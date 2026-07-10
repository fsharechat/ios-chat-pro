import Foundation
import IMClient
import IMTransport
import IMProto
import IMStorage
import GRDB

/// The single entry point Plan E/F's UI code constructs: wires
/// `MessageSendAckHandler`/`ReceiveMessageHandler`/`NotifyMessageHandler`
/// into the given `IMClient`, and exposes `sendText`/`sendImage`/
/// `pullMessagesSinceLastSync`.
///
/// **Threading contract:** like the rest of this codebase (see `IMClient`'s
/// own threading-contract doc comment), this has no internal locking and
/// must be called from a single consistent queue.
public final class MessagingService {
    private let imClient: IMClient
    private let storage: IMStorage
    private let tracker: OutgoingMessageTracker
    private let idGenerator: LocalMessageIdGenerator
    private let nowMillis: () -> Int64
    private let receiveMessageHandler: ReceiveMessageHandler
    private let recallNotifyHandler: RecallNotifyMessageHandler
    private let recallAckHandler: RecallAckHandler
    private let remoteMessageAckHandler: RemoteMessageAckHandler
    private let scheduler: Scheduler
    private var pendingRecalls: [UInt16: (Bool) -> Void] = [:]

    private struct PendingRemoteLoad {
        let timeoutToken: SchedulerToken
        let completion: (Int?) -> Void
    }
    private var pendingRemoteLoads: [UInt16: PendingRemoteLoad] = [:]

    /// Forwards to the internal `ReceiveMessageHandler`'s own closure of the
    /// same name — see that type's doc comment. Exposed here because
    /// `AppEnvironment` only has a handle on `MessagingService`, not on the
    /// handler instances it registers internally.
    public var onGroupNotificationMessage: ((String) -> Void)? {
        get { receiveMessageHandler.onGroupNotificationMessage }
        set { receiveMessageHandler.onGroupNotificationMessage = newValue }
    }

    /// Forwards to the internal `ReceiveMessageHandler`'s closure of the
    /// same name — see that type's doc comment. `IMCall.CallManager` wires
    /// this to learn about incoming calls.
    public var onCallStartMessage: ((StoredMessage) -> Void)? {
        get { receiveMessageHandler.onCallStartMessage }
        set { receiveMessageHandler.onCallStartMessage = newValue }
    }

    /// Forwards to the internal `ReceiveMessageHandler`'s closure of the
    /// same name — see that type's doc comment. `IMCall.CallManager` wires
    /// this to receive Answer/Bye/Signal/Modify/AnswerT (401/402/403/404/405).
    public var onCallSignal: ((Im_Message) -> Void)? {
        get { receiveMessageHandler.onCallSignal }
        set { receiveMessageHandler.onCallSignal = newValue }
    }

    /// Forwards to the internal `ReceiveMessageHandler`'s property of the
    /// same name — see that type's doc comment. `IMKit` 的
    /// `ActiveConversationTracking` conformance 通过它标记/清除用户当前
    /// 停留的会话。
    public var activeConversation: (conversationType: ConversationType, target: String, line: Int)? {
        get { receiveMessageHandler.activeConversation }
        set { receiveMessageHandler.activeConversation = newValue }
    }

    /// Forwards to the internal `RecallNotifyMessageHandler`'s closure.
    /// Wire this to any UI that needs to react when a message is recalled
    /// (e.g. to scroll to the updated row or dismiss a reply composer).
    public var onMessageRecalled: ((Int64) -> Void)? {
        get { recallNotifyHandler.onRecalled }
        set { recallNotifyHandler.onRecalled = newValue }
    }

