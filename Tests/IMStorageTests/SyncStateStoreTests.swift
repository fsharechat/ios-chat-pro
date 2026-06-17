import XCTest
@testable import IMStorage

final class SyncStateStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: SyncStateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = SyncStateStore(dbQueue: database.dbQueue)
    }

    func test_get_beforeAnySet_returnsAllZeros() throws {
        let state = try store.get()
        XCTAssertEqual(state, StoredSyncState(msgHead: 0, friendHead: 0, friendRequestHead: 0, settingHead: 0))
    }

    func test_set_thenGet_returnsWhatWasSet() throws {
        try store.set(StoredSyncState(msgHead: 100, friendHead: 5, friendRequestHead: 2, settingHead: 3))

        XCTAssertEqual(try store.get(), StoredSyncState(msgHead: 100, friendHead: 5, friendRequestHead: 2, settingHead: 3))
    }

    func test_set_calledTwice_overwritesRatherThanDuplicating() throws {
        try store.set(StoredSyncState(msgHead: 100, friendHead: 5, friendRequestHead: 2, settingHead: 3))
        try store.set(StoredSyncState(msgHead: 200, friendHead: 6, friendRequestHead: 3, settingHead: 4))

        XCTAssertEqual(try store.get(), StoredSyncState(msgHead: 200, friendHead: 6, friendRequestHead: 3, settingHead: 4))

        let rowCount = try database.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState") }
        XCTAssertEqual(rowCount, 1)
    }
}
