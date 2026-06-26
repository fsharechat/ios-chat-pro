import GRDB
import Combine

/// CRUD + Combine observation for `StoredConversation`. The "conversation
/// list" screen (Plan D) subscribes to `conversationsPublisher()`.
public final class ConversationStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func conversation(conversationType: ConversationType, target: String, line: Int = 0) throws -> StoredConversation? {
        try dbQueue.read { db in
            try StoredConversation
                .filter(Column("conversationType") == conversationType.rawValue)
                .filter(Column("target") == target)
                .filter(Column("line") == line)
                .fetchOne(db)
        }
    }

    public func conversations() throws -> [StoredConversation] {
        try dbQueue.read { db in
            try StoredConversation.order(Column("isTop").desc, Column("timestamp").desc).fetchAll(db)
        }
    }

    public func conversationsPublisher() -> AnyPublisher<[StoredConversation], Error> {
        ValueObservation
            .tracking { db in try StoredConversation.order(Column("isTop").desc, Column("timestamp").desc).fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    /// Upserts the conversation row for an incoming or outgoing message:
    /// updates `lastMessageUid`/`timestamp`, and optionally bumps
    /// `unreadCount` (callers pass `incrementUnread: false` when recording
    /// their own sent message — it shouldn't mark their own conversation
    /// unread).
    public func recordIncomingMessage(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        messageUid: Int64,
        timestamp: Int64,
        incrementUnread: Bool,
        incrementMention: Bool = false
    ) throws {
        try dbQueue.write { db in
            try self.recordIncomingMessage(
                conversationType: conversationType, target: target, line: line,
                messageUid: messageUid, timestamp: timestamp,
                incrementUnread: incrementUnread, incrementMention: incrementMention, db: db
            )
        }
    }

    /// Same as `recordIncomingMessage(...)`, run against a caller-managed
    /// transaction — see `ReceiveMessageHandler`, the first caller batching
    /// many of these into one transaction.
    public func recordIncomingMessage(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        messageUid: Int64,
        timestamp: Int64,
        incrementUnread: Bool,
        incrementMention: Bool = false,
        db: Database
    ) throws {
        let existing = try StoredConversation
            .filter(Column("conversationType") == conversationType.rawValue)
            .filter(Column("target") == target)
            .filter(Column("line") == line)
            .fetchOne(db)

        var conversation = existing ?? StoredConversation(conversationType: conversationType, target: target, line: line)
        conversation.lastMessageUid = messageUid
        conversation.timestamp = timestamp
        if incrementUnread {
            conversation.unreadCount += 1
        }
        if incrementMention {
            conversation.unreadMentionCount += 1
        }
        try conversation.save(db)
    }

    /// Re-saves the existing conversation row without changing `timestamp`,
    /// `lastMessageUid`, or `unreadCount`. Used by recall to trigger
    /// `conversationsPublisher` without corrupting list ordering.
    /// No-op when the conversation row does not yet exist.
    public func touchConversation(conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws {
        guard let conversation = try StoredConversation
            .filter(Column("conversationType") == conversationType.rawValue)
            .filter(Column("target") == target)
            .filter(Column("line") == line)
            .fetchOne(db) else { return }
        try conversation.save(db)
    }

    public func clearUnread(conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET unreadCount = 0, unreadMentionCount = 0 WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [conversationType.rawValue, target, line]
            )
        }
    }

    public func setTop(_ isTop: Bool, conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET isTop = ? WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [isTop, conversationType.rawValue, target, line]
            )
        }
    }

    public func setDraft(_ draft: String?, conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET draft = ? WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [draft, conversationType.rawValue, target, line]
            )
        }
    }
}
