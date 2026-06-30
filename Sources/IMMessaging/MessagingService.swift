import Foundation
import IMClient
import IMTransport
import IMProto
import IMStorage

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
    private var pendingRecalls: [UInt16: (Bool) -> Void] = [:]

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
    /// this to receive Answer/Bye/Signal/Modify.
    public var onCallSignal: ((Im_Message) -> Void)? {
        get { receiveMessageHandler.onCallSignal }
        set { receiveMessageHandler.onCallSignal = newValue }
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

        let notifyHandler = NotifyMessageHandler()
        notifyHandler.onNotify = { [weak self] head, type in self?.pullMessages(from: head, type: type) }
        imClient.register(notifyHandler)
        imClient.register(recallHandler)
        recallAckHandlerInstance.onAck = { [weak self] wireId, success in
            self?.pendingRecalls.removeValue(forKey: wireId)?(success)
        }
        imClient.register(recallAckHandlerInstance)
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

    /// Sends one of 401/402/403/404 (Answer/Bye/Signal/Modify) directly on
    /// the wire — deliberately bypassing `send(...)`'s local-echo insert
    /// and `OutgoingMessageTracker` ack tracking, because these are
    /// transient signaling with no corresponding stored row to update (see
    /// the Phase 3 design doc §2's persist-flag table). `callId` goes in
    /// `searchableContent` and `dataPayload` in `data`, mirroring every
    /// other content type's wire-field mapping in this codebase.
    public func sendCallControlMessage(to target: String, wireType: Int32, callId: String, dataPayload: Data?) throws {
        var wireMessage = Im_Message()
        wireMessage.conversation.type = Int32(ConversationType.single.rawValue)
        wireMessage.conversation.target = target
        wireMessage.conversation.line = 0
        wireMessage.fromUser = imClient.userId
        var content = Im_MessageContent()
        content.type = wireType
        content.searchableContent = callId
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
            switch result {
            case .acked(let messageUid, _):
                try? self.storage.messages.updateMessageUid(localMessageId: localId, messageUid: messageUid)
                try? self.storage.messages.updateStatus(localMessageId: localId, status: .sent)
            case .failed:
                try? self.storage.messages.updateStatus(localMessageId: localId, status: .sendFailure)
            }
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
