import XCTest
import IMStorage
@testable import IMKit

final class CreateGroupViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fakeActing: FakeGroupActing!
    private var fakeSyncing: FakeGroupSyncing!
    private var viewModel: CreateGroupViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        try storage.users.replaceFriendList(uids: ["u2", "u3"])
        try storage.users.upsertProfile(uid: "u2", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.users.upsertProfile(uid: "u3", name: nil, displayName: "Carol", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        fakeActing = FakeGroupActing()
        fakeSyncing = FakeGroupSyncing()
        viewModel = CreateGroupViewModel(storage: storage, groupActing: fakeActing, groupSyncing: fakeSyncing)
    }

    func test_init_populatesRowsFromFriendsList() {
        XCTAssertEqual(viewModel.rows.map(\.contact.displayName).sorted(), ["Bob", "Carol"])
        XCTAssertTrue(viewModel.rows.allSatisfy { !$0.isSelected })
    }

    func test_toggleSelection_flipsIsSelectedAndSelectedCount() {
        let uid = viewModel.rows[0].contact.uid

        viewModel.toggleSelection(uid: uid)

        XCTAssertTrue(viewModel.rows.first { $0.contact.uid == uid }!.isSelected)
        XCTAssertEqual(viewModel.selectedCount, 1)

        viewModel.toggleSelection(uid: uid)

        XCTAssertFalse(viewModel.rows.first { $0.contact.uid == uid }!.isSelected)
        XCTAssertEqual(viewModel.selectedCount, 0)
    }

    func test_createGroup_passesOnlySelectedMemberIdsToGroupActing() {
        viewModel.toggleSelection(uid: "u2")

        viewModel.createGroup(name: "My Group") { _ in }

        XCTAssertEqual(fakeActing.lastName, "My Group")
        XCTAssertEqual(fakeActing.lastMemberIds, ["u2"])
    }

    func test_createGroup_onSuccess_triggersRefreshGroupWithReturnedId() {
        fakeActing.resultToReturn = .success("g999")

        viewModel.createGroup(name: "My Group") { _ in }

        XCTAssertEqual(fakeSyncing.lastRefreshedGroupId, "g999")
    }

    func test_createGroup_onFailure_doesNotTriggerRefresh() {
        fakeActing.resultToReturn = .failure(NSError(domain: "test", code: 1))

        viewModel.createGroup(name: "My Group") { _ in }

        XCTAssertNil(fakeSyncing.lastRefreshedGroupId)
    }
}

final class FakeGroupActing: GroupActing {
    var resultToReturn: Result<String, Error> = .success("g1")
    private(set) var lastName: String?
    private(set) var lastMemberIds: [String]?

    func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void) {
        lastName = name
        lastMemberIds = memberIds
        completion(resultToReturn)
    }
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {}
    func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
}

final class FakeGroupSyncing: GroupSyncing {
    private(set) var lastRefreshedGroupId: String?
    func refreshGroup(targetId: String) { lastRefreshedGroupId = targetId }
    func refreshMembers(targetId: String) {}
}
