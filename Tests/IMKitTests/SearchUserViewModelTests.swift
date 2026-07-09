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

private final class QueuingUserSearching: UserSearching {
    var pendingCompletions: [(keyword: String, completion: (Result<[String], Error>) -> Void)] = []

    func searchUser(keyword: String, completion: @escaping (Result<[String], Error>) -> Void) {
        pendingCompletions.append((keyword, completion))
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
        viewModel = SearchUserViewModel(userSearching: userSearching, friendRequestSending: friendRequestSending, storage: storage, currentUserId: "me")
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

    func test_search_excludesExistingFriends() throws {
        try storage.users.upsertProfile(uid: "friend1", name: nil, displayName: "老朋友", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.users.upsertProfile(uid: "stranger1", name: nil, displayName: "新面孔", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.users.replaceFriendList(uids: ["friend1"])
        userSearching.stubbedResult = .success(["friend1", "stranger1"])

        viewModel.search(keyword: "朋友")

        XCTAssertEqual(viewModel.results.map(\.uid), ["stranger1"], "已是好友的用户不应出现在添加朋友的搜索结果里")
    }

    func test_search_excludesSelf() throws {
        try storage.users.upsertProfile(uid: "me", name: nil, displayName: "我自己", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.users.upsertProfile(uid: "stranger1", name: nil, displayName: "新面孔", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        userSearching.stubbedResult = .success(["me", "stranger1"])

        viewModel.search(keyword: "我")

        XCTAssertEqual(viewModel.results.map(\.uid), ["stranger1"], "搜索结果不应包含自己,自己不能加自己")
    }

    func test_search_failure_clearsResults() {
        userSearching.stubbedResult = .failure(NSError(domain: "test", code: 1))

        viewModel.search(keyword: "alice")

        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func test_search_staleCompletionArrivingAfterNewerSearch_isDiscarded() throws {
        try storage.users.upsertProfile(uid: "u_old", name: nil, displayName: "Old", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.users.upsertProfile(uid: "u_new", name: nil, displayName: "New", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        let queuing = QueuingUserSearching()
        let vm = SearchUserViewModel(userSearching: queuing, friendRequestSending: friendRequestSending, storage: storage, currentUserId: "me")

        vm.search(keyword: "old")
        vm.search(keyword: "new")
        XCTAssertEqual(queuing.pendingCompletions.count, 2)

        // Newer search's network call resolves first.
        queuing.pendingCompletions[1].completion(.success(["u_new"]))
        XCTAssertEqual(vm.results.map(\.uid), ["u_new"])

        // Older (stale) search's network call resolves after — must be discarded, not overwrite.
        queuing.pendingCompletions[0].completion(.success(["u_old"]))
        XCTAssertEqual(vm.results.map(\.uid), ["u_new"], "stale completion must not overwrite newer results")
    }

    func test_defaultRequestReason_usesMyDisplayName() throws {
        try storage.users.upsertProfile(uid: "me", name: nil, displayName: "云朵爸爸", portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        XCTAssertEqual(viewModel.defaultRequestReason, "我是 云朵爸爸")
    }

    func test_defaultRequestReason_emptyWhenProfileMissing() {
        XCTAssertEqual(viewModel.defaultRequestReason, "")
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
