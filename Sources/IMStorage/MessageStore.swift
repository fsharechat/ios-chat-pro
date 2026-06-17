import GRDB

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

    public func message(localMessageId: Int64) throws -> StoredMessage? {
        try dbQueue.read { db in
            try StoredMessage.filter(Column("localMessageId") == localMessageId).fetchOne(db)
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

    public func updateStatus(localMessageId: Int64, status: MessageStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE message SET status = ? WHERE localMessageId = ?",
                arguments: [status.rawValue, localMessageId]
            )
        }
    }

    public func updateMessageUid(localMessageId: Int64, messageUid: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE message SET messageUid = ? WHERE localMessageId = ?",
                arguments: [messageUid, localMessageId]
            )
        }
    }
}
