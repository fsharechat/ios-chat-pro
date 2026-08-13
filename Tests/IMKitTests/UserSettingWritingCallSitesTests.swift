// Tests/IMKitTests/UserSettingWritingCallSitesTests.swift
import XCTest
import IMStorage
@testable import IMKit

/// Records every `updateUserSetting` call as a `(scope, key, value)` triple —
/// same fake-collaborator shape as `FakeGroupSyncing` in
/// `CreateGroupViewModelTests.swift`.
final class FakeUserSettingWriting: UserSettingWriting {
    private(set) var calls: [(scope: Int, key: String, value: String)] = []

    func updateUserSetting(scope: Int, key: String, value: String) {
        calls.append((scope, key, value))
    }
}

/// Covers every ViewModel call site that reports a toggle to
/// `UserSettingWriting`, and pins down the exact `(scope, key, value)` triple
/// each one emits — this is where `GroupInfoViewModel.setFav`'s
/// "key is the bare groupId, not a conversation triple" exception lives, and
/// it has no other guard, so it's the most copy-paste-prone of the six.
final class UserSettingWritingCallSitesTests: XCTestCase {
    private var storage: IMStorage!
    private var fakeWriting: FakeUserSettingWriting!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fakeWriting = FakeUserSettingWriting()
    }

    // MARK: - GroupInfoViewModel

    private func makeGroupInfoViewModel(groupId: String = "groupX") -> GroupInfoViewModel {
        GroupInfoViewModel(
            groupId: groupId,
            groupActing: nil,
            groupSyncing: nil,
            storage: storage,
            currentUserId: "me",
            userSettingWriting: fakeWriting
        )
    }

    func test_groupInfoViewModel_setTop_emitsScope3WithConversationTripleKey() throws {
        let viewModel = makeGroupInfoViewModel(groupId: "groupX")

        viewModel.setTop(true)

        XCTAssertEqual(fakeWriting.calls.count, 1)
        let call = try XCTUnwrap(fakeWriting.calls.first)
        XCTAssertEqual(call.scope, UserSettingKeys.Scope.conversationTop)
        XCTAssertEqual(call.key, "1-0-groupX")
        XCTAssertEqual(call.value, "1")
    }

    func test_groupInfoViewModel_setMuted_emitsScope1WithConversationTripleKey() throws {
        let viewModel = makeGroupInfoViewModel(groupId: "groupX")

        viewModel.setMuted(true)

        let call = try XCTUnwrap(fakeWriting.calls.first)
        XCTAssertEqual(call.scope, UserSettingKeys.Scope.conversationSilent)
        XCTAssertEqual(call.key, "1-0-groupX")
        XCTAssertEqual(call.value, "1")
    }

    /// The exception: scope 6's key is the bare groupId, not a
    /// `type-line-target` conversation triple.
    func test_groupInfoViewModel_setFav_emitsScope6WithBareGroupIdKey() throws {
        let viewModel = makeGroupInfoViewModel(groupId: "groupX")

        viewModel.setFav(true)

        let call = try XCTUnwrap(fakeWriting.calls.first)
        XCTAssertEqual(call.scope, UserSettingKeys.Scope.favoriteGroup)
        XCTAssertEqual(call.key, "groupX", "scope 6 的 key 是裸 groupId，不是会话三元组")
        XCTAssertEqual(call.value, "1")
    }

    func test_groupInfoViewModel_setFav_cancel_writesTombstoneZeroRatherThanDeleting() throws {
        let viewModel = makeGroupInfoViewModel(groupId: "groupX")

        viewModel.setFav(false)

        let call = try XCTUnwrap(fakeWriting.calls.first)
        XCTAssertEqual(call.value, "0", "取消操作写 tombstone \"0\"，不是删除")
    }

    // MARK: - SingleConversationInfoViewModel

    private func makeSingleConversationInfoViewModel(userId: String = "userX") -> SingleConversationInfoViewModel {
        SingleConversationInfoViewModel(userId: userId, storage: storage, userSettingWriting: fakeWriting)
    }

    func test_singleConversationInfoViewModel_setTop_emitsScope3WithConversationTripleKey() throws {
        let viewModel = makeSingleConversationInfoViewModel(userId: "userX")

        viewModel.setTop(true)

        let call = try XCTUnwrap(fakeWriting.calls.first)
        XCTAssertEqual(call.scope, UserSettingKeys.Scope.conversationTop)
        XCTAssertEqual(call.key, "0-0-userX")
        XCTAssertEqual(call.value, "1")
    }

    func test_singleConversationInfoViewModel_setMuted_emitsScope1WithConversationTripleKey() throws {
        let viewModel = makeSingleConversationInfoViewModel(userId: "userX")

        viewModel.setMuted(true)

        let call = try XCTUnwrap(fakeWriting.calls.first)
        XCTAssertEqual(call.scope, UserSettingKeys.Scope.conversationSilent)
        XCTAssertEqual(call.key, "0-0-userX")
        XCTAssertEqual(call.value, "1")
    }

    // MARK: - ConversationListViewModel

    private func makeConversationListViewModel() -> ConversationListViewModel {
        ConversationListViewModel(storage: storage, contactSync: nil, groupSync: nil, userSettingWriting: fakeWriting)
    }

    private func makeRow(conversationType: ConversationType, target: String, line: Int = 0) -> ConversationRow {
        ConversationRow(
            conversationType: conversationType,
            target: target,
            line: line,
            displayName: target,
            avatarURL: nil,
            previewText: "",
            timestamp: 0,
            unreadCount: 0,
            hasUnreadMention: false,
            isTop: false,
            isMuted: false,
            lastMessageStatus: nil
        )
    }

    func test_conversationListViewModel_setTop_emitsScope3WithRowsOwnTripleKey() throws {
        let viewModel = makeConversationListViewModel()
        let row = makeRow(conversationType: .group, target: "groupY", line: 2)

        try viewModel.setTop(true, for: row)

        let call = try XCTUnwrap(fakeWriting.calls.first)
        XCTAssertEqual(call.scope, UserSettingKeys.Scope.conversationTop)
        XCTAssertEqual(call.key, "1-2-groupY")
        XCTAssertEqual(call.value, "1")
    }

    func test_conversationListViewModel_setMuted_emitsScope1WithRowsOwnTripleKey() throws {
        let viewModel = makeConversationListViewModel()
        let row = makeRow(conversationType: .single, target: "userY", line: 0)

        try viewModel.setMuted(true, for: row)

        let call = try XCTUnwrap(fakeWriting.calls.first)
        XCTAssertEqual(call.scope, UserSettingKeys.Scope.conversationSilent)
        XCTAssertEqual(call.key, "0-0-userY")
        XCTAssertEqual(call.value, "1")
    }

    func test_conversationListViewModel_setMuted_cancel_writesTombstoneZeroRatherThanDeleting() throws {
        let viewModel = makeConversationListViewModel()
        let row = makeRow(conversationType: .single, target: "userY", line: 0)

        try viewModel.setMuted(false, for: row)

        let call = try XCTUnwrap(fakeWriting.calls.first)
        XCTAssertEqual(call.value, "0", "取消操作写 tombstone \"0\"，不是删除")
    }
}
