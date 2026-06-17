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

    public func allUsers() throws -> [StoredUser] {
        try dbQueue.read { db in
            try StoredUser.order(Column("displayName")).fetchAll(db)
        }
    }

    public func usersPublisher() -> AnyPublisher<[StoredUser], Error> {
        ValueObservation
            .tracking { db in try StoredUser.order(Column("displayName")).fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }
}
