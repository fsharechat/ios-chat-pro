// Tests/IMKitTests/ConversationViewModelProfileTests.swift
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

/// The chat screen resolves sender names/avatars from `UserStore` alone. A
/// sender who never went through friend-list sync or the conversation list's
/// own `fetchUserInfo` (the common case: a non-friend group member) has no
/// row there at all, so every bubble rendered as the raw uid with no avatar
/// and nothing ever asked the server for the missing profile.
final class ConversationViewModelProfileTests: XCTestCase {
    private var storage: IMStorage!
    private var fetcher: FakeContactInfoFetcher!
    private var viewModel: ConversationViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fetcher = FakeContactInfoFetcher()
        viewModel = ConversationViewModel(
            storage: storage,
            messageSending: nil,
            imageUploading: nil,
            contactSync: fetcher,
            target: "g1",
            conversationType: .group,
            currentUserId: "me"
        )
    }

    override func tearDown() {
        cancellables.removeAll()
        viewModel = nil
        super.tearDown()
    }

    private func insertIncoming(from sender: String, localMessageId: Int64 = 1) throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: localMessageId,
            messageUid: localMessageId,
            conversationType: .group,
            target: "g1",
            from: sender,
            content: .text("hi"),
            timestamp: 1_000 + localMessageId,
            status: .unread,
            direction: .receive
        ))
    }

    private func waitForRows(where predicate: @escaping ([ChatMessageRow]) -> Bool, description: String) {
        if predicate(viewModel.rows) { return }
        let expectation = expectation(description: description)
        expectation.assertForOverFulfill = false
        viewModel.$rows.sink { if predicate($0) { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    private func senderName(uid: String) -> String? {
        for row in viewModel.rows {
            if case .message(let message) = row, message.senderUid == uid { return message.senderDisplayName }
        }
        return nil
    }

    private func senderAvatar(uid: String) -> String? {
        for row in viewModel.rows {
            if case .message(let message) = row, message.senderUid == uid { return message.senderAvatarURL }
        }
        return nil
    }

    func test_senderWithNoStoredProfile_requestsItFromTheServer() throws {
        try insertIncoming(from: "stranger")

        waitForRows(where: { !$0.isEmpty }, description: "row appears")

        XCTAssertTrue(fetcher.fetchedUids.contains("stranger"))
        XCTAssertEqual(fetcher.lastForceRefresh, false)
    }

    /// `FriendSyncHandler.replaceFriendList` writes an all-nil placeholder row
    /// for a newly-flagged friend before their profile resolves — a
    /// presence-only check would call that "cached" and never fetch, the same
    /// trap `ContactSyncService.fetchUserInfo` documents.
    func test_senderWithPlaceholderProfileRow_isStillRequested() throws {
        try storage.users.upsertProfile(uid: "stranger", name: nil, displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try insertIncoming(from: "stranger")

        waitForRows(where: { !$0.isEmpty }, description: "row appears")

        XCTAssertTrue(fetcher.fetchedUids.contains("stranger"))
    }

    func test_senderWithResolvedProfile_isNotRequested() throws {
        try storage.users.upsertProfile(uid: "known", name: nil, displayName: "Known", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try insertIncoming(from: "known")

        waitForRows(where: { !$0.isEmpty }, description: "row appears")

        XCTAssertFalse(fetcher.fetchedUids.contains("known"))
    }

    /// Rows rebuild on every message change and on every relevant profile
    /// change; without in-view-model de-duplication each rebuild would re-ask
    /// the server for the same still-unresolved uid.
    func test_repeatedRebuilds_requestTheSameUidOnlyOnce() throws {
        try insertIncoming(from: "stranger", localMessageId: 1)
        waitForRows(where: { !$0.isEmpty }, description: "row appears")
        try insertIncoming(from: "stranger", localMessageId: 2)
        waitForRows(where: { $0.count >= 2 }, description: "second row appears")
        viewModel.reprocessMessages()

        XCTAssertEqual(fetcher.fetchedUids.filter { $0 == "stranger" }.count, 1)
    }

    /// The other half of the bug: even once the `UPUI` response lands, the
    /// open chat screen only re-derived rows from `messagesPublisher`, so the
    /// resolved name/avatar stayed invisible until a new message arrived or
    /// the screen was popped and pushed again.
    func test_profileResolvingAfterRowsExist_updatesNameAndAvatarInPlace() throws {
        try insertIncoming(from: "stranger")
        waitForRows(where: { !$0.isEmpty }, description: "row appears")
        XCTAssertEqual(senderName(uid: "stranger"), "stranger")

        try storage.users.upsertProfile(uid: "stranger", name: nil, displayName: "Resolved", portrait: "http://x/p.png", mobile: nil, gender: 0, updateDt: 1)

        waitForRows(where: { rows in
            rows.contains { row in
                if case .message(let message) = row { return message.senderDisplayName == "Resolved" }
                return false
            }
        }, description: "row picks up the resolved profile")

        XCTAssertEqual(senderAvatar(uid: "stranger"), "http://x/p.png")
    }

    /// Guards the relevance filter: `usersPublisher()` observes the whole
    /// `user` table, and a friend-list sync writes hundreds of rows at once.
    /// Rebuilding this screen's rows for profiles it doesn't render would put
    /// the conversation's dominant cost (see `makeRows`) on an unrelated
    /// write's critical path.
    func test_unrelatedProfileChange_doesNotRebuildRows() throws {
        try insertIncoming(from: "stranger")
        waitForRows(where: { !$0.isEmpty }, description: "row appears")

        let expectation = expectation(description: "rows must not re-emit")
        expectation.isInverted = true
        viewModel.$rows.dropFirst().sink { _ in expectation.fulfill() }.store(in: &cancellables)

        try storage.users.upsertProfile(uid: "someone-else", name: nil, displayName: "Irrelevant", portrait: nil, mobile: nil, gender: 0, updateDt: 1)

        wait(for: [expectation], timeout: 0.5)
    }
}
