// Tests/IMKitTests/ContactListViewModelTests.swift
import XCTest
import Combine
import IMStorage
@testable import IMKit

private final class FakeContactInfoFetcher: ContactInfoFetching {
    private(set) var fetchedUids: [String] = []
    private(set) var lastForceRefresh: Bool?

    func fetchUserInfo(uids: [String], forceRefresh: Bool) {
        fetchedUids.append(contentsOf: uids)
        lastForceRefresh = forceRefresh
    }
}

final class ContactListViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fetcher: FakeContactInfoFetcher!
    private var viewModel: ContactListViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fetcher = FakeContactInfoFetcher()
        viewModel = ContactListViewModel(storage: storage, contactSync: fetcher)
    }

    private func waitForNonEmptySections() {
        guard viewModel.sections.isEmpty else { return }
        let expectation = expectation(description: "sections appear")
        expectation.assertForOverFulfill = false
        viewModel.$sections.dropFirst().sink { sections in if !sections.isEmpty { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    func test_initialState_emptySections() {
        XCTAssertEqual(viewModel.sections.count, 0)
    }

    func test_singleEnglishNameFriend_groupedUnderItsFirstLetter() throws {
        try storage.users.upsert(StoredUser(uid: "u1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        waitForNonEmptySections()

        XCTAssertEqual(viewModel.sections.map { $0.letter }, ["A"])
        XCTAssertEqual(viewModel.sections.first?.rows.map { $0.displayName }, ["Alice"])
    }

    func test_nonFriendUser_excludedFromSections() throws {
        try storage.users.upsert(StoredUser(uid: "u1", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: false))

        let expectation = expectation(description: "no sections appear")
        expectation.isInverted = true
        viewModel.$sections.dropFirst().sink { sections in if !sections.isEmpty { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 0.5)

        XCTAssertTrue(viewModel.sections.isEmpty)
    }

    func test_multipleFriends_sortedAlphabeticallyBySection() throws {
        try storage.users.upsert(StoredUser(uid: "u1", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))
        try storage.users.upsert(StoredUser(uid: "u2", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))
        try storage.users.upsert(StoredUser(uid: "u3", name: nil, displayName: "Adam", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        let expectation = expectation(description: "all three settle")
        expectation.assertForOverFulfill = false
        viewModel.$sections.sink { sections in
            let total = sections.reduce(0) { $0 + $1.rows.count }
            if total == 3 { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.sections.map { $0.letter }, ["A", "B"])
        XCTAssertEqual(viewModel.sections.first?.rows.map { $0.displayName }, ["Adam", "Alice"])
        XCTAssertEqual(viewModel.sections.last?.rows.map { $0.displayName }, ["Bob"])
    }

    func test_unresolvedFriendName_fallsBackToUidForGroupingAndDisplay() throws {
        try storage.users.upsert(StoredUser(uid: "zz9", name: nil, displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        waitForNonEmptySections()

        XCTAssertEqual(viewModel.sections.first?.rows.first?.displayName, "zz9")
        XCTAssertEqual(viewModel.sections.map { $0.letter }, ["Z"])
    }

    func test_unresolvedFriendProfile_triggersAFetchUserInfoCall() throws {
        try storage.users.upsert(StoredUser(uid: "zz9", name: nil, displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        waitForNonEmptySections()

        XCTAssertTrue(fetcher.fetchedUids.contains("zz9"))
        XCTAssertEqual(fetcher.lastForceRefresh, false)
    }

    func test_resolvedFriendProfile_doesNotTriggerAFetchUserInfoCall() throws {
        try storage.users.upsert(StoredUser(uid: "u1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        waitForNonEmptySections()

        XCTAssertTrue(fetcher.fetchedUids.isEmpty)
    }

    func test_nonLetterName_groupedUnderHash() throws {
        try storage.users.upsert(StoredUser(uid: "u1", name: nil, displayName: "123", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        waitForNonEmptySections()

        XCTAssertEqual(viewModel.sections.map { $0.letter }, ["#"])
    }

    func test_unreadFriendRequestCount_reflectsUnreadIncomingRequests() throws {
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        let expectation = expectation(description: "count settles at 1")
        expectation.assertForOverFulfill = false
        viewModel.$unreadFriendRequestCount.sink { count in if count == 1 { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }
}
