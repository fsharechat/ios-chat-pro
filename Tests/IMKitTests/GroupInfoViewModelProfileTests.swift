// Tests/IMKitTests/GroupInfoViewModelProfileTests.swift
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

/// `IMGroups` syncs group *membership* (uid + role) and never touches
/// `UserStore`, so a member who isn't a friend has no profile anywhere and
/// the member grid rendered their raw uid with no avatar — permanently,
/// since nothing asked the server for it.
final class GroupInfoViewModelProfileTests: XCTestCase {
    private var storage: IMStorage!
    private var fetcher: FakeContactInfoFetcher!
    private var viewModel: GroupInfoViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fetcher = FakeContactInfoFetcher()
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "G1", portrait: nil, owner: "owner1", groupType: .normal, memberCount: 2, updateDt: 0, memberUpdateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "owner1", memberType: .owner, updateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "member1", memberType: .normal, updateDt: 0))
    }

    /// Constructed per test rather than in `setUp`: the first member
    /// derivation starts on subscription and hops queues, so seeding a
    /// profile after the view model already exists races that first pass.
    private func makeViewModel() {
        viewModel = GroupInfoViewModel(
            groupId: "g1",
            groupActing: FakeGroupActing(),
            groupSyncing: FakeGroupSyncing(),
            storage: storage,
            contactSync: fetcher,
            currentUserId: "owner1"
        )
    }

    override func tearDown() {
        cancellables.removeAll()
        viewModel = nil
        super.tearDown()
    }

    /// The member list is derived off the main queue and delivered back
    /// asynchronously, so every assertion here has to wait for it.
    private func waitForMembers(where predicate: @escaping ([GroupInfoViewModel.MemberRow]) -> Bool, description: String) {
        if predicate(viewModel.members) { return }
        let expectation = expectation(description: description)
        expectation.assertForOverFulfill = false
        viewModel.$members.sink { if predicate($0) { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    private func member(_ uid: String) -> GroupInfoViewModel.MemberRow? {
        viewModel.members.first { $0.uid == uid }
    }

    func test_membersWithNoStoredProfile_areRequestedFromTheServer() {
        makeViewModel()

        waitForMembers(where: { $0.count == 2 }, description: "members load")

        XCTAssertEqual(Set(fetcher.fetchedUids), ["owner1", "member1"])
        XCTAssertEqual(fetcher.lastForceRefresh, false)
    }

    func test_memberWithResolvedProfile_isNotRequested() throws {
        try storage.users.upsertProfile(uid: "member1", name: nil, displayName: "Member One", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        makeViewModel()

        waitForMembers(where: { rows in rows.contains { $0.displayName == "Member One" } }, description: "resolved member loads")

        XCTAssertFalse(fetcher.fetchedUids.contains("member1"))
    }

    func test_profileResolvingAfterMembersExist_updatesTheRowInPlace() throws {
        makeViewModel()

        waitForMembers(where: { $0.count == 2 }, description: "members load")
        XCTAssertEqual(member("member1")?.displayName, "member1")

        try storage.users.upsertProfile(uid: "member1", name: nil, displayName: "Resolved", portrait: "http://x/p.png", mobile: nil, gender: 0, updateDt: 1)

        waitForMembers(where: { rows in rows.contains { $0.displayName == "Resolved" } }, description: "member row picks up the resolved profile")

        XCTAssertEqual(member("member1")?.avatarURL, "http://x/p.png")
    }

    func test_repeatedDerivations_requestTheSameUidOnlyOnce() throws {
        makeViewModel()

        waitForMembers(where: { $0.count == 2 }, description: "members load")

        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "member2", memberType: .normal, updateDt: 1))
        waitForMembers(where: { $0.count == 3 }, description: "third member loads")

        XCTAssertEqual(fetcher.fetchedUids.filter { $0 == "member1" }.count, 1)
        XCTAssertTrue(fetcher.fetchedUids.contains("member2"))
    }
}
