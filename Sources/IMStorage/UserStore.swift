import GRDB
import Combine

public final class UserStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ user: StoredUser) throws {
        try dbQueue.write { db in try user.save(db) }
    }

    public func user(uid: String) throws -> StoredUser? {
        try dbQueue.read { db in try StoredUser.fetchOne(db, key: uid) }
    }

    /// Sorted with NULL `displayName`s last, not first: plain `ORDER BY
    /// displayName` puts SQLite NULLs ahead of every real name, which would
    /// float not-yet-synced contacts to the top of the list. `displayName
    /// IS NULL` evaluates to 0 for a populated name and 1 for NULL, so
    /// ordering by that first pushes NULLs to the end before the secondary
    /// alphabetical sort takes over. Plain SQL (rather than the query
    /// interface) here since it's the simplest way to express this exact,
    /// well-known SQLite "NULLs last" idiom without depending on a specific
    /// GRDB query-interface ordering-expression API.
    private static let allUsersOrderedSQL = "SELECT * FROM user ORDER BY displayName IS NULL, displayName"

    public func allUsers() throws -> [StoredUser] {
        try dbQueue.read { db in
            try StoredUser.fetchAll(db, sql: Self.allUsersOrderedSQL)
        }
    }

    public func usersPublisher() -> AnyPublisher<[StoredUser], Error> {
        ValueObservation
            .tracking { db in try StoredUser.fetchAll(db, sql: Self.allUsersOrderedSQL) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    private static let friendsOrderedSQL = "SELECT * FROM user WHERE isFriend = 1 ORDER BY displayName IS NULL, displayName"

    public func friends() throws -> [StoredUser] {
        try dbQueue.read { db in
            try StoredUser.fetchAll(db, sql: Self.friendsOrderedSQL)
        }
    }

    public func friendsPublisher() -> AnyPublisher<[StoredUser], Error> {
        ValueObservation
            .tracking { db in try StoredUser.fetchAll(db, sql: Self.friendsOrderedSQL) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    /// Replaces the entire friend-UID set: every currently-`isFriend`
    /// user not in `uids` is unflagged (not deleted — their cached profile,
    /// if any, is kept), and every uid in `uids` is flagged, creating a
    /// placeholder row (all profile fields `nil`) if none exists yet.
    /// Mirrors Android's `setFriendArr(refresh: true)` full-replace
    /// semantics.
    public func replaceFriendList(uids: [String]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE user SET isFriend = 0")
            for uid in uids {
                if var existing = try StoredUser.fetchOne(db, key: uid) {
                    existing.isFriend = true
                    try existing.save(db)
                } else {
                    try StoredUser(uid: uid, name: nil, displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true).save(db)
                }
            }
        }
    }

    /// Merges profile fields into the row for `uid`, creating it if it
    /// doesn't exist yet. Never touches `isFriend` — a naive whole-row
    /// upsert here would be a real bug (it would clobber friend status on
    /// every profile refresh).
    public func upsertProfile(uid: String, name: String?, displayName: String?, portrait: String?, mobile: String?, gender: Int, updateDt: Int64) throws {
        try dbQueue.write { db in try Self.saveProfile(uid: uid, name: name, displayName: displayName, portrait: portrait, mobile: mobile, gender: gender, updateDt: updateDt, db: db) }
    }

    public struct ProfileUpdate {
        public let uid: String
        public let name: String?
        public let displayName: String?
        public let portrait: String?
        public let mobile: String?
        public let gender: Int
        public let updateDt: Int64

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

    /// Same merge semantics as `upsertProfile(...)`, applied to every entry
    /// in a single write transaction — one `friendsPublisher`/`usersPublisher`
    /// emission for the whole batch instead of one per entry. Matters when a
    /// single `UPUI` response resolves dozens/hundreds of profiles at once
    /// (e.g. right after a fresh friend-list sync): without batching, each
    /// per-entry transaction re-triggers a full re-query and re-sort
    /// downstream in `ContactListViewModel`.
    public func upsertProfiles(_ updates: [ProfileUpdate]) throws {
        try dbQueue.write { db in
            for update in updates {
                try Self.saveProfile(uid: update.uid, name: update.name, displayName: update.displayName, portrait: update.portrait, mobile: update.mobile, gender: update.gender, updateDt: update.updateDt, db: db)
            }
        }
    }

    private static func saveProfile(uid: String, name: String?, displayName: String?, portrait: String?, mobile: String?, gender: Int, updateDt: Int64, db: Database) throws {
        var user = try StoredUser.fetchOne(db, key: uid) ?? StoredUser(uid: uid, name: nil, displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        user.name = name
        user.displayName = displayName
        user.portrait = portrait
        user.mobile = mobile
        user.gender = gender
        user.updateDt = updateDt
        try user.save(db)
    }
}
