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
        imClient.register(ReceiveMessageHandler(storage: storage, myUserId: { [weak imClient] in imClient?.userId ?? "" }))
        let notifyHandler = NotifyMessageHandler()
        notifyHandler.onNotify = { [weak self] head, type in self?.pullMessages(from: head, type: type) }
        imClient.register(notifyHandler)
    }

    /// Call once after a successful login (wire this to
    /// `ConnectAckHandler.onSyncState`, Plan B Task 11) to catch up on
    /// anything missed while disconnected, seeded from the locally stored
    /// sync state rather than starting from zero.
    public func pullMessagesSinceLastSync(syncState: ConnectAckSyncState) {
        pullMessages(from: syncState.messageHead, type: 0)
    }

    public func sendText(to target: String, conversationType: ConversationType = .single, line: Int = 0, text: String) throws {
        try send(to: target, conversationType: conversationType, line: line, content: .text(text))
    }

    public func sendImage(to target: String, conversationType: ConversationType = .single, line: Int = 0, thumbnail: Data?, remoteURL: String) throws {
        try send(to: target, conversationType: conversationType, line: line, content: .image(thumbnail: thumbnail, remoteURL: remoteURL, localPath: nil))
    }

    private func send(to target: String, conversationType: ConversationType, line: Int, content: MessageContent) throws {
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
            direction: .send
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

        try sendWireMessage(localMessageId: echo.localMessageId, conversationType: conversationType, target: target, line: line, content: content)
    }

    /// Re-sends an already-stored message that previously failed (`status
    /// == .sendFailure`) — e.g. the user tapped a retry affordance on a
    /// failed bubble. Reuses the existing row's `localMessageId`/content
    /// rather than inserting a new row, so the UI sees the same message
    /// transition back to `.sending` rather than a duplicate appearing.
    /// Doesn't touch the conversation's last-message preview/timestamp —
    /// unlike a fresh `send`, this isn't a new logical message, so there's
    /// nothing new to reflect there. A no-op if no such sent-direction row
    /// exists for `localMessageId` (mirrors `MessageStore.updateStatus`'s
    /// own silent-no-op-on-not-found behavior).
    public func resend(localMessageId: Int64) throws {
        guard let message = try storage.messages.message(localMessageId: localMessageId) else { return }
        try storage.messages.updateStatus(localMessageId: localMessageId, status: .sending)
        try sendWireMessage(localMessageId: localMessageId, conversationType: message.conversationType, target: message.target, line: message.line, content: message.content)
    }

    private func sendWireMessage(localMessageId: Int64, conversationType: ConversationType, target: String, line: Int, content: MessageContent) throws {
        var wireMessage = Im_Message()
        wireMessage.conversation.type = Int32(conversationType.rawValue)
        wireMessage.conversation.target = target
        wireMessage.conversation.line = Int32(line)
        wireMessage.fromUser = imClient.userId
        wireMessage.content = MessageContentCodec.encode(content)
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
