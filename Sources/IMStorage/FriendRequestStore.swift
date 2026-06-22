// Sources/IMStorage/FriendRequestStore.swift
import GRDB
import Combine

/// Friend requests are scoped to "where I am the recipient" entirely on the
/// server side — the `.frp` pull endpoint only ever returns requests sent
/// *to* the current user, mirroring how Android's own friend-request inbox
/// never shows outgoing requests. Every row in this local table therefore
/// already satisfies `toUid == myUid` by construction, so no method here
/// takes a `myUid` parameter.
public final class FriendRequestStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ request: StoredFriendRequest) throws {
        try dbQueue.write { db in
            try request.save(db)
        }
    }

    public func markAccepted(fromUid: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE friendRequest SET status = ? WHERE fromUid = ?",
                arguments: [StoredFriendRequest.Status.accepted, fromUid]
            )
        }
    }

    public func incomingRequestsPublisher() -> AnyPublisher<[StoredFriendRequest], Error> {
        ValueObservation
            .tracking { db in try StoredFriendRequest.order(Column("updateDt").desc).fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    public func unreadIncomingCountPublisher() -> AnyPublisher<Int, Error> {
        ValueObservation
            .tracking { db in
                try StoredFriendRequest
                    .filter(Column("status") == StoredFriendRequest.Status.pending)
                    .filter(Column("toReadStatus") == false)
                    .fetchCount(db)
            }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }
}
