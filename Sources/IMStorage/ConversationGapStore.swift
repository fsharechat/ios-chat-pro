import GRDB

/// 会话断层的记录与收尾，规则见服务端设计文档
/// `chat-server-pro/docs/superpowers/specs/2026-10-26-conversation-gap-sync-design.md`。
///
/// **Threading contract:** 与本代码库其余部分一致，没有内部加锁，
/// 必须从单一一致的队列调用。
public final class ConversationGapStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// 收到增量拉取的 gap 时调用。只有本地存在比 `beforeUid` 更早的消息才会形成空洞；
    /// 本地没有更早消息时，现有的"本地翻完再拉远程"已经能接上，不必记录。
    /// 返回是否写入了断层。
    @discardableResult
    public func record(conversationType: ConversationType, target: String, line: Int, beforeUid: Int64, db: Database) throws -> Bool {
        let hasOlder = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM message
                WHERE conversationType = ? AND target = ? AND line = ?
                  AND messageUid > 0 AND messageUid < ?
            )
            """, arguments: [conversationType.rawValue, target, line, beforeUid]) ?? false
        guard hasOlder else { return false }
        try StoredConversationGap(conversationType: conversationType, target: target, line: line, beforeUid: beforeUid).save(db)
        return true
    }

    public func gaps(conversationType: ConversationType, target: String, line: Int) throws -> [StoredConversationGap] {
        try dbQueue.read { db in
            try StoredConversationGap
                .filter(Column("conversationType") == conversationType.rawValue)
                .filter(Column("target") == target)
                .filter(Column("line") == line)
                .order(Column("beforeUid").desc)
                .fetchAll(db)
        }
    }

    /// 会话页只显示 `messageUid >= 返回值` 的消息（以及尚未 ack 的 uid 为 0 的消息），
    /// 避免把空洞两侧的消息拼在一起。取最高的那个普通断层：它下面的消息要等它补完才可见。
    /// 尾部断层缺的是最新的一段，不隐藏任何本地消息。
    public func visibleFloorUid(conversationType: ConversationType, target: String, line: Int) throws -> Int64? {
        try gaps(conversationType: conversationType, target: target, line: line)
            .first { !$0.isTail }?
            .beforeUid
    }

    public func hasTailGap(conversationType: ConversationType, target: String, line: Int) throws -> Bool {
        try gaps(conversationType: conversationType, target: target, line: line).contains { $0.isTail }
    }

    /// 断层下方那一段本地消息的顶部：补拉回来的消息 uid 不超过它即表示已经接上。
    /// 0 表示断层下方没有本地消息。
    public func localFloorUid(conversationType: ConversationType, target: String, line: Int, below beforeUid: Int64, db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            SELECT MAX(messageUid) FROM message
            WHERE conversationType = ? AND target = ? AND line = ?
              AND messageUid > 0 AND messageUid < ?
            """, arguments: [conversationType.rawValue, target, line, beforeUid]) ?? 0
    }

    /// 一页补拉落库后调用：已经接上本地（有 uid 不超过 `floorUid`）、服务端已到底
    /// （空页或不满一页）时删除断层，否则把断层下移到这一页最老的一条。
    public func resolveAfterFill(
        conversationType: ConversationType,
        target: String,
        line: Int,
        beforeUid: Int64,
        returnedUids: [Int64],
        requestedCount: Int,
        floorUid: Int64,
        db: Database
    ) throws {
        try StoredConversationGap
            .filter(Column("conversationType") == conversationType.rawValue)
            .filter(Column("target") == target)
            .filter(Column("line") == line)
            .filter(Column("beforeUid") == beforeUid)
            .deleteAll(db)
        guard let oldest = returnedUids.min(),
              returnedUids.count >= requestedCount,
              oldest > floorUid else { return }
        try StoredConversationGap(conversationType: conversationType, target: target, line: line, beforeUid: oldest).save(db)
    }

    public func deleteGaps(conversationType: ConversationType, target: String, line: Int, db: Database) throws {
        try StoredConversationGap
            .filter(Column("conversationType") == conversationType.rawValue)
            .filter(Column("target") == target)
            .filter(Column("line") == line)
            .deleteAll(db)
    }

    public func deleteAll(db: Database) throws {
        try StoredConversationGap.deleteAll(db)
    }
}
