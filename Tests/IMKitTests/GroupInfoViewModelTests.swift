// Tests/IMKitTests/GroupInfoViewModelTests.swift
import XCTest
import IMStorage
@testable import IMKit

final class GroupInfoViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fakeActing: FakeGroupActing!
    private var fakeSyncing: FakeGroupSyncing!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fakeActing = FakeGroupActing()
        fakeSyncing = FakeGroupSyncing()
    }

    private func seedGroup(type: GroupType, owner: String = "owner1") throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "G1", portrait: nil, owner: owner, groupType: type, memberCount: 2, updateDt: 0, memberUpdateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: owner, memberType: .owner, updateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "member1", memberType: .normal, updateDt: 0))
    }

    private func makeViewModel(currentUserId: String) -> GroupInfoViewModel {
        GroupInfoViewModel(groupId: "g1", groupActing: fakeActing, groupSyncing: fakeSyncing, storage: storage, currentUserId: currentUserId)
    }

    // --- Permission matrix: the authoritative source is the design doc's
    // verified table (Restricted/Normal/Free × add/kick/modify/dismiss).
    // Each row below is one cell of that table, owner and non-owner both
    // checked where they differ.

    func test_restrictedGroup_ownerCanDoEverythingExceptQuit() throws {
        try seedGroup(type: .restricted, owner: "me")
        let viewModel = makeViewModel(currentUserId: "me")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertTrue(viewModel.canKickMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
        XCTAssertTrue(viewModel.canDismiss)
    }

    func test_restrictedGroup_nonOwnerCanDoNothingButQuit() throws {
        try seedGroup(type: .restricted, owner: "owner1")
        let viewModel = makeViewModel(currentUserId: "member1")

        XCTAssertFalse(viewModel.canAddMembers)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertFalse(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canDismiss)
    }

    func test_normalGroup_nonOwnerCanAddAndModifyButNotKickOrDismiss() throws {
        try seedGroup(type: .normal, owner: "owner1")
        let viewModel = makeViewModel(currentUserId: "member1")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canDismiss)
    }

    func test_normalGroup_ownerCanDoEverything() throws {
        try seedGroup(type: .normal, owner: "me")
        let viewModel = makeViewModel(currentUserId: "me")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertTrue(viewModel.canKickMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
        XCTAssertTrue(viewModel.canDismiss)
    }

    func test_freeGroup_nobodyCanKickOrDismissEvenTheOwner() throws {
        try seedGroup(type: .free, owner: "me")
        let viewModel = makeViewModel(currentUserId: "me")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canDismiss)
    }

    func test_freeGroup_nonOwnerCanAddAndModify() throws {
        try seedGroup(type: .free, owner: "owner1")
        let viewModel = makeViewModel(currentUserId: "member1")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertFalse(viewModel.canDismiss)
    }

    func test_noGroupLoadedYet_allPermissionsFalse() {
        let viewModel = makeViewModel(currentUserId: "me")

        XCTAssertFalse(viewModel.canAddMembers)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertFalse(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canDismiss)
    }

    // --- Member list

    func test_members_excludesRemovedAndMarksOwner() throws {
        try seedGroup(type: .normal, owner: "owner1")
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "removedUser", memberType: .removed, updateDt: 0))
        try storage.users.upsertProfile(uid: "owner1", name: nil, displayName: "Owner", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        let viewModel = makeViewModel(currentUserId: "owner1")

        XCTAssertEqual(Set(viewModel.members.map(\.uid)), ["owner1", "member1"])
        XCTAssertEqual(viewModel.members.first { $0.uid == "owner1" }?.isOwner, true)
        XCTAssertEqual(viewModel.members.first { $0.uid == "member1" }?.isOwner, false)
        XCTAssertEqual(viewModel.members.first { $0.uid == "owner1" }?.displayName, "Owner")
    }

    // --- Actions delegate to GroupActing/GroupSyncing

    func test_addMembers_callsGroupActingThenRefreshesMembers() throws {
        try seedGroup(type: .normal)
        let viewModel = makeViewModel(currentUserId: "owner1")

        viewModel.addMembers(["newUser"]) { _ in }

        XCTAssertEqual(fakeActing.lastMemberIds, ["newUser"])
    }

    func test_refresh_callsGroupSyncingRefreshGroup() {
        let viewModel = makeViewModel(currentUserId: "me")

        viewModel.refresh()

        XCTAssertEqual(fakeSyncing.lastRefreshedGroupId, "g1")
    }

    // --- 双态(成员/非成员,扫群码入口)

    func test_isMember_trueForMember_falseForStranger() throws {
        try seedGroup(type: .normal)

        XCTAssertTrue(makeViewModel(currentUserId: "member1").isMember)
        XCTAssertFalse(makeViewModel(currentUserId: "stranger").isMember)
    }

    func test_nonMember_allManagementPermissionsFalse() throws {
        try seedGroup(type: .normal)
        let viewModel = makeViewModel(currentUserId: "stranger")

        XCTAssertFalse(viewModel.canAddMembers)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertFalse(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canDismiss)
    }

    func test_joinGroup_addsSelfThenRefreshesGroupAndMembers() throws {
        try seedGroup(type: .normal)
        let viewModel = makeViewModel(currentUserId: "stranger")

        var succeeded = false
        viewModel.joinGroup { if case .success = $0 { succeeded = true } }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(fakeActing.lastMemberIds, ["stranger"])
        XCTAssertEqual(fakeSyncing.lastRefreshedGroupId, "g1")
        XCTAssertEqual(fakeSyncing.lastRefreshedMembersGroupId, "g1")
    }

    // --- Quit/dismiss cleanup

    func test_quitGroup_onSuccess_deletesLocalConversationAndMessages() throws {
        try seedGroup(type: .normal, owner: "owner1")
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "owner1",
            content: .text("hi"), timestamp: 1_000, status: .sent, direction: .receive
        ))
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)
        let viewModel = makeViewModel(currentUserId: "member1")

        var succeeded = false
        viewModel.quitGroup { if case .success = $0 { succeeded = true } }

        XCTAssertTrue(succeeded)
        XCTAssertNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
        XCTAssertTrue(try storage.messages.messages(conversationType: .group, target: "g1").isEmpty)
    }

    func test_dismissGroup_onSuccess_deletesLocalConversationAndMessages() throws {
        try seedGroup(type: .normal, owner: "me")
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
        let viewModel = makeViewModel(currentUserId: "me")

        var succeeded = false
        viewModel.dismissGroup { if case .success = $0 { succeeded = true } }

        XCTAssertTrue(succeeded)
        XCTAssertNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
    }

    func test_quitGroup_onFailure_doesNotDeleteLocalConversation() throws {
        try seedGroup(type: .normal, owner: "owner1")
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
        fakeActing.quitGroupResult = .failure(NSError(domain: "test", code: 1))
        let viewModel = makeViewModel(currentUserId: "member1")

        var failed = false
        viewModel.quitGroup { if case .failure = $0 { failed = true } }

        XCTAssertTrue(failed)
        XCTAssertNotNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
    }
}
