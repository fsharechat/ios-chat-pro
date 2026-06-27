import GRDB

/// One row per group the local user is a member of. Discovered passively
/// (no "list my groups" wire API exists) — created/updated by `IMGroups`'s
/// `GroupInfoSyncHandler` whenever a `.gpgi` response or a group
/// notification message arrives for this `groupId`.
public struct StoredGroup: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "groupInfo"

    public var groupId: String
    public var name: String
    public var portrait: String?
    public var owner: String?
    public var groupType: GroupType
    public var memberCount: Int
    public var updateDt: Int64
    public var memberUpdateDt: Int64
    public var isFav: Bool

    public init(
        groupId: String,
        name: String,
        portrait: String?,
        owner: String?,
        groupType: GroupType,
        memberCount: Int,
        updateDt: Int64,
        memberUpdateDt: Int64,
        isFav: Bool = false
    ) {
        self.groupId = groupId
        self.name = name
        self.portrait = portrait
        self.owner = owner
        self.groupType = groupType
        self.memberCount = memberCount
        self.updateDt = updateDt
        self.memberUpdateDt = memberUpdateDt
        self.isFav = isFav
    }
}

/// One row per (group, member) pair. `memberType == .removed` rows are kept
/// (not deleted) so a stale local cache can tell "never knew about this
/// member" apart from "knows they were removed" — `GroupStore.members(groupId:)`
/// filters `.removed` out for display.
public struct StoredGroupMember: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "groupMember"

    public var groupId: String
    public var memberId: String
    public var memberType: GroupMemberType
    public var updateDt: Int64

    public init(groupId: String, memberId: String, memberType: GroupMemberType, updateDt: Int64) {
        self.groupId = groupId
        self.memberId = memberId
        self.memberType = memberType
        self.updateDt = updateDt
    }
}