    public init(
        imClient: IMClient,
        storage: IMStorage,
        scheduler: Scheduler = DispatchQueueScheduler(),
        idGenerator: LocalMessageIdGenerator = LocalMessageIdGenerator(),
        nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.imClient = imClient
        self.storage = storage
        self.scheduler = scheduler
        tracker = OutgoingMessageTracker(scheduler: scheduler)
        self.idGenerator = idGenerator
        self.nowMillis = nowMillis

        imClient.register(MessageSendAckHandler(tracker: tracker))
        let receiveHandler = ReceiveMessageHandler(storage: storage, myUserId: { [weak imClient] in imClient?.userId ?? "" })
        receiveMessageHandler = receiveHandler
        imClient.register(receiveHandler)
        // Initialise recallNotifyHandler before the first [weak self] closure
        // below — Swift phase-1 init requires every stored property to be set
        // before `self` is captured anywhere (even weakly).
        let recallHandler = RecallNotifyMessageHandler(storage: storage)
        recallNotifyHandler = recallHandler
        // recallAckHandler must be assigned before the first [weak self] closure
        // below — Swift phase-1 init requires every stored property to be set
        // before `self` is captured anywhere (even weakly).
        let recallAckHandlerInstance = RecallAckHandler()
        recallAckHandler = recallAckHandlerInstance
        let remoteAckHandlerInstance = RemoteMessageAckHandler()
        remoteMessageAckHandler = remoteAckHandlerInstance

        let notifyHandler = NotifyMessageHandler()
        notifyHandler.onNotify = { [weak self] head, type in self?.pullMessages(from: head, type: type) }
        imClient.register(notifyHandler)
        imClient.register(recallHandler)
        recallAckHandlerInstance.onAck = { [weak self] wireId, success in
            self?.pendingRecalls.removeValue(forKey: wireId)?(success)
        }
        imClient.register(recallAckHandlerInstance)
        remoteAckHandlerInstance.onResult = { [weak self] wireId, messages in
            self?.handleRemoteMessagesResult(wireId: wireId, messages: messages)
        }
        imClient.register(remoteAckHandlerInstance)
    }

    /// Call once after a successful login (wire this to
    /// `ConnectAckHandler.onSyncState`, Plan B Task 11) to catch up on
    /// anything missed while disconnected, seeded from the locally stored
    /// sync state rather than starting from zero.
    ///
    /// Deliberately ignores `ConnectAckSyncState.messageHead` (the
    /// CONNECT_ACK payload's `msgHead`) — that field is the server's
    /// *current* head, not "where this device last synced to." Using it as
    /// the pull cursor on first login asks the server for messages newer
    /// than "right now," which always comes back empty even when there's
    /// real history — Android's `ConnectAckMessageHandler` makes the same
    /// distinction (`getLastMessageSeq()`, a value it explicitly never
    /// calibrates from the ack's `msgHead`). The locally stored
    /// `IMStorage.syncState` head defaults to 0 for a fresh device, which is
    /// exactly "give me everything," and is advanced to the server's real
    /// value only as `ReceiveMessageHandler` actually persists pulled
    /// messages.
    public func pullMessagesSinceLastSync() {
        let localHead = (try? storage.syncState.get())?.msgHead ?? 0
        if localHead == 0 {
            receiveMessageHandler.suppressUnreadIncrement = true
        }
        pullMessages(from: localHead, type: 0)
    }

    public func sendText(to target: String, conversationType: ConversationType = .single, line: Int = 0, text: String, mentionedType: Int32 = 0, mentionedTargets: [String] = []) throws {
        try send(to: target, conversationType: conversationType, line: line, content: .text(text), mentionedType: mentionedType, mentionedTargets: mentionedTargets)
    }

    public func sendImage(to target: String, conversationType: ConversationType = .single, line: Int = 0, thumbnail: Data?, remoteURL: String) throws {
        try send(to: target, conversationType: conversationType, line: line, content: .image(thumbnail: thumbnail, remoteURL: remoteURL, localPath: nil), mentionedType: 0, mentionedTargets: [])
    }

    public func sendVoice(to target: String, conversationType: ConversationType = .single, line: Int = 0, remoteURL: String, duration: Int) throws {
        try send(to: target, conversationType: conversationType, line: line,
                 content: .voice(remoteURL: remoteURL, localPath: nil, duration: duration),
                 mentionedType: 0, mentionedTargets: [])
    }

    public func sendFile(to target: String, conversationType: ConversationType = .single, line: Int = 0, name: String, size: Int, remoteURL: String) throws {
        try send(to: target, conversationType: conversationType, line: line,
                 content: .file(name: name, size: size, remoteURL: remoteURL, localPath: nil),
                 mentionedType: 0, mentionedTargets: [])
    }

    public func sendVideo(to target: String, conversationType: ConversationType = .single, line: Int = 0, thumbnail: Data?, remoteURL: String, duration: Int) throws {
        try send(to: target, conversationType: conversationType, line: line,
                 content: .video(thumbnail: thumbnail, remoteURL: remoteURL, localPath: nil, duration: duration),
                 mentionedType: 0, mentionedTargets: [])
    }

