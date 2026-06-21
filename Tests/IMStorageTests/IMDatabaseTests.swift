import XCTest
import GRDB
@testable import IMStorage

final class IMDatabaseTests: XCTestCase {
    func test_openInMemory_createsAllFourTables() throws {
        let database = try IMDatabase.openInMemory()

        let tableNames: Set<String> = try database.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }

        XCTAssertTrue(tableNames.contains("message"))
        XCTAssertTrue(tableNames.contains("conversation"))
        XCTAssertTrue(tableNames.contains("user"))
        XCTAssertTrue(tableNames.contains("syncState"))
    }

    func test_openInMemory_createsFriendRequestTable() throws {
        let database = try IMDatabase.openInMemory()
        let exists = try database.dbQueue.read { db in
            try db.tableExists("friendRequest")
        }
        XCTAssertTrue(exists)
    }

    func test_openInMemory_runningMigrationTwiceIsHarmless() throws {
        // Simulates app relaunch: a fresh IMDatabase instance against the same
        // (here, file-backed) path must not fail because the schema already exists.
        let path = NSTemporaryDirectory() + "imdatabase-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try IMDatabase.open(atPath: path)
        let second = try IMDatabase.open(atPath: path) // must not throw

        let tableNames: Set<String> = try second.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        XCTAssertTrue(tableNames.contains("message"))
    }

    func test_messageIndexExists_forConversationPagination() throws {
        let database = try IMDatabase.openInMemory()

        let indexNames: [String] = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'message'")
        }

        XCTAssertTrue(indexNames.contains("message_on_conversation_timestamp"))
    }

    private func insertMessage(_ db: Database, localMessageId: Int, direction: MessageDirection) throws {
        try db.execute(
            sql: """
                INSERT INTO message
                    (localMessageId, messageUid, conversationType, target, line, "from", contentType, timestamp, status, direction)
                VALUES
                    (?, 0, ?, 'someTarget', 0, 'someSender', ?, ?, ?, ?)
                """,
            arguments: [
                localMessageId,
                ConversationType.single.rawValue,
                MessageContentType.text.rawValue,
                Int64(Date().timeIntervalSince1970 * 1000),
                MessageStatus.sent.rawValue,
                direction.rawValue,
            ]
        )
    }

    func test_localMessageIdUniqueness_isEnforcedOnlyAmongSentMessages() throws {
        let database = try IMDatabase.openInMemory()
        let sharedLocalMessageId = 1234567890

        // Two sent (direction = .send) messages sharing a localMessageId must
        // collide: this is the dedup scenario the partial unique index exists
        // to protect (matching my own pending send against a server ack/redelivery).
        try database.dbQueue.write { db in
            try self.insertMessage(db, localMessageId: sharedLocalMessageId, direction: .send)
        }
        XCTAssertThrowsError(
            try database.dbQueue.write { db in
                try self.insertMessage(db, localMessageId: sharedLocalMessageId, direction: .send)
            }
        ) { error in
            guard let dbError = error as? DatabaseError else {
                XCTFail("Expected a DatabaseError, got \(error)")
                return
            }
            XCTAssertEqual(dbError.resultCode, .SQLITE_CONSTRAINT)
        }
    }

    func test_localMessageIdUniqueness_doesNotApplyAcrossSendAndReceive() throws {
        let database = try IMDatabase.openInMemory()
        let sharedLocalMessageId = 987654321

        // A received message may legitimately carry a localMessageId that
        // collides with one I used myself for a sent message — there is no
        // cross-device coordination preventing that. The partial index must
        // not reject this.
        try database.dbQueue.write { db in
            try self.insertMessage(db, localMessageId: sharedLocalMessageId, direction: .send)
            try self.insertMessage(db, localMessageId: sharedLocalMessageId, direction: .receive)
        }

        let count = try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE localMessageId = ?", arguments: [sharedLocalMessageId])
        }
        XCTAssertEqual(count, 2)
    }
}
