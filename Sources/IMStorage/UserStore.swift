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
}
