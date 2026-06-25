import GRDB

/// Single entry point: construct one `IMStorage`, get all six stores
/// sharing the same underlying SQLite connection.
///
/// Otherwise intentionally does not expose the underlying
/// `IMDatabase`/`DatabaseQueue` beyond the test-only escape hatch below —
/// nothing in production scope needs raw connection access. If a future
/// need arises (backup/export, maintenance tasks, another store), add a
/// narrow accessor here deliberately rather than reaching around the
/// facade; doing so is a non-breaking, additive change since every store
/// already takes a plain `DatabaseQueue`, not an `IMStorage`.
public final class IMStorage {
    public let messages: MessageStore
    public let conversations: ConversationStore
    public let users: UserStore
    public let syncState: SyncStateStore
    public let friendRequests: FriendRequestStore
    public let groups: GroupStore

    /// Test-only escape hatch for asserting on raw table contents. Not for
    /// production use — production code always goes through one of the
    /// stores above.
    public var dbQueueForTesting: DatabaseQueue { database.dbQueue }

    /// The "narrow accessor" this type's doc comment above reserves for
    /// when a future need arises: runs `updates` inside a single write
    /// transaction against the shared connection, so writes that span
    /// multiple stores (e.g. `messages` + `conversations` + `syncState`,
    /// all touched per pulled message) commit atomically and any reactive
    /// publisher observing the affected tables fires once for the whole
    /// batch, not once per row. Callers use each store's `db:`-taking
    /// overload from inside `updates` — see `ReceiveMessageHandler`
    /// (`IMMessaging`), the first caller.
    public func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try database.dbQueue.write(updates)
    }

    /// Clears the locally cached chat history on logout, matching Android's
    /// `SqliteDatabaseStore.stop()` scope exactly: deletes every row from
    /// `message`/`conversation` and resets `syncState` back to its all-zero
    /// defaults — the iOS equivalent of Android also `clear()`-ing the
    /// SharedPreferences that hold its sync cursors. `users`/`groups`/
    /// `friendRequests` are deliberately left untouched — Android doesn't
    /// clear them either, and the next login's normal sync flow overwrites
    /// them anyway. Without the `syncState` reset, logging into a different
    /// account on the same device would resume incremental sync from the
    /// previous account's cursors, silently dropping messages.
    public func clearSessionData() throws {
        try database.dbQueue.write { db in
            try StoredMessage.deleteAll(db)
            try StoredConversation.deleteAll(db)
            try StoredSyncState(msgHead: 0, friendHead: 0, friendRequestHead: 0, settingHead: 0).save(db)
        }
    }

    private let database: IMDatabase

    private init(database: IMDatabase) {
        self.database = database
        messages = MessageStore(dbQueue: database.dbQueue)
        conversations = ConversationStore(dbQueue: database.dbQueue)
        users = UserStore(dbQueue: database.dbQueue)
        syncState = SyncStateStore(dbQueue: database.dbQueue)
        friendRequests = FriendRequestStore(dbQueue: database.dbQueue)
        groups = GroupStore(dbQueue: database.dbQueue)
    }

    public static func open(atPath path: String) throws -> IMStorage {
        IMStorage(database: try IMDatabase.open(atPath: path))
    }

    public static func openInMemory() throws -> IMStorage {
        IMStorage(database: try IMDatabase.openInMemory())
    }
}
