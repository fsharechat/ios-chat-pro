import GRDB

public struct StoredFriendRequest: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "friendRequest"

    public enum Status {
        public static let pending = 0
        public static let accepted = 1
    }

    public var fromUid: String
    public var toUid: String
    public var reason: String
    public var status: Int
    public var updateDt: Int64
    public var fromReadStatus: Bool
    public var toReadStatus: Bool

    public init(fromUid: String, toUid: String, reason: String, status: Int, updateDt: Int64, fromReadStatus: Bool, toReadStatus: Bool) {
        self.fromUid = fromUid
        self.toUid = toUid
        self.reason = reason
        self.status = status
        self.updateDt = updateDt
        self.fromReadStatus = fromReadStatus
        self.toReadStatus = toReadStatus
    }
}
