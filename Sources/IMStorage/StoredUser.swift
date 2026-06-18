import GRDB

/// Static contact-list cache. Only the fields Phase 1's contact list and
/// message sender display actually need (`name`, `displayName`, `portrait`,
/// `mobile`, `gender`, `updateDt`) — `ProtoUserInfo`'s richer profile fields
/// (`email`, `address`, `company`, `social`, `extra`, `friendAlias`,
/// `groupAlias`) are deliberately omitted (YAGNI); add them later if a
/// future phase's profile screen needs them — purely additive, no migration
/// of existing columns required.
///
/// `isFriend` (Plan F) tracks contact-list membership, populated by
/// `UserStore.replaceFriendList(uids:)` only — never touched by
/// `upsertProfile(...)`, which only ever writes the profile columns. A row
/// can exist with `isFriend == false` (e.g. someone who messaged you but
/// isn't a friend, whose profile got resolved for display purposes) or with
/// every profile field still `nil` (a friend-list UID not yet resolved via
/// `UPUI`) — both are valid, expected states, not bugs.
public struct StoredUser: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "user"

    public var uid: String
    public var name: String?
    public var displayName: String?
    public var portrait: String?
    public var mobile: String?
    public var gender: Int
    public var updateDt: Int64
    public var isFriend: Bool

    public init(uid: String, name: String?, displayName: String?, portrait: String?, mobile: String?, gender: Int, updateDt: Int64, isFriend: Bool = false) {
        self.uid = uid
        self.name = name
        self.displayName = displayName
        self.portrait = portrait
        self.mobile = mobile
        self.gender = gender
        self.updateDt = updateDt
        self.isFriend = isFriend
    }
}
