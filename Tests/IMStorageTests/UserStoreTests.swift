import XCTest
import Combine
@testable import IMStorage

final class UserStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: UserStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = UserStore(dbQueue: database.dbQueue)
        cancellables = []
    }

    func test_upsert_thenFetchByUid_returnsStoredUser() throws {
        try store.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice", portrait: nil, mobile: "13800000000", gender: 0, updateDt: 1))

        let fetched = try store.user(uid: "u1")

        XCTAssertEqual(fetched?.displayName, "Alice")
    }

    func test_upsert_sameUidTwice_updatesRatherThanDuplicates() throws {
        try store.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 1))
        try store.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice Updated", portrait: nil, mobile: nil, gender: 0, updateDt: 2))

        XCTAssertEqual(try store.allUsers().count, 1)
        XCTAssertEqual(try store.user(uid: "u1")?.displayName, "Alice Updated")
    }

    func test_allUsers_sortedByDisplayName() throws {
        try store.upsert(StoredUser(uid: "u1", name: "bob", displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 1))
        try store.upsert(StoredUser(uid: "u2", name: "alice", displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 1))

        let users = try store.allUsers()

        XCTAssertEqual(users.map { $0.displayName }, ["Alice", "Bob"])
    }

    func test_usersPublisher_emitsOnUpsert() throws {
        var receivedCounts: [Int] = []
        let expectation = expectation(description: "received at least 2 updates")
        expectation.expectedFulfillmentCount = 2

        store.usersPublisher()
            .sink(receiveCompletion: { _ in }, receiveValue: { users in
                receivedCounts.append(users.count)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 1))

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(receivedCounts, [0, 1])
    }
}
