import GRDB
import Combine

/// CRUD for `StoredMessage`. `message(localMessageId:)` is the dedup lookup
/// a future `SendMessageHandler` (Plan D) needs after reconnecting, per the
/// migration design doc's `local_message_id` flow.
public final class MessageStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    @discardableResult
    public func insert(_ message: StoredMessage) throws -> StoredMessage {
        var message = message
        try dbQueue.write { db in try message.insert(db) }
        return message
    }

    /// `localMessageId` is only guaranteed unique among my own **sent**
    /// messages (see Task 2's partial unique index and its doc comment) — a
    /// received message can legitimately carry a `localMessageId` chosen by
    /// a different sender's device that coincides with one of mine. This
    /// lookup is scoped to `direction = .send` for exactly that reason: it
    /// must never return/touch a received message as a side effect of an
    /// unrelated collision.
    public func message(localMessageId: Int64) throws -> StoredMessage? {
        try dbQueue.read { db in
            try StoredMessage
                .filter(Column("localMessageId") == localMessageId)
                .filter(Column("direction") == MessageDirection.send.rawValue)
                .fetchOne(db)
        }
    }

    /// Looks up a message by server-assigned `messageUid` — used by
    /// `IMMessaging`'s receive path to dedup pulled messages against ones
    /// already stored (pull windows can overlap). `messageUid == 0` means
    /// "not yet acked" and is shared by every pending sent message, so it
    /// would be ambiguous to look up — short-circuits to `nil`.
    public func message(uid: Int64) throws -> StoredMessage? {
        guard uid != 0 else { return nil }
        return try dbQueue.read { db in
            try StoredMessage.filter(Column("messageUid") == uid).fetchOne(db)
        }
    }

    public func messages(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        limit: Int = 50
    ) throws -> [StoredMessage] {
        try dbQueue.read { db in
            try StoredMessage
                .filter(Column("conversationType") == conversationType.rawValue)
                .filter(Column("target") == target)
                .filter(Column("line") == line)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Reactive "latest `limit` messages" query, ascending by time (oldest
    /// first) — the opposite order from `messages(...)` above, because this
    /// feeds a chat screen that renders top-to-bottom. Re-fires on any
    /// insert/update affecting this conversation (new sends, new receives,
    /// ack status changes). See `olderMessages` below for paging further
    /// back — this method's `limit` is fixed, not meant to grow as the user
    /// scrolls.
    public func messagesPublisher(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        limit: Int = 50
    ) -> AnyPublisher<[StoredMessage], Error> {
        ValueObservation
            .tracking { db in
                try StoredMessage
                    .filter(Column("conversationType") == conversationType.rawValue)
                    .filter(Column("target") == target)
                    .filter(Column("line") == line)
                    .order(Column("timestamp").desc, Column("id").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            .publisher(in: dbQueue, scheduling: .immediate)
            .map { Array($0.reversed()) }
            .eraseToAnyPublisher()
    }

    /// Scoped to `direction = .send` for the same reason as `message(localMessageId:)`
    /// above — without this, a colliding received-message `localMessageId`
    /// would also get its status silently overwritten by an unrelated ack.
    /// A `localMessageId` that doesn't match any sent row is a silent no-op
    /// (no row updated, no error) — this mirrors GRDB's own `db.execute`
    /// semantics (it doesn't report affected-row counts) and is acceptable
    /// for Phase 1's only caller (a future `SendMessageHandler` that already
    /// knows the row exists, having just inserted it itself).
    public func updateStatus(localMessageId: Int64, status: MessageStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE message SET status = ? WHERE localMessageId = ? AND direction = ?",
                arguments: [status.rawValue, localMessageId, MessageDirection.send.rawValue]
            )
        }
    }

    /// Scoped to `direction = .send`; see `updateStatus` above for why, and
    /// for the no-op-on-not-found behavior.
    public func updateMessageUid(localMessageId: Int64, messageUid: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE message SET messageUid = ? WHERE localMessageId = ? AND direction = ?",
                arguments: [messageUid, localMessageId, MessageDirection.send.rawValue]
            )
        }
    }
}
