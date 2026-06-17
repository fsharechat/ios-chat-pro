import GRDB

/// Static contact-list cache. Only the fields Phase 1's contact list and
/// message sender display actually need (`name`, `displayName`, `portrait`,
/// `mobile`, `gender`, `updateDt`) — `ProtoUserInfo`'s richer profile fields
/// (`email`, `address`, `company`, `social`, `extra`, `friendAlias`,
/// `groupAlias`) are deliberately omitted (YAGNI); add them later if a
/// future phase's profile screen needs them — purely additive, no migration
/// of existing columns required.
public struct StoredUser: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "user"

    public var uid: String
    public var name: String?
    public var displayName: String?
    public var portrait: String?
    public var mobile: String?
    public var gender: Int
    public var updateDt: Int64

    public init(uid: String, name: String?, displayName: String?, portrait: String?, mobile: String?, gender: Int, updateDt: Int64) {
        self.uid = uid
        self.name = name
        self.displayName = displayName
        self.portrait = portrait
        self.mobile = mobile
        self.gender = gender
        self.updateDt = updateDt
    }
}
