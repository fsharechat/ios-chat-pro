import XCTest
import Combine
import IMStorage
@testable import IMKit

final class AddGroupMemberViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fakeActing: FakeGroupActing!
    private var fakeSyncing: FakeGroupSyncing!
    private var viewModel: AddGroupMemberViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        try storage.users.replaceFriendList(uids: ["u2", "u3"])
        try storage.users.upsertProfile(uid: "u2", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.users.upsertProfile(uid: "u3", name: nil, displayName: "Carol", portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "G1", portrait: nil, owner: "u1", groupType: .normal, memberCount: 1, updateDt: 0, memberUpdateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u1", memberType: .owner, updateDt: 0))

        fakeActing = FakeGroupActing()
        fakeSyncing = FakeGroupSyncing()
        viewModel = AddGroupMemberViewModel(groupId: "g1", storage: storage, groupActing: fakeActing, groupSyncing: fakeSyncing)
    }

    /// `CombineLatest` only emits once BOTH upstream publishers have
    /// produced at least one value. Both `friendsPublisher` and
    /// `membersPublisher` emit synchronously on `.immediate` scheduling
    /// from GRDB's `ValueObservation`, so a synchronous read after init
    /// should already be populated — but we still wait defensively the
    /// same way `ConversationListViewModelTests.waitForRow` does, since
    /// asserting on a possibly-not-yet-emitted `rows` would be a flaky
    /// false negative.
    private func waitForRowsNonEmpty() {
        if !viewModel.rows.isEmpty { return }
        let expectation = expectation(description: "rows populated")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    func test_init_excludesExistingMembers() {
        waitForRowsNonEmpty()

        // u1 is the owner/existing member and is not a friend anyway, but
        // u2/u3 (friends) are NOT members of g1, so both should appear.
        XCTAssertEqual(viewModel.rows.map(\.contact.displayName).sorted(), ["Bob", "Carol"])
        XCTAssertTrue(viewModel.rows.allSatisfy { !$0.isSelected })
    }

    func test_init_excludesFriendWhoIsAlreadyAMember() throws {
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u2", memberType: .normal, updateDt: 0))

        let expectation = expectation(description: "rows re-emitted without u2")
        expectation.assertForOverFulfill = false
        viewModel.$rows.sink { rows in
            if rows.contains(where: { $0.contact.uid == "u3" }) && !rows.contains(where: { $0.contact.uid == "u2" }) {
                expectation.fulfill()
            }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertFalse(viewModel.rows.contains { $0.contact.uid == "u2" })
        XCTAssertTrue(viewModel.rows.contains { $0.contact.uid == "u3" })
    }

    func test_toggleSelection_flipsIsSelectedAndSelectedCount() {
        waitForRowsNonEmpty()
        let uid = viewModel.rows[0].contact.uid

        viewModel.toggleSelection(uid: uid)

        XCTAssertTrue(viewModel.rows.first { $0.contact.uid == uid }!.isSelected)
        XCTAssertEqual(viewModel.selectedCount, 1)

        viewModel.toggleSelection(uid: uid)

        XCTAssertFalse(viewModel.rows.first { $0.contact.uid == uid }!.isSelected)
        XCTAssertEqual(viewModel.selectedCount, 0)
    }

    func test_addSelectedMembers_passesOnlySelectedMemberIdsToGroupActing() {
        waitForRowsNonEmpty()
        viewModel.toggleSelection(uid: "u2")

        viewModel.addSelectedMembers { _ in }

        XCTAssertEqual(fakeActing.lastMemberIds, ["u2"])
    }

    func test_addSelectedMembers_onSuccess_triggersRefreshMembersWithGroupId() {
        waitForRowsNonEmpty()
        viewModel.toggleSelection(uid: "u2")
        fakeActing.addMembersResultToReturn = .success(())

        viewModel.addSelectedMembers { _ in }

        XCTAssertEqual(fakeSyncing.lastRefreshedMembersGroupId, "g1")
    }

    func test_addSelectedMembers_onFailure_doesNotTriggerRefresh() {
        waitForRowsNonEmpty()
        viewModel.toggleSelection(uid: "u2")
        fakeActing.addMembersResultToReturn = .failure(NSError(domain: "test", code: 1))

        viewModel.addSelectedMembers { _ in }

        XCTAssertNil(fakeSyncing.lastRefreshedMembersGroupId)
    }

    func test_friendAlreadyMemberNeverAppearsEvenAfterFriendsListRefresh() throws {
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u2", memberType: .normal, updateDt: 0))

        let expectation1 = expectation(description: "u2 excluded after membership change")
        expectation1.assertForOverFulfill = false
        viewModel.$rows.sink { rows in
            if !rows.contains(where: { $0.contact.uid == "u2" }) && rows.contains(where: { $0.contact.uid == "u3" }) {
                expectation1.fulfill()
            }
        }.store(in: &cancellables)
        wait(for: [expectation1], timeout: 2)

        // Now refresh the friends list (re-emits friendsPublisher) -- u2
        // is still a member of g1, so it must still be excluded.
        let expectation2 = expectation(description: "rows re-emitted after friend list refresh")
        expectation2.assertForOverFulfill = false
        viewModel.$rows.dropFirst().sink { rows in
            expectation2.fulfill()
        }.store(in: &cancellables)

        try storage.users.upsertProfile(uid: "u3", name: nil, displayName: "Carol Updated", portrait: nil, mobile: nil, gender: 0, updateDt: 1)

        wait(for: [expectation2], timeout: 2)

        XCTAssertFalse(viewModel.rows.contains { $0.contact.uid == "u2" })
    }
}
