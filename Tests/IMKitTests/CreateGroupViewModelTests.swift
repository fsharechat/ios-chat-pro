import XCTest
import Combine
import IMStorage
@testable import IMKit

final class CreateGroupViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fakeActing: FakeGroupActing!
    private var fakeSyncing: FakeGroupSyncing!
    private var viewModel: CreateGroupViewModel!
    private var cancellables: Set<AnyCancellable> = []

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

    func test_init_groupsRowsIntoPinyinSections() {
        XCTAssertEqual(viewModel.sections.map(\.letter), ["B", "C"])
        XCTAssertEqual(viewModel.sections.map { $0.rows.map(\.contact.displayName) }, [["Bob"], ["Carol"]])
    }

    func test_toggleSelection_updatesSectionsInPlace() {
        viewModel.toggleSelection(uid: "u2")

        let bobRow = viewModel.sections.flatMap(\.rows).first { $0.contact.uid == "u2" }
        XCTAssertEqual(bobRow?.isSelected, true)
        XCTAssertEqual(viewModel.sections.map(\.letter), ["B", "C"])
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

    // MARK: - startChat(发起聊天:1 人单聊 / 多人自动命名建群,对齐 Android)

    func test_startChat_singleSelection_returnsSingleWithoutCreatingGroup() {
        viewModel.toggleSelection(uid: "u2")

        var received: CreateGroupViewModel.StartChatResult?
        viewModel.startChat { result in received = try? result.get() }

        XCTAssertEqual(received, .single(uid: "u2"))
        XCTAssertNil(fakeActing.lastName)
    }

    func test_startChat_multiSelection_createsGroupWithAutoName() {
        fakeActing.resultToReturn = .success("g5")
        viewModel.toggleSelection(uid: "u2")
        viewModel.toggleSelection(uid: "u3")

        var received: CreateGroupViewModel.StartChatResult?
        viewModel.startChat { result in received = try? result.get() }

        XCTAssertEqual(received, .group(groupId: "g5", name: "Bob、Carol"))
        XCTAssertEqual(fakeActing.lastName, "Bob、Carol")
        XCTAssertEqual(Set(fakeActing.lastMemberIds ?? []), ["u2", "u3"])
        XCTAssertEqual(fakeSyncing.lastRefreshedGroupId, "g5")
    }

    func test_startChat_emptySelection_doesNothing() {
        var callbackCount = 0
        viewModel.startChat { _ in callbackCount += 1 }

        XCTAssertEqual(callbackCount, 0)
        XCTAssertNil(fakeActing.lastName)
    }

    func test_autoGroupName_capsAtThreeNames() {
        XCTAssertEqual(CreateGroupViewModel.autoGroupName(from: ["A", "B", "C", "D"]), "A、B、C")
        XCTAssertEqual(CreateGroupViewModel.autoGroupName(from: ["A"]), "A")
    }

    func test_unrelatedFriendListMutation_preservesInProgressSelection() throws {
        viewModel.toggleSelection(uid: "u2")
        XCTAssertEqual(viewModel.selectedCount, 1)

        let expectation = expectation(description: "rows re-emitted")
        viewModel.$rows.dropFirst().sink { rows in
            if rows.first(where: { $0.contact.uid == "u3" })?.contact.displayName == "Carol Updated" {
                expectation.fulfill()
            }
        }.store(in: &cancellables)

        try storage.users.upsertProfile(uid: "u3", name: nil, displayName: "Carol Updated", portrait: nil, mobile: nil, gender: 0, updateDt: 1)

        wait(for: [expectation], timeout: 2)

        XCTAssertTrue(viewModel.rows.first { $0.contact.uid == "u2" }!.isSelected)
        XCTAssertEqual(viewModel.selectedCount, 1)
    }

    func test_unfriendingMidFlow_dropsSelectionAndRemovesRow() throws {
        viewModel.toggleSelection(uid: "u2")
        XCTAssertEqual(viewModel.selectedCount, 1)

        let expectation = expectation(description: "rows re-emitted without u2")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.contains(where: { $0.contact.uid == "u2" }) {
                expectation.fulfill()
            }
        }.store(in: &cancellables)

        try storage.users.replaceFriendList(uids: ["u3"])

        wait(for: [expectation], timeout: 2)

        XCTAssertFalse(viewModel.rows.contains { $0.contact.uid == "u2" })
        XCTAssertEqual(viewModel.selectedCount, 0)
    }
}

final class FakeGroupActing: GroupActing {
    var resultToReturn: Result<String, Error> = .success("g1")
    var addMembersResultToReturn: Result<Void, Error> = .success(())
    private(set) var lastName: String?
    private(set) var lastMemberIds: [String]?

    func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void) {
        lastName = name
        lastMemberIds = memberIds
        completion(resultToReturn)
    }
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        lastMemberIds = memberIds
        completion(addMembersResultToReturn)
    }
    func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
}

final class FakeGroupSyncing: GroupSyncing {
    private(set) var lastRefreshedGroupId: String?
    private(set) var lastRefreshedMembersGroupId: String?
    func refreshGroup(targetId: String) { lastRefreshedGroupId = targetId }
    func refreshMembers(targetId: String) { lastRefreshedMembersGroupId = targetId }
}
