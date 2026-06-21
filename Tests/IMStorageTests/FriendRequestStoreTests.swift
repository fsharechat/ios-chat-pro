// Tests/IMStorageTests/FriendRequestStoreTests.swift
import XCTest
import Combine
@testable import IMStorage

final class FriendRequestStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: FriendRequestStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = FriendRequestStore(dbQueue: database.dbQueue)
    }

    func test_upsert_thenIncomingRequestsPublisher_emitsTheRow() throws {
        let request = StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false)
        try store.upsert(request)

        let expectation = expectation(description: "row appears")
        store.incomingRequestsPublisher()
            .replaceError(with: [])
            .sink { rows in if !rows.isEmpty { expectation.fulfill() } }
            .store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        let rows = try database.dbQueue.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows, [request])
    }

    func test_upsert_sameFromAndToUid_replacesPreviousRow() throws {
        try store.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))
        try store.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi again", status: StoredFriendRequest.Status.pending, updateDt: 200, fromReadStatus: false, toReadStatus: false))

        let rows = try database.dbQueue.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.reason, "hi again")
        XCTAssertEqual(rows.first?.updateDt, 200)
    }

    func test_markAccepted_updatesStatusToAccepted() throws {
        try store.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))
        try store.markAccepted(fromUid: "u1")

        let rows = try database.dbQueue.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows.first?.status, StoredFriendRequest.Status.accepted)
    }

    func test_unreadIncomingCountPublisher_countsOnlyUnreadRows() throws {
        try store.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))
        try store.upsert(StoredFriendRequest(fromUid: "u2", toUid: "me", reason: "", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: true))

        let expectation = expectation(description: "count settles at 1")
        expectation.assertForOverFulfill = false
        store.unreadIncomingCountPublisher()
            .replaceError(with: 0)
            .sink { count in if count == 1 { expectation.fulfill() } }
            .store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }
}
