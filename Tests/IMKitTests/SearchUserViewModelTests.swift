// Tests/IMKitTests/SearchUserViewModelTests.swift
import XCTest
import IMStorage
@testable import IMKit

private final class FakeUserSearching: UserSearching {
    var lastKeyword: String?
    var stubbedResult: Result<[String], Error> = .success([])

    func searchUser(keyword: String, completion: @escaping (Result<[String], Error>) -> Void) {
        lastKeyword = keyword
        completion(stubbedResult)
    }
}

private final class FakeFriendRequestSending: FriendRequestSending {
    var lastSendArgs: (uid: String, reason: String)?
    var stubbedSendResult: Result<Void, Error> = .success(())

    func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lastSendArgs = (uid, reason)
        completion(stubbedSendResult)
    }

    func acceptFriendRequest(from uid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}

final class SearchUserViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var userSearching: FakeUserSearching!
    private var friendRequestSending: FakeFriendRequestSending!
    private var viewModel: SearchUserViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        userSearching = FakeUserSearching()
        friendRequestSending = FakeFriendRequestSending()
        viewModel = SearchUserViewModel(userSearching: userSearching, friendRequestSending: friendRequestSending, storage: storage)
    }

    func test_search_emptyKeyword_clearsResultsWithoutSendingRequest() {
        userSearching.stubbedResult = .success(["u1"])
        viewModel.search(keyword: "alice") // populate results first
        XCTAssertFalse(viewModel.results.isEmpty)

        userSearching.lastKeyword = nil
        viewModel.search(keyword: "")

        XCTAssertNil(userSearching.lastKeyword, "empty keyword must not call through to searchUser")
        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func test_search_withResults_mapsMatchedUidsToContactRowsUsingCachedProfile() throws {
        try storage.users.upsertProfile(uid: "u1", name: nil, displayName: "Alice", portrait: "https://example.com/a.png", mobile: nil, gender: 0, updateDt: 0)
        userSearching.stubbedResult = .success(["u1"])

        viewModel.search(keyword: "alice")

        XCTAssertEqual(viewModel.results.count, 1)
        XCTAssertEqual(viewModel.results.first?.uid, "u1")
        XCTAssertEqual(viewModel.results.first?.displayName, "Alice")
        XCTAssertEqual(viewModel.results.first?.avatarURL, "https://example.com/a.png")
        XCTAssertEqual(viewModel.results.first?.sectionLetter, "")
    }

    func test_search_unresolvedUid_fallsBackToUidForDisplayName() throws {
        userSearching.stubbedResult = .success(["zz9"])

        viewModel.search(keyword: "zz9")

        XCTAssertEqual(viewModel.results.first?.displayName, "zz9")
    }

    func test_search_failure_clearsResults() {
        userSearching.stubbedResult = .failure(NSError(domain: "test", code: 1))

        viewModel.search(keyword: "alice")

        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func test_sendFriendRequest_delegatesToFriendRequestSending() {
        var captured: Result<Void, Error>?
        viewModel.sendFriendRequest(to: "u1", reason: "hi") { result in captured = result }

        XCTAssertEqual(friendRequestSending.lastSendArgs?.uid, "u1")
        XCTAssertEqual(friendRequestSending.lastSendArgs?.reason, "hi")
        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }
}
