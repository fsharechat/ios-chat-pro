import GRDB
import Combine

/// CRUD + Combine observation for `StoredGroup`/`StoredGroupMember`.
public final class GroupStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsertGroup(_ group: StoredGroup) throws {
        try dbQueue.write { db in
            var updated = group
            if let existing = try StoredGroup.fetchOne(db, key: group.groupId) {
                updated.isFav = existing.isFav
            } else {
                // 首次为这个 groupId 建行(例如 .gpgi 应答先于/晚于 UG 到达都可能触发)——
                // 群行不存在时没有旧值可沿用，改从 userSetting 播种，否则重装后 UG
                // 投影的 isFav 会被这里悄悄用 false 盖掉（源头是入参 group.isFav
                // 默认 false，见 GroupInfoSyncHandler 不传 isFav:）。
                updated.isFav = try StoredUserSetting
                    .filter(Column("scope") == UserSettingKeys.Scope.favoriteGroup
                            && Column("key") == group.groupId)
                    .fetchOne(db)?.value == "1"
            }
            try updated.save(db)
        }
    }

    public func group(groupId: String) throws -> StoredGroup? {
        try dbQueue.read { db in try self.group(groupId: groupId, db: db) }
    }

    /// 与上面相同，跑在调用方管理的事务里。
    public func group(groupId: String, db: Database) throws -> StoredGroup? {
        try StoredGroup.fetchOne(db, key: groupId)
    }

    /// All groups, re-fired on any insert/update to the `group` table —
    /// unlike `groupPublisher(groupId:)`, which only tracks one row. Lets a
    /// list (e.g. `ConversationListViewModel`) re-derive its rows once a
    /// group's name/portrait resolves asynchronously after the list's own
    /// driving publisher already fired.
    public func groupsPublisher() -> AnyPublisher<[StoredGroup], Error> {
        ValueObservation
            .tracking { db in try StoredGroup.fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    public func groupPublisher(groupId: String) -> AnyPublisher<StoredGroup?, Error> {
        ValueObservation
            .tracking { db in try StoredGroup.fetchOne(db, key: groupId) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    public func upsertMember(_ member: StoredGroupMember) throws {
        try dbQueue.write { db in try member.save(db) }
    }

    private static func activeMembersQuery(groupId: String) -> QueryInterfaceRequest<StoredGroupMember> {
        StoredGroupMember
            .filter(Column("groupId") == groupId)
            .filter(Column("memberType") != GroupMemberType.removed.rawValue)
    }

    public func members(groupId: String) throws -> [StoredGroupMember] {
        try dbQueue.read { db in try Self.activeMembersQuery(groupId: groupId).fetchAll(db) }
    }

    public func membersPublisher(groupId: String) -> AnyPublisher<[StoredGroupMember], Error> {
        ValueObservation
            .tracking { db in try Self.activeMembersQuery(groupId: groupId).fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    public func favGroupsPublisher() -> AnyPublisher<[StoredGroup], Error> {
        ValueObservation
            .tracking { db in try StoredGroup.filter(Column("isFav") == true).fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    public func setFav(_ isFav: Bool, groupId: String) throws {
        try dbQueue.write { db in try self.setFav(isFav, groupId: groupId, db: db) }
    }

    /// 与上面相同，跑在调用方管理的事务里。
    public func setFav(_ isFav: Bool, groupId: String, db: Database) throws {
        try db.execute(
            sql: "UPDATE groupInfo SET isFav = ? WHERE groupId = ?",
            arguments: [isFav, groupId]
        )
    }

    /// Resets every group's `isFav` flag — used by `IMStorage.clearSessionData()`
    /// on logout. `isFav` is now synced from the server via scope 6 (see
    /// `UserSettingSyncService`), with `userSetting` as the source of truth
    /// and this column its projection, so it's still the one `groupInfo`
    /// column that must be explicitly wiped rather than left for the next
    /// login's sync to overwrite. Takes `db:` rather than opening its own write, so
    /// `clearSessionData()` can run it in the same transaction as its other
    /// table clears.
    public func clearAllFav(db: Database) throws {
        try db.execute(sql: "UPDATE groupInfo SET isFav = 0")
    }
}
