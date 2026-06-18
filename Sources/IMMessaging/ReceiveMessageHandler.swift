import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses a `PUB_ACK`/`MP` pulled-message batch, persists new messages,
/// updates the affected conversations, and advances the local sync state.
/// See this plan's "Reference facts" for the own-message-race handling.
public final class ReceiveMessageHandler: MessageHandler {
    private let storage: IMStorage
    private let myUserId: () -> String

    public init(storage: IMStorage, myUserId: @escaping () -> String) {
        self.storage = storage
        self.myUserId = myUserId
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .mp
    }

    public func handle(frame: Frame) {
        guard let result = try? Im_PullMessageResult(serializedBytes: frame.body) else { return }
        for wireMessage in result.message {
            persist(wireMessage)
        }
        advanceSyncHead(to: result.head)
    }

    private func persist(_ wireMessage: Im_Message) {
        guard wireMessage.messageID != 0 else { return }
        if (try? storage.messages.message(uid: wireMessage.messageID)) != nil {
            return // already have it via server uid — pull windows can overlap
        }

        let direction: MessageDirection = wireMessage.fromUser == myUserId() ? .send : .receive

        if direction == .send, wireMessage.localMessageID != 0,
           (try? storage.messages.message(localMessageId: wireMessage.localMessageID)) != nil {
            // My own message, already locally echoed before its own ack
            // arrived (e.g. a reconnect race) — update in place rather than
            // risk a duplicate-row insert against the
            // (localMessageId, direction = .send) unique index.
            try? storage.messages.updateMessageUid(localMessageId: wireMessage.localMessageID, messageUid: wireMessage.messageID)
            try? storage.messages.updateStatus(localMessageId: wireMessage.localMessageID, status: .sent)
            return
        }

        guard let content = try? MessageContentCodec.decode(wireMessage.content) else { return }
        let conversationType = ConversationType(rawValue: Int(wireMessage.conversation.type)) ?? .single
        let target = wireMessage.conversation.target
        let line = Int(wireMessage.conversation.line)

        do {
            try storage.messages.insert(StoredMessage(
                localMessageId: wireMessage.localMessageID,
                messageUid: wireMessage.messageID,
                conversationType: conversationType,
                target: target,
                line: line,
                from: wireMessage.fromUser,
                content: content,
                timestamp: wireMessage.serverTimestamp,
                status: direction == .send ? .sent : .unread,
                direction: direction
            ))
            try storage.conversations.recordIncomingMessage(
                conversationType: conversationType,
                target: target,
                line: line,
                messageUid: wireMessage.messageID,
                timestamp: wireMessage.serverTimestamp,
                incrementUnread: direction == .receive
            )
        } catch {
            // Best-effort: one malformed/unexpected row shouldn't abort the rest of the batch.
        }
    }

    private func advanceSyncHead(to head: Int64) {
        guard let current = try? storage.syncState.get(), head > current.msgHead else { return }
        try? storage.syncState.set(StoredSyncState(
            msgHead: head,
            friendHead: current.friendHead,
            friendRequestHead: current.friendRequestHead,
            settingHead: current.settingHead
        ))
    }
}