    public func sendLocation(to target: String, conversationType: ConversationType = .single, line: Int = 0, lat: Double, lng: Double, title: String, thumbnail: Data?) throws {
        try send(to: target, conversationType: conversationType, line: line,
                 content: .location(lat: lat, lng: lng, title: title, thumbnail: thumbnail),
                 mentionedType: 0, mentionedTargets: [])
    }

    /// Sends a CallStart (wire type 400) and persists it as a local call-
    /// record bubble, exactly like `sendText`/`sendImage` persist their
    /// content — this is the one call-signaling type that's a real chat
    /// message, not transient signaling. Returns the inserted row so
    /// `IMCall.CallManager` can capture its `id` for later
    /// `IMStorage.MessageStore.updateContent` calls as the call progresses.
    @discardableResult
    public func sendCallStart(targetId: String, callId: String, audioOnly: Bool) throws -> StoredMessage {
        let content = MessageContent.callRecord(callId: callId, targetId: targetId, audioOnly: audioOnly, status: 0, connectTime: 0, endTime: 0)
        let localMessageId = idGenerator.next()
        let timestamp = nowMillis()

        let echo = try storage.messages.insert(StoredMessage(
            localMessageId: localMessageId,
            conversationType: .single,
            target: targetId,
            from: imClient.userId,
            content: content,
            timestamp: timestamp,
            status: .sending,
            direction: .send
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: .single, target: targetId, line: 0,
            messageUid: 0, timestamp: timestamp, incrementUnread: false
        )
        try sendWireMessage(localMessageId: echo.localMessageId, conversationType: .single, target: targetId, line: 0, content: content, mentionedType: 0, mentionedTargets: [])
        return echo
    }

    /// Sends one of 401/402/403/404/405 (Answer/Bye/Signal/Modify/AnswerT) directly on
    /// the wire — deliberately bypassing `send(...)`'s local-echo insert
    /// and `OutgoingMessageTracker` ack tracking, because these are
    /// transient signaling with no corresponding stored row to update (see
    /// the Phase 3 design doc §2's persist-flag table). `callId` goes in
    /// `content` and `dataPayload` in `data` — Android 引擎的 AnswerMessage/
    /// ByeMessage/SignalMessage 都从 `MessagePayload.content`(= wire 的
    /// content 字段)读 callId,写错字段对端会解出空 callId,把整通电话当
    /// 无关信令拒掉。
    public func sendCallControlMessage(to target: String, wireType: Int32, callId: String, dataPayload: Data?) throws {
        var wireMessage = Im_Message()
        wireMessage.conversation.type = Int32(ConversationType.single.rawValue)
        wireMessage.conversation.target = target
        wireMessage.conversation.line = 0
        wireMessage.fromUser = imClient.userId
        var content = Im_MessageContent()
        content.type = wireType
        content.content = callId
        if let dataPayload {
            content.data = dataPayload
        }
        wireMessage.content = content

        let body = try wireMessage.serializedData()
        imClient.sendFrame(signal: .publish, subSignal: .ms, body: body)
    }

    private func send(to target: String, conversationType: ConversationType, line: Int, content: MessageContent, mentionedType: Int32, mentionedTargets: [String]) throws {
        let localMessageId = idGenerator.next()
        let timestamp = nowMillis()

        let echo = try storage.messages.insert(StoredMessage(
            localMessageId: localMessageId,
            conversationType: conversationType,
            target: target,
            line: line,
            from: imClient.userId,
            content: content,
            timestamp: timestamp,
            status: .sending,
            direction: .send,
            mentionedType: Int(mentionedType),
            mentionedTargets: mentionedTargets
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: conversationType, target: target, line: line,
            messageUid: 0, timestamp: timestamp, incrementUnread: false
        )
        // No transaction wraps the two calls above: if `recordIncomingMessage`
        // throws after `insert` succeeds, this function returns early (never
        // reaching `sendWireMessage`), leaving a message row stuck in
        // `.sending` with no conversation update — the same accepted-for-
        // Phase-1 gap documented in `ReceiveMessageHandler.persist`.

        try sendWireMessage(localMessageId: echo.localMessageId, conversationType: conversationType, target: target, line: line, content: content, mentionedType: mentionedType, mentionedTargets: mentionedTargets)
    }

    public func recall(
        messageUid: Int64,
        storageId: Int64,
        conversationType: ConversationType,
        target: String,
        line: Int,
        completion: @escaping (Bool) -> Void
    ) {
        var buf = Im_INT64Buf()
        buf.id = messageUid
        guard let body = try? buf.serializedData() else { completion(false); return }
        let wireId = imClient.sendFrame(signal: .publish, subSignal: .mr, body: body)
        pendingRecalls[wireId] = { [weak self] success in
            guard let self, success else { completion(false); return }
            try? self.storage.write { db in
                try self.storage.messages.updateContent(id: storageId, content: .recalled(operatorId: self.imClient.userId), db: db)
                try self.storage.conversations.touchConversation(conversationType: conversationType, target: target, line: line, db: db)
            }
            completion(true)
        }
    }

    /// Re-sends an already-stored message that previously failed (`status
    /// == .sendFailure`) — e.g. the user tapped a retry affordance on a
    /// failed bubble. Reuses the existing row's `localMessageId`/content
    /// rather than inserting a new row, so the UI sees the same message
    /// transition back to `.sending` rather than a duplicate appearing.
    /// Doesn't touch the conversation's last-message preview/timestamp —
    /// unlike a fresh `send`, this isn't a new logical message, so there's
    /// nothing new to reflect there. A no-op if no such sent-direction row
    /// exists for `localMessageId`, or if it isn't currently in
    /// `.sendFailure` (this also means calling `resend` twice in quick
    /// succession before the first attempt resolves is safe — the second
    /// call sees `.sending`, not `.sendFailure`, and no-ops).
    public func resend(localMessageId: Int64) throws {
        guard let message = try storage.messages.message(localMessageId: localMessageId), message.status == .sendFailure else { return }
        try storage.messages.updateStatus(localMessageId: localMessageId, status: .sending)
        try sendWireMessage(localMessageId: localMessageId, conversationType: message.conversationType, target: message.target, line: message.line, content: message.content, mentionedType: Int32(message.mentionedType), mentionedTargets: message.mentionedTargets)
    }

    private func sendWireMessage(localMessageId: Int64, conversationType: ConversationType, target: String, line: Int, content: MessageContent, mentionedType: Int32, mentionedTargets: [String]) throws {
        var wireMessage = Im_Message()
        wireMessage.conversation.type = Int32(conversationType.rawValue)
        wireMessage.conversation.target = target
        wireMessage.conversation.line = Int32(line)
        wireMessage.fromUser = imClient.userId
        wireMessage.content = MessageContentCodec.encode(content, mentionedType: mentionedType, mentionedTargets: mentionedTargets)
        wireMessage.localMessageID = localMessageId

        let body = try wireMessage.serializedData()
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .ms, body: body)
        tracker.track(wireMessageId: wireMessageId, localMessageId: localMessageId) { [weak self] localId, result in
            guard let self else { return }
            // 状态更新只写 messages 表,但会话列表的「发送中/发送失败」前缀
            // 由 conversationsPublisher 驱动 —— 必须同事务 touch 一下会话行,
            // 否则列表停留在旧状态(与 recall 的 touchConversation 同一模式)。
            try? self.storage.write { db in
                switch result {
                case .acked(let messageUid, _):
                    try self.storage.messages.updateMessageUid(localMessageId: localId, messageUid: messageUid, db: db)
                    try self.storage.messages.updateStatus(localMessageId: localId, status: .sent, db: db)
                case .failed:
                    try self.storage.messages.updateStatus(localMessageId: localId, status: .sendFailure, db: db)
                }
                try self.storage.conversations.touchConversation(conversationType: conversationType, target: target, line: line, db: db)
            }
        }
    }

    /// Requests up to `count` messages strictly older than `beforeUid` from
    /// the server (`PUBLISH`/`LRM`) and persists any it doesn't already have
    /// locally. Mirrors Android's `ChatManager.getRemoteMessages` — the
    /// remote fallback the conversation screen uses when local history is
    /// exhausted. `beforeUid == 0` means "from the newest".
    ///
    /// `completion` receives the number of *newly persisted* messages on
    /// success (0 when everything returned was already stored, or the server
    /// had nothing older), and `nil` when the request failed — server error
    /// or timeout (5s, same as send acks) — so the caller can retry later
    /// instead of treating history as exhausted. Persisting history deliberately does
    /// **not** touch the conversation row (no unread badge, no last-message
    /// preview regression to an older message) nor the incremental-pull sync
    /// head — history sits strictly behind what the user has already seen.
    public func loadRemoteMessages(
        conversationType: ConversationType,
        target: String,
        line: Int,
        beforeUid: Int64,
        count: Int,
        completion: @escaping (Int?) -> Void
    ) {
        var request = Im_LoadRemoteMessages()
        request.conversation.type = Int32(conversationType.rawValue)
        request.conversation.target = target
        request.conversation.line = Int32(line)
        request.beforeUid = beforeUid
        request.count = Int32(count)
        guard let body = try? request.serializedData() else { completion(nil); return }
        let wireId = imClient.sendFrame(signal: .publish, subSignal: .lrm, body: body)
        let timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.pendingRemoteLoads.removeValue(forKey: wireId)?.completion(nil)
        }
        pendingRemoteLoads[wireId] = PendingRemoteLoad(timeoutToken: timeoutToken, completion: completion)
    }

