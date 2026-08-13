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
    /// many of these into one transaction. Returns the conversation's
    /// `isMuted` flag *after* the upsert (mute status itself is never
    /// changed here) — `ReceiveMessageHandler` uses it to decide whether a
    /// newly persisted message should trigger a local vibrate/sound alert,
    /// at no extra query cost since this method already `fetchOne`s the row.
    @discardableResult
    public func recordIncomingMessage(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        messageUid: Int64,
        timestamp: Int64,
        incrementUnread: Bool,
        incrementMention: Bool = false,
        db: Database
    ) throws -> Bool {
        let existing = try StoredConversation
            .filter(Column("conversationType") == conversationType.rawValue)
            .filter(Column("target") == target)
            .filter(Column("line") == line)
            .fetchOne(db)

        var conversation: StoredConversation
        if let existing = existing {
            conversation = existing
        } else {
            // 首次为这个会话建行——没有旧行可沿用 isTop/isMuted，改从 userSetting
            // 播种。冷启动时 UG 应答常常先于这条消息落库到达(AppEnvironment 在
            // pullMessagesSinceLastSync() 之前就发 UG)，那时投影是空操作，全靠
            // 这里补上，否则重装后置顶/免打扰会永久丢失。
            let key = UserSettingKeys.conversationKey(conversationType: conversationType, line: line, target: target)
            let isTop = try StoredUserSetting
                .filter(Column("scope") == UserSettingKeys.Scope.conversationTop && Column("key") == key)
                .fetchOne(db)?.value == "1"
            let isMuted = try StoredUserSetting
                .filter(Column("scope") == UserSettingKeys.Scope.conversationSilent && Column("key") == key)
                .fetchOne(db)?.value == "1"
            conversation = StoredConversation(conversationType: conversationType, target: target, line: line, isTop: isTop, isMuted: isMuted)
        }
        conversation.lastMessageUid = messageUid
        conversation.timestamp = timestamp
        if incrementUnread {
            conversation.unreadCount += 1
        }
        if incrementMention {
            conversation.unreadMentionCount += 1
        }
        try conversation.save(db)
        return conversation.isMuted
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
            try self.setTop(isTop, conversationType: conversationType, target: target, line: line, db: db)
        }
    }

    /// 与上面相同，跑在调用方管理的事务里 —— 见 `UserSettingSyncHandler`，
    /// 它要把设置写入与派生列投影合并成一次事务。
    public func setTop(_ isTop: Bool, conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws {
        try db.execute(
            sql: "UPDATE conversation SET isTop = ? WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [isTop, conversationType.rawValue, target, line]
        )
    }

    public func setDraft(_ draft: String?, conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET draft = ? WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [draft, conversationType.rawValue, target, line]
            )
        }
    }

    public func setMuted(_ isMuted: Bool, conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try self.setMuted(isMuted, conversationType: conversationType, target: target, line: line, db: db)
        }
    }

    /// 与上面相同，跑在调用方管理的事务里。
    public func setMuted(_ isMuted: Bool, conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws {
        try db.execute(
            sql: "UPDATE conversation SET isMuted = ? WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [isMuted, conversationType.rawValue, target, line]
        )
    }

    public func deleteConversation(conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in try self.deleteConversation(conversationType: conversationType, target: target, line: line, db: db) }
    }

    /// Same as `deleteConversation(...)`, run against a caller-managed
    /// transaction — see `ReceiveMessageHandler`, which removes a group's
    /// conversation in the same write transaction as persisting the
    /// notification that triggered it (dismiss/self-quit/self-kicked).
    public func deleteConversation(conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM conversation WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [conversationType.rawValue, target, line]
        )
    }

    public func resetLastMessage(conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            guard var conversation = try StoredConversation
                .filter(Column("conversationType") == conversationType.rawValue)
                .filter(Column("target") == target)
                .filter(Column("line") == line)
                .fetchOne(db) else { return }
            conversation.lastMessageUid = nil
            try conversation.save(db)
        }
    }
}
