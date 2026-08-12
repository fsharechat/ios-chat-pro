import GRDB

/// **Threading contract:** 与本代码库其余部分一致，没有内部加锁，
/// 必须从单一一致的队列调用。
public final class UserSettingStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ settings: [StoredUserSetting]) throws {
        try dbQueue.write { db in try self.upsert(settings, db: db) }
    }

    /// 与 `upsert(_:)` 相同，跑在调用方管理的事务里 —— UG 拉取要把设置写入、
    /// 派生列投影、syncState 更新合并成一次事务，避免中间态被 UI 的 publisher 看到。
    public func upsert(_ settings: [StoredUserSetting], db: Database) throws {
        for setting in settings {
            try setting.save(db)
        }
    }

    public func value(scope: Int, key: String) throws -> String? {
        try dbQueue.read { db in
            try StoredUserSetting
                .filter(Column("scope") == scope && Column("key") == key)
                .fetchOne(db)?
                .value
        }
    }

    /// 只返回 value 为 "1" 的 key。取消操作写的是 "0"（tombstone）而非删除记录，
    /// 所以不能用「记录是否存在」判断是否生效。
    public func enabledKeys(scope: Int) throws -> [String] {
        try dbQueue.read { db in
            try StoredUserSetting
                .filter(Column("scope") == scope && Column("value") == "1")
                .fetchAll(db)
                .map(\.key)
        }
    }

    public func deleteAll(db: Database) throws {
        try StoredUserSetting.deleteAll(db)
    }
}