    private func handleRemoteMessagesResult(wireId: UInt16, messages: [Im_Message]?) {
        guard let pending = pendingRemoteLoads.removeValue(forKey: wireId) else { return }
        pending.timeoutToken.cancel()
        // `nil` = server-reported error → a failed request; an empty page is
        // a *successful* "no more history" and completes with 0.
        guard let messages else { pending.completion(nil); return }
        guard !messages.isEmpty else { pending.completion(0); return }
        var inserted = 0
        try? storage.write { db in
            for wireMessage in messages where persistHistory(wireMessage, db: db) {
                inserted += 1
            }
        }
        pending.completion(inserted)
    }

    /// Persist path for remote *history* — same wire-to-stored conversion as
    /// `ReceiveMessageHandler.persist` (direction/target mapping, content
    /// fallbacks) but with everything conversation-facing stripped: no
    /// `recordIncomingMessage`, no sync-head advance, no group/call
    /// callbacks. Returns whether a new row was inserted.
    private func persistHistory(_ wireMessage: Im_Message, db: Database) -> Bool {
        guard wireMessage.messageID != 0 else { return false }
        if (try? storage.messages.message(uid: wireMessage.messageID, db: db)) != nil {
            return false // already have it via server uid
        }
        if [401, 402, 403, 404, 405].contains(wireMessage.content.type) {
            return false // transient call signaling never persists (see ReceiveMessageHandler)
        }
        guard var content = try? MessageContentCodec.decode(wireMessage.content) else { return false }
        if case .groupNotification(let type, let operatorUid, let memberUids, let value) = content, operatorUid.isEmpty {
            content = .groupNotification(type: type, operatorUid: wireMessage.fromUser, memberUids: memberUids, value: value)
        }
        if case .recalled(let operatorId) = content, operatorId.isEmpty {
            content = .recalled(operatorId: wireMessage.fromUser)
        }

        let direction: MessageDirection = wireMessage.fromUser == imClient.userId ? .send : .receive
        let conversationType = ConversationType(rawValue: Int(wireMessage.conversation.type)) ?? .single
        let target: String
        if conversationType == .single && direction == .receive {
            target = wireMessage.fromUser
        } else {
            target = wireMessage.conversation.target
        }

        do {
            // History rows never reconcile with an in-flight local echo (any
            // message this device sent is already stored and deduped by uid
            // above), so the server uid doubles as the send-direction
            // localMessageId surrogate — an old device's localMessageID could
            // collide with this device's generator under the partial unique
            // index on (localMessageId) WHERE direction=send.
            try storage.messages.insert(StoredMessage(
                localMessageId: direction == .send ? wireMessage.messageID : wireMessage.localMessageID,
                messageUid: wireMessage.messageID,
                conversationType: conversationType,
                target: target,
                line: Int(wireMessage.conversation.line),
                from: wireMessage.fromUser,
                content: content,
                timestamp: wireMessage.serverTimestamp,
                status: direction == .send ? .sent : .read,
                direction: direction,
                mentionedType: Int(wireMessage.content.mentionedType),
                mentionedTargets: wireMessage.content.mentionedTarget
            ), db: db)
            return true
        } catch {
            return false // one malformed row shouldn't abort the rest of the batch
        }
    }

    private func pullMessages(from beforeHead: Int64, type: Int32) {
        var request = Im_PullMessageRequest()
        request.id = beforeHead
        request.type = type
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .mp, body: body)
    }
}
