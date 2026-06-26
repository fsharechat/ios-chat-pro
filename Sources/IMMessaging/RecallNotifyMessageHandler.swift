import IMClient
import IMTransport
import IMProto
import IMStorage

/// Handles a `PUBLISH`/`RMN` (subSignal 31) server push that tells this
/// client a message has been recalled by its sender.
///
/// On receipt the handler:
/// 1. Updates the message row's content to `.recalled(operatorId:)` inside
///    a single write transaction.
/// 2. Touches the conversation row via `touchConversation` so
///    `conversationsPublisher` fires and any list/chat UI observing it
///    re-renders the recalled bubble. The touch does NOT mutate
///    `timestamp`/`lastMessageUid` — recall does not change ordering.
/// 3. Fires `onRecalled` with the `messageUid` — but only when the message
///    was found locally (i.e. `didUpdate == true`). Recalls for messages
///    outside the local sync window are silently ignored.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class RecallNotifyMessageHandler: MessageHandler {
    private let storage: IMStorage

    /// Fired after the recalled message has been updated in storage.
    /// The argument is the `messageUid` of the recalled message.
    /// Not fired when the message is not found locally (e.g. outside sync window).
    public var onRecalled: ((Int64) -> Void)?

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .publish && subSignal == .rmn
    }

    public func handle(frame: Frame) {
        guard let notify = try? Im_NotifyRecallMessage(serializedBytes: frame.body) else { return }
        let messageUid = notify.id
        let operatorId = notify.fromUser

        // `didUpdate` is mutated inside the synchronous `storage.write` block.
        // It stays false when the message row is not found locally so the
        // callback is not fired for a recall the client never stored.
        var didUpdate = false
        try? storage.write { db in
            guard let existing = try storage.messages.message(uid: messageUid, db: db),
                  let rowId = existing.id else { return }
            try storage.messages.updateContent(id: rowId, content: .recalled(operatorId: operatorId), db: db)
            try storage.conversations.touchConversation(
                conversationType: existing.conversationType,
                target: existing.target,
                line: existing.line,
                db: db
            )
            didUpdate = true
        }
        if didUpdate { onRecalled?(messageUid) }
    }
}
