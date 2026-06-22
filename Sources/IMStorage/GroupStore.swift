import GRDB
import Combine

/// CRUD + Combine observation for `StoredGroup`/`StoredGroupMember`.
public final class GroupStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsertGroup(_ group: StoredGroup) throws {
        try dbQueue.write { db in try group.save(db) }
    }

    public func group(groupId: String) throws -> StoredGroup? {
        try dbQueue.read { db in try StoredGroup.fetchOne(db, key: groupId) }
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
}
