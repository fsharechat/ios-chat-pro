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
}
