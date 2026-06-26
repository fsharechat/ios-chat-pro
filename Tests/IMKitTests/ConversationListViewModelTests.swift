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

private final class FakeGroupSyncer: GroupSyncing {
    private(set) var refreshedGroupIds: [String] = []

    func refreshGroup(targetId: String) {
        refreshedGroupIds.append(targetId)
    }

    func refreshMembers(targetId: String) {}
}

final class ConversationListViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fetcher: FakeContactInfoFetcher!
    private var groupSyncer: FakeGroupSyncer!
    private var viewModel: ConversationListViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fetcher = FakeContactInfoFetcher()
        groupSyncer = FakeGroupSyncer()
        viewModel = ConversationListViewModel(storage: storage, contactSync: fetcher, groupSync: groupSyncer)
    }

    func test_initialState_emptyRows() {
        XCTAssertEqual(viewModel.rows, [])
    }

    func test_newConversation_appearsAsARow_withDisplayNameAndPreviewFromLastMessage() throws {
        try storage.users.upsertProfile(uid: "them", name: nil, displayName: "Alice", portrait: "https://example.com/a.png", mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hello"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)

        let expectation = expectation(description: "row appears")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(row.target, "them")
        XCTAssertEqual(row.displayName, "Alice")
        XCTAssertEqual(row.avatarURL, "https://example.com/a.png")
        XCTAssertEqual(row.previewText, "hello")
        XCTAssertEqual(row.unreadCount, 1)
    }

    func test_pendingSentMessage_stillShowsAPreview_despiteMessageUidZero() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 0, conversationType: .single, target: "them", from: "me", content: .text("not yet acked"), timestamp: 1_000, status: .sending, direction: .send))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 0, timestamp: 1_000, incrementUnread: false)

        let expectation = expectation(description: "row appears")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.first?.previewText, "not yet acked")
        XCTAssertEqual(viewModel.rows.first?.lastMessageStatus, .sending)
    }

    func test_draftPresent_showsDraftInsteadOfLastMessage() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hello"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)
        try storage.conversations.setDraft("unsent reply", conversationType: .single, target: "them", line: 0)

        let expectation = expectation(description: "draft preview appears")
        viewModel.$rows.sink { rows in
            if rows.first?.previewText == "[草稿] unsent reply" { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.first?.previewText, "[草稿] unsent reply")
    }

    func test_unresolvedProfile_triggersAFetchUserInfoCall() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)

        let expectation = expectation(description: "fetch triggered")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertTrue(fetcher.fetchedUids.contains("them"))
        XCTAssertEqual(fetcher.lastForceRefresh, false)
        XCTAssertEqual(viewModel.rows.first?.displayName, "them")
    }

    /// The regression this guards against: a sender's profile resolves
    /// asynchronously (a `UPUI` round trip after `fetchUserInfo` fires),
    /// with no new message/conversation event accompanying it. Before this
    /// test was added, `ConversationListViewModel` only re-derived rows on
    /// `conversationsPublisher` updates, so a profile arriving after that
    /// publisher had already fired (its only emission for this
    /// conversation) left the row frozen on the uid-fallback/no-avatar
    /// placeholder forever — exactly what reopening the app "fixed" by
    /// re-reading already-resolved local data on the next single emission.
    func test_profileResolvingAfterTheRowAlreadyExists_updatesTheRowInPlace() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)
        _ = try waitForRow(target: "them")
        XCTAssertEqual(viewModel.rows.first?.displayName, "them")

        try storage.users.upsertProfile(uid: "them", name: nil, displayName: "Resolved Name", portrait: "http://x/p.png", mobile: nil, gender: 0, updateDt: 1)

        let expectation = expectation(description: "row updates with the resolved profile")
        expectation.assertForOverFulfill = false
        viewModel.$rows.sink { rows in
            if rows.first(where: { $0.target == "them" })?.displayName == "Resolved Name" { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.first?.avatarURL, "http://x/p.png")
    }

    /// Same regression as `test_profileResolvingAfterTheRowAlreadyExists_updatesTheRowInPlace`,
    /// for a group's `refreshGroup`-triggered `gpgi` resolution instead of a
    /// single chat's `UPUI` resolution.
    func test_groupInfoResolvingAfterTheRowAlreadyExists_updatesTheRowInPlace() throws {
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g-unknown", messageUid: 1, timestamp: 1_000, incrementUnread: false)
        _ = try waitForRow(target: "g-unknown")
        XCTAssertEqual(viewModel.rows.first?.displayName, "g-unknown")

        try storage.groups.upsertGroup(StoredGroup(groupId: "g-unknown", name: "Resolved Group", portrait: "http://x/g.png", owner: "u1", groupType: .normal, memberCount: 2, updateDt: 0, memberUpdateDt: 0))

        let expectation = expectation(description: "row updates with the resolved group info")
        expectation.assertForOverFulfill = false
        viewModel.$rows.sink { rows in
            if rows.first(where: { $0.target == "g-unknown" })?.displayName == "Resolved Group" { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.first?.avatarURL, "http://x/g.png")
    }

    func test_resolvedProfileWithNoDisplayName_fallsBackToName() throws {
        try storage.users.upsertProfile(uid: "them", name: "rawname", displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 1)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)

        let expectation = expectation(description: "row appears")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.first?.displayName, "rawname")
        XCTAssertTrue(fetcher.fetchedUids.isEmpty) // name is resolved, even though displayName isn't — no fetch needed
    }

    func test_groupConversationWithNoCachedGroupInfo_triggersARefreshGroupCall() throws {
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g-unknown", messageUid: 1, timestamp: 1_000, incrementUnread: false)

        _ = try waitForRow(target: "g-unknown")

        XCTAssertTrue(groupSyncer.refreshedGroupIds.contains("g-unknown"))
    }

    func test_groupConversation_resolvesDisplayNameAndAvatarFromGroupStoreNotUserStore() throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "Group One", portrait: "http://x/g.png", owner: "u1", groupType: .normal, memberCount: 2, updateDt: 0, memberUpdateDt: 0))
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", messageUid: 1, timestamp: 1_000, incrementUnread: false)

        let row = try waitForRow(target: "g1")

        XCTAssertEqual(row.displayName, "Group One")
        XCTAssertEqual(row.avatarURL, "http://x/g.png")
        XCTAssertTrue(groupSyncer.refreshedGroupIds.isEmpty) // already resolved — no refresh needed
    }

    func test_groupConversation_previewTextIsPrefixedWithSenderDisplayName() throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "Group One", portrait: nil, owner: "u1", groupType: .normal, memberCount: 2, updateDt: 0, memberUpdateDt: 0))
        try storage.users.upsertProfile(uid: "sender1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "sender1", content: .text("hello"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", messageUid: 1, timestamp: 1_000, incrementUnread: true)

        let row = try waitForRow(target: "g1")

        XCTAssertEqual(row.previewText, "Alice: hello")
    }

    func test_groupConversation_withUnreadMention_setsHasUnreadMentionTrue() throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "Group One", portrait: nil, owner: "u1", groupType: .normal, memberCount: 2, updateDt: 0, memberUpdateDt: 0))
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", messageUid: 1, timestamp: 1_000, incrementUnread: true, incrementMention: true)

        let row = try waitForRow(target: "g1")

        XCTAssertTrue(row.hasUnreadMention)
    }

    func test_singleConversation_previewTextHasNoSenderPrefix() throws {
        try storage.users.upsertProfile(uid: "u2", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .single, target: "u2", from: "u2", content: .text("hello"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "u2", messageUid: 1, timestamp: 1_000, incrementUnread: true)

        let row = try waitForRow(target: "u2")

        XCTAssertEqual(row.previewText, "hello")
        XCTAssertFalse(row.hasUnreadMention)
    }

    func test_recalledBySelf_showsSelfRecallPreview() throws {
        // Build a dedicated viewModel that knows the current user is "me" so
        // the self-recall branch ("您撤回了一条消息") can fire.
        let selfViewModel = ConversationListViewModel(storage: storage, contactSync: fetcher, groupSync: groupSyncer, currentUserId: "me")

        try storage.messages.insert(StoredMessage(
            localMessageId: 20, messageUid: 600,
            conversationType: .single, target: "them", from: "me",
            content: .recalled(operatorId: "me"),
            timestamp: 6_000, status: .sent, direction: .send
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: .single, target: "them", line: 0,
            messageUid: 600, timestamp: 6_000, incrementUnread: false
        )

        let expectation = expectation(description: "row appears")
        selfViewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(selfViewModel.rows.first?.previewText, "您撤回了一条消息")
    }

    func test_recalledByOther_showsDisplayNamePreview() throws {
        try storage.users.upsertProfile(uid: "them", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(
            localMessageId: 21, messageUid: 601,
            conversationType: .single, target: "them", from: "them",
            content: .recalled(operatorId: "them"),
            timestamp: 6_001, status: .unread, direction: .receive
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: .single, target: "them", line: 0,
            messageUid: 601, timestamp: 6_001, incrementUnread: true
        )

        let expectation = expectation(description: "row appears")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.first?.previewText, "Bob撤回了一条消息")
    }

    private func waitForRow(target: String) throws -> ConversationRow {
        let expectation = expectation(description: "row for \(target) appears")
        expectation.assertForOverFulfill = false
        viewModel.$rows.dropFirst().sink { rows in
            if rows.contains(where: { $0.target == target }) { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
        return try XCTUnwrap(viewModel.rows.first { $0.target == target })
    }
}
