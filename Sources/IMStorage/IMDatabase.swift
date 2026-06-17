import GRDB

/// Owns the SQLite connection and schema migration. Construct via
/// `open(atPath:)` (real file, for the app) or `openInMemory()` (tests).
public final class IMDatabase {
    public let dbQueue: DatabaseQueue

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    public static func open(atPath path: String) throws -> IMDatabase {
        try IMDatabase(dbQueue: DatabaseQueue(path: path))
    }

    public static func openInMemory() throws -> IMDatabase {
        try IMDatabase(dbQueue: DatabaseQueue())
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_createSchema") { db in
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("localMessageId", .integer).notNull()
                t.column("messageUid", .integer).notNull().defaults(to: 0)
                t.column("conversationType", .integer).notNull()
                t.column("target", .text).notNull()
                t.column("line", .integer).notNull().defaults(to: 0)
                t.column("from", .text).notNull()
                t.column("contentType", .integer).notNull()
                t.column("textContent", .text)
                t.column("searchableContent", .text)
                t.column("mediaRemoteURL", .text)
                t.column("mediaLocalPath", .text)
                t.column("mediaThumbnail", .blob)
                t.column("timestamp", .integer).notNull()
                t.column("status", .integer).notNull()
                t.column("direction", .integer).notNull()
            }
            try db.create(
                index: "message_on_conversation_timestamp",
                on: "message",
                columns: ["conversationType", "target", "line", "timestamp"]
            )
            try db.create(index: "message_on_local_message_id", on: "message", columns: ["localMessageId"])

            try db.create(table: "conversation") { t in
                t.column("conversationType", .integer).notNull()
                t.column("target", .text).notNull()
                t.column("line", .integer).notNull().defaults(to: 0)
                t.column("lastMessageUid", .integer)
                t.column("timestamp", .integer).notNull().defaults(to: 0)
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("isTop", .boolean).notNull().defaults(to: false)
                t.column("isMuted", .boolean).notNull().defaults(to: false)
                t.column("draft", .text)
                t.primaryKey(["conversationType", "target", "line"])
            }

            try db.create(table: "user") { t in
                t.column("uid", .text).notNull().primaryKey()
                t.column("name", .text)
                t.column("displayName", .text)
                t.column("portrait", .text)
                t.column("mobile", .text)
                t.column("gender", .integer).notNull().defaults(to: 0)
                t.column("updateDt", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "syncState") { t in
                t.column("id", .integer).notNull().primaryKey()
                t.column("msgHead", .integer).notNull().defaults(to: 0)
                t.column("friendHead", .integer).notNull().defaults(to: 0)
                t.column("friendRequestHead", .integer).notNull().defaults(to: 0)
                t.column("settingHead", .integer).notNull().defaults(to: 0)
            }
        }
        return migrator
    }
}
