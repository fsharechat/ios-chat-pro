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

    /// One-shot (non-reactive) page of history strictly before
    /// `(beforeTimestamp, beforeId)` — `id` (GRDB's autoincrement primary
    /// key) breaks ties when multiple messages share the same millisecond
    /// timestamp, which plain `timestamp` comparison can't disambiguate.
    /// Returns ascending order (oldest first), matching `messagesPublisher`'s
    /// contract, so callers can simply prepend the result to what they
    /// already have.
    public func olderMessages(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        beforeTimestamp: Int64,
        beforeId: Int64,
        limit: Int = 50
    ) throws -> [StoredMessage] {
        try dbQueue.read { db in
            let rows = try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message
                WHERE conversationType = ? AND target = ? AND line = ?
                  AND (timestamp < ? OR (timestamp = ? AND id < ?))
                ORDER BY timestamp DESC, id DESC
                LIMIT ?
                """, arguments: [
                    conversationType.rawValue, target, line,
                    beforeTimestamp, beforeTimestamp, beforeId,
                    limit,
                ])
            return Array(rows.reversed())
        }
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

    /// Updates a previously-inserted row's content in place, keyed by its
    /// GRDB autoincrement `id` — deliberately **not** `localMessageId`,
    /// which (per `message(localMessageId:)`'s doc comment above) is only
    /// guaranteed unique among my own sent messages; a received row's
    /// `localMessageId` can coincide with one of mine. `id` is the only
    /// column that unambiguously identifies "this exact row" regardless of
    /// `direction`, which matters here because a call-record bubble exists
    /// on both the caller's and callee's side and `IMCall.CallManager`
    /// updates whichever one is local to this device. A no-op (no error)
    /// if no row with this `id` exists.
    public func updateContent(id: Int64, content: MessageContent) throws {
        try dbQueue.write { db in
            guard var existing = try StoredMessage.fetchOne(db, key: id) else { return }
            existing.setContent(content)
            try existing.update(db)
        }
    }
}
