import GRDB

/// Mirrors `ConnectAckPayload`'s sync-head fields (`msg_head`, `friend_head`,
/// `friend_rq_head`, `setting_head`) — see `ConnectAckHandler` (Plan B). A
/// future Plan D handler reads/writes this to drive incremental sync after
/// reconnecting.
public struct StoredSyncState: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "syncState"

    public var id: Int = 1
    public var msgHead: Int64
    public var friendHead: Int64
    public var friendRequestHead: Int64
    public var settingHead: Int64

    public init(msgHead: Int64, friendHead: Int64, friendRequestHead: Int64, settingHead: Int64) {
        self.msgHead = msgHead
        self.friendHead = friendHead
        self.friendRequestHead = friendRequestHead
        self.settingHead = settingHead
    }
}

public final class SyncStateStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func get() throws -> StoredSyncState {
        try dbQueue.read { db in
            try StoredSyncState.fetchOne(db, key: 1) ?? StoredSyncState(msgHead: 0, friendHead: 0, friendRequestHead: 0, settingHead: 0)
        }
    }

    public func set(_ state: StoredSyncState) throws {
        var state = state
        state.id = 1
        try dbQueue.write { db in try state.save(db) }
    }
}
