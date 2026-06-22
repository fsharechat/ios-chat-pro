// Tests/IMKitTests/NewFriendsViewModelTests.swift
import XCTest
import Combine
import IMStorage
@testable import IMKit

private final class FakeFriendRequestSyncing: FriendRequestSyncing {
    var syncFriendRequestsCallCount = 0
    var markFriendRequestsAsReadCallCount = 0

    func syncFriendRequests() { syncFriendRequestsCallCount += 1 }
    func markFriendRequestsAsRead() { markFriendRequestsAsReadCallCount += 1 }
}

private final class FakeFriendRequestSending: FriendRequestSending {
    var lastAcceptedUid: String?
    var stubbedAcceptResult: Result<Void, Error> = .success(())

    func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func acceptFriendRequest(from uid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lastAcceptedUid = uid
        completion(stubbedAcceptResult)
    }
}

final class NewFriendsViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var syncing: FakeFriendRequestSyncing!
    private var sending: FakeFriendRequestSending!
    private var viewModel: NewFriendsViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        syncing = FakeFriendRequestSyncing()
        sending = FakeFriendRequestSending()
        viewModel = NewFriendsViewModel(friendRequestSyncing: syncing, friendRequestSending: sending, storage: storage)
    }

    private func waitForNonEmptyRows() {
        guard viewModel.rows.isEmpty else { return }
        let expectation = expectation(description: "rows appear")
        expectation.assertForOverFulfill = false
        viewModel.$rows.dropFirst().sink { rows in if !rows.isEmpty { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    func test_initialState_emptyRows() {
        XCTAssertTrue(viewModel.rows.isEmpty)
    }

    func test_incomingRequest_mapsToRowWithResolvedProfile() throws {
        try storage.users.upsertProfile(uid: "u1", name: nil, displayName: "Alice", portrait: "https://example.com/a.png", mobile: nil, gender: 0, updateDt: 0)
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        waitForNonEmptyRows()

        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(row.fromUid, "u1")
        XCTAssertEqual(row.displayName, "Alice")
        XCTAssertEqual(row.avatarURL, "https://example.com/a.png")
        XCTAssertEqual(row.reason, "hi")
        XCTAssertFalse(row.isAccepted)
    }

    func test_incomingRequest_unresolvedProfile_fallsBackToUidForDisplayName() throws {
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "zz9", toUid: "me", reason: "", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        waitForNonEmptyRows()

        XCTAssertEqual(viewModel.rows.first?.displayName, "zz9")
    }

    func test_acceptedRequest_mapsToRowWithIsAcceptedTrue() throws {
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "", status: StoredFriendRequest.Status.accepted, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        waitForNonEmptyRows()

        XCTAssertTrue(viewModel.rows.first?.isAccepted ?? false)
    }

    func test_refresh_callsSyncFriendRequestsAndMarkFriendRequestsAsRead() {
        viewModel.refresh()

        XCTAssertEqual(syncing.syncFriendRequestsCallCount, 1)
        XCTAssertEqual(syncing.markFriendRequestsAsReadCallCount, 1)
    }

    func test_accept_delegatesToFriendRequestSending() {
        viewModel.accept(fromUid: "u1")

        XCTAssertEqual(sending.lastAcceptedUid, "u1")
    }
}
