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

    func test_allUsers_sortsNilDisplayNameLastNotFirst() throws {
        try store.upsert(StoredUser(uid: "u1", name: "bob", displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 1))
        try store.upsert(StoredUser(uid: "u2", name: "no-name-yet", displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 1))
        try store.upsert(StoredUser(uid: "u3", name: "alice", displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 1))

        let users = try store.allUsers()

        XCTAssertEqual(users.map { $0.uid }, ["u3", "u1", "u2"]) // Alice, Bob, then the nil-displayName contact last
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

    func test_replaceFriendList_marksListedUidsAsFriendsAndCreatesPlaceholderRows() throws {
        try store.replaceFriendList(uids: ["u1", "u2"])

        let friends = try store.friends()
        XCTAssertEqual(Set(friends.map(\.uid)), ["u1", "u2"])
        XCTAssertTrue(friends.allSatisfy(\.isFriend))
    }

    func test_replaceFriendList_calledAgainWithFewerUids_unmarksRemovedFriends() throws {
        try store.replaceFriendList(uids: ["u1", "u2"])
        try store.replaceFriendList(uids: ["u1"])

        let friends = try store.friends()
        XCTAssertEqual(friends.map(\.uid), ["u1"])

        // u2's row still exists (not deleted) but is no longer flagged as a friend.
        let u2 = try store.user(uid: "u2")
        XCTAssertNotNil(u2)
        XCTAssertFalse(u2!.isFriend)
    }

    func test_replaceFriendList_preservesExistingProfileFieldsForAlreadyKnownUser() throws {
        try store.upsertProfile(uid: "u1", name: "u1name", displayName: "Display One", portrait: "http://example.com/p.png", mobile: "13800000000", gender: 1, updateDt: 1_000)

        try store.replaceFriendList(uids: ["u1"])

        let u1 = try store.user(uid: "u1")
        XCTAssertEqual(u1?.displayName, "Display One")
        XCTAssertTrue(u1?.isFriend ?? false)
    }

    func test_upsertProfile_doesNotClobberExistingIsFriendFlag() throws {
        try store.replaceFriendList(uids: ["u1"])
        XCTAssertTrue(try store.user(uid: "u1")!.isFriend)

        try store.upsertProfile(uid: "u1", name: "u1name", displayName: "Display One", portrait: nil, mobile: nil, gender: 0, updateDt: 2_000)

        let u1 = try store.user(uid: "u1")
        XCTAssertEqual(u1?.displayName, "Display One")
        XCTAssertTrue(u1?.isFriend ?? false) // still a friend — profile update alone must not flip this
    }

    func test_upsertProfile_createsRowIfNoneExists() throws {
        try store.upsertProfile(uid: "newUser", name: "n", displayName: "New User", portrait: nil, mobile: nil, gender: 0, updateDt: 1)

        let user = try store.user(uid: "newUser")
        XCTAssertEqual(user?.displayName, "New User")
        XCTAssertFalse(user?.isFriend ?? true) // a profile-only upsert never makes someone a friend
    }

    func test_friends_excludesNonFriendProfiles() throws {
        try store.upsertProfile(uid: "stranger", name: nil, displayName: "Stranger", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try store.replaceFriendList(uids: ["friend1"])

        let friends = try store.friends()
        XCTAssertEqual(friends.map(\.uid), ["friend1"])
    }
}
