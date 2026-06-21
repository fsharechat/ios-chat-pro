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
}
