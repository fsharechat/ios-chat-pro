/// Single entry point: construct one `IMStorage`, get all four stores
/// sharing the same underlying SQLite connection.
public final class IMStorage {
    public let messages: MessageStore
    public let conversations: ConversationStore
    public let users: UserStore
    public let syncState: SyncStateStore

    private init(database: IMDatabase) {
        messages = MessageStore(dbQueue: database.dbQueue)
        conversations = ConversationStore(dbQueue: database.dbQueue)
        users = UserStore(dbQueue: database.dbQueue)
        syncState = SyncStateStore(dbQueue: database.dbQueue)
    }

    public static func open(atPath path: String) throws -> IMStorage {
        IMStorage(database: try IMDatabase.open(atPath: path))
    }

    public static func openInMemory() throws -> IMStorage {
        IMStorage(database: try IMDatabase.openInMemory())
    }
}
