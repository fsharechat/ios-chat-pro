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
    private let streamingAiHandler: StreamingAiHandler
    private let scheduler: Scheduler
    private var pendingRecalls: [UInt16: (Bool) -> Void] = [:]

    /// 远程历史请求的**空闲**超时：从"最后一次观察到该响应有新字节到达"
    /// 起算，而不是从请求发出起算。一页 30 条历史在慢链路上实测能到
    /// 180 KB / 7 秒以上，用固定的发出后 5 秒（`OutgoingMessageTracker`
    /// 给单条消息 ack 用的值）必然误杀。
    private static let remoteLoadIdleTimeout: TimeInterval = 10
    /// 空闲续期的硬上限，从请求发出起算：防止服务端以慢速滴灌的方式把
    /// 一个请求无限吊住。
    private static let remoteLoadMaxDuration: TimeInterval = 60

    private struct PendingRemoteLoad {
        var timeoutToken: SchedulerToken
        let completion: (Int?) -> Void
        let startedAtMillis: Int64
        /// 已观察到的 body 字节数，用于忽略不推进的重复进度回调。
        var receivedBodyBytes: Int
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
    /// this to receive Answer/Bye/Signal/Modify/AnswerT/CallTaken (401/402/403/404/405/406).
    public var onCallSignal: ((Im_Message) -> Void)? {
        get { receiveMessageHandler.onCallSignal }
        set { receiveMessageHandler.onCallSignal = newValue }
    }

    /// Forwards to the internal `ReceiveMessageHandler`'s closure of the
    /// same name — see that type's doc comment. `AppEnvironment` relays this
    /// to `App.MessageAlertPlayer` so it survives `MessagingService` being
    /// torn down/recreated across logout/re-login.
    public var onIncomingMessageAlert: ((_ isMuted: Bool, _ isActiveConversation: Bool, _ isGroupNotification: Bool) -> Void)? {
        get { receiveMessageHandler.onIncomingMessageAlert }
        set { receiveMessageHandler.onIncomingMessageAlert = newValue }
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

    /// 当前活跃的流式 AI(官方客服)回复,对齐 Android `ChatManager` 的
    /// `activeStream`——会话页中途退出重进时用它恢复占位气泡;真实完整
    /// 消息入库替换占位后由 UI 调 `clearActiveStream()` 清掉。
    public private(set) var activeStream: StreamingState?

    /// SAI 增量事件的单监听者(同 Android `setOnSaiTokenListener`),由
    /// 当前打开的会话页 ViewModel 绑定;无论状态机是否吃下该事件都会
    /// 原样上抛(与 Android 先更新 activeStream 再回调 listener 一致)。
    public var onSaiToken: ((_ streamId: String, _ delta: String, _ done: Bool, _ target: String) -> Void)?

    public func clearActiveStream() {
        activeStream = nil
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
        let streamingHandler = StreamingAiHandler()
        streamingAiHandler = streamingHandler

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
        streamingHandler.onSaiToken = { [weak self] streamId, delta, done, target in
            self?.handleSaiToken(streamId: streamId, delta: delta, done: done, target: target)
        }
        imClient.register(streamingHandler)
        imClient.onIncomingFrameProgress = { [weak self] header, receivedBodyBytes in
            self?.handleIncomingFrameProgress(header: header, receivedBodyBytes: receivedBodyBytes)
        }
        imClient.onDisconnected = { [weak self] in
            self?.failAllPendingRemoteLoads()
        }
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

    /// Sends one of 401/402/403/404/405/406 (Answer/Bye/Signal/Modify/AnswerT/CallTaken) directly on
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
        pendingRemoteLoads[wireId] = PendingRemoteLoad(
            timeoutToken: scheduleRemoteLoadTimeout(wireId: wireId),
            completion: completion,
            startedAtMillis: nowMillis(),
            receivedBodyBytes: 0
        )
    }

    private func scheduleRemoteLoadTimeout(wireId: UInt16) -> SchedulerToken {
        scheduler.scheduleOnce(after: Self.remoteLoadIdleTimeout) { [weak self] in
            self?.pendingRemoteLoads.removeValue(forKey: wireId)?.completion(nil)
        }
    }

    /// 该请求的响应帧正在流式到达 → 把空闲超时窗口整体后移。只认自己那
    /// 一笔（`PUB_ACK`/`LRM` + 匹配的 `messageId`，帧头一到就都已知），
    /// 不会被连接上的其它流量（心跳 ack、别人的推送）误续。
    private func handleIncomingFrameProgress(header: Header, receivedBodyBytes: Int) {
        guard header.signal == .pubAck, header.subSignal == .lrm,
              var pending = pendingRemoteLoads[header.messageId],
              receivedBodyBytes > pending.receivedBodyBytes else { return }
        // 硬上限到点后停止续期：不主动结掉请求，而是让当前这枚计时器自然
        // 烧完——超出上限的幅度因此最多一个空闲窗口，换来的是这里不必处理
        // "在进度回调里同步触发 completion" 的重入。
        let elapsed = TimeInterval(nowMillis() - pending.startedAtMillis) / 1000
        guard elapsed < Self.remoteLoadMaxDuration else { return }
        pending.timeoutToken.cancel()
        pending.timeoutToken = scheduleRemoteLoadTimeout(wireId: header.messageId)
        pending.receivedBodyBytes = receivedBodyBytes
        pendingRemoteLoads[header.messageId] = pending
    }

    /// 连接断开 → 在途的历史请求不可能再有响应，立刻判失败，而不是让调用
    /// 方（下拉刷新的菊花）干等满整个空闲窗口。
    private func failAllPendingRemoteLoads() {
        let cancelled = pendingRemoteLoads
        pendingRemoteLoads.removeAll()
        for (_, pending) in cancelled {
            pending.timeoutToken.cancel()
            pending.completion(nil)
        }
    }

    private func handleRemoteMessagesResult(wireId: UInt16, messages: [Im_Message]?) {
        // 找不到 pending = 这一笔已经超时（或因断连）被判失败了。响应仍然
        // 照常入库：字节已经收下来、protobuf 已经解完，此刻丢掉只会让下次
        // 下拉重新下载同样的一页——慢链路上那正是历史永远拉不出来的死循环。
        // 只是不再回调调用方（它早已收到 nil 并结束了自己的刷新）。
        let pending = pendingRemoteLoads.removeValue(forKey: wireId)
        pending?.timeoutToken.cancel()
        // `nil` = server-reported error → a failed request; an empty page is
        // a *successful* "no more history" and completes with 0.
        guard let messages else { pending?.completion(nil); return }
        guard !messages.isEmpty else { pending?.completion(0); return }
        var inserted = 0
        try? storage.write { db in
            for wireMessage in messages where persistHistory(wireMessage, db: db) {
                inserted += 1
            }
        }
        pending?.completion(inserted)
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
        if [401, 402, 403, 404, 405, 406].contains(wireMessage.content.type) {
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

    private func handleSaiToken(streamId: String, delta: String, done: Bool, target: String) {
        if !done, delta.isEmpty, activeStream == nil {
            activeStream = StreamingState(streamId: streamId, target: target, accumulatedText: "", done: false)
        } else if !done, !delta.isEmpty, let stream = activeStream, stream.streamId == streamId {
            activeStream = StreamingState(streamId: streamId, target: target, accumulatedText: stream.accumulatedText + delta, done: false)
        } else if done, let stream = activeStream, stream.streamId == streamId {
            activeStream = StreamingState(streamId: streamId, target: target, accumulatedText: stream.accumulatedText, done: true)
        }
        onSaiToken?(streamId, delta, done, target)
    }
}
