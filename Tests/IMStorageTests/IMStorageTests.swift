import XCTest
import Combine
@testable import IMStorage

final class IMStorageTests: XCTestCase {
    func test_openInMemory_exposesAllFourStoresSharingTheSameDatabase() throws {
        let storage = try IMStorage.openInMemory()

        // Round-trip through each store to prove they all see the same
        // underlying connection (not four independent, disconnected databases).
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send
        ))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)
        try storage.users.upsert(StoredUser(uid: "u2", name: "bob", displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 1))
        try storage.syncState.set(StoredSyncState(msgHead: 1, friendHead: 0, friendRequestHead: 0, settingHead: 0))

        XCTAssertEqual(try storage.messages.message(localMessageId: 1)?.content, .text("hi"))
        XCTAssertEqual(try storage.conversations.conversation(conversationType: .single, target: "u2")?.unreadCount, 1)
        XCTAssertEqual(try storage.users.user(uid: "u2")?.displayName, "Bob")
        XCTAssertEqual(try storage.syncState.get().msgHead, 1)
    }

    func test_openAtPath_persistsAcrossInstances() throws {
        let path = NSTemporaryDirectory() + "imstorage-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try IMStorage.open(atPath: path)
        try first.users.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 1))

        let second = try IMStorage.open(atPath: path)
        XCTAssertEqual(try second.users.user(uid: "u1")?.displayName, "Alice")
    }

    func test_friendRequests_isWiredIntoFacade() throws {
        let storage = try IMStorage.openInMemory()
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        let expectation = expectation(description: "row appears via facade")
        var cancellables: Set<AnyCancellable> = []
        storage.friendRequests.incomingRequestsPublisher()
            .replaceError(with: [])
            .sink { rows in if !rows.isEmpty { expectation.fulfill() } }
            .store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    func test_clearSessionData_deletesMessagesAndConversationsAndResetsSyncState() throws {
        let storage = try IMStorage.openInMemory()
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send
        ))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)
        try storage.syncState.set(StoredSyncState(msgHead: 42, friendHead: 7, friendRequestHead: 3, settingHead: 9))
        try storage.users.upsert(StoredUser(uid: "u2", name: "bob", displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 1))

        try storage.clearSessionData()

        XCTAssertNil(try storage.messages.message(localMessageId: 1))
        XCTAssertTrue(try storage.conversations.conversations().isEmpty)
        let syncState = try storage.syncState.get()
        XCTAssertEqual(syncState.msgHead, 0)
        XCTAssertEqual(syncState.friendHead, 0)
        XCTAssertEqual(syncState.friendRequestHead, 0)
        XCTAssertEqual(syncState.settingHead, 0)
        // users table is untouched — matches Android's SqliteDatabaseStore.stop() scope
        XCTAssertEqual(try storage.users.user(uid: "u2")?.displayName, "Bob")
    }

    func test_clearSessionData_resetsFavGroupFlag() throws {
        let storage = try IMStorage.openInMemory()
        try storage.groups.upsertGroup(StoredGroup(
            groupId: "g1", name: "Old Account's Group", portrait: nil, owner: "u1",
            groupType: .normal, memberCount: 3, updateDt: 1, memberUpdateDt: 1
        ))
        try storage.groups.setFav(true, groupId: "g1")
        XCTAssertEqual(try storage.groups.group(groupId: "g1")?.isFav, true)

        try storage.clearSessionData()

        XCTAssertEqual(try storage.groups.group(groupId: "g1")?.isFav, false)
    }
}
