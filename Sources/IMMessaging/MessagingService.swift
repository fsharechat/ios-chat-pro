import Foundation
import IMClient
import IMTransport
import IMProto
import IMStorage

/// The single entry point Plan E/F's UI code constructs: wires
/// `MessageSendAckHandler`/`ReceiveMessageHandler`/`NotifyMessageHandler`
/// into the given `IMClient`, and exposes `sendText`/`sendImage`/
/// `pullMessagesSinceLastSync`.
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

        var wireMessage = Im_Message()
        wireMessage.conversation.type = Int32(conversationType.rawValue)
        wireMessage.conversation.target = target
        wireMessage.conversation.line = Int32(line)
        wireMessage.fromUser = imClient.userId
        wireMessage.content = MessageContentCodec.encode(content)
        wireMessage.localMessageID = localMessageId

        let body = try wireMessage.serializedData()
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .ms, body: body)
        tracker.track(wireMessageId: wireMessageId, localMessageId: echo.localMessageId) { [weak self] localId, result in
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
