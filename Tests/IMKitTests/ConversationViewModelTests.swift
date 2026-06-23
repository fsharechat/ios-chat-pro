import XCTest
import Combine
import IMStorage
import IMMedia
@testable import IMKit

private final class FakeMessageSending: MessageSending {
    private(set) var sentTexts: [(target: String, text: String)] = []
    private(set) var sentImages: [(target: String, thumbnail: Data?, remoteURL: String)] = []
    private(set) var resentLocalMessageIds: [Int64] = []
    private(set) var lastMentionedType: Int32?
    private(set) var lastMentionedTargets: [String]?

    func sendText(to target: String, conversationType: ConversationType, line: Int, text: String, mentionedType: Int32, mentionedTargets: [String]) throws {
        sentTexts.append((target, text))
        lastMentionedType = mentionedType
        lastMentionedTargets = mentionedTargets
    }

    func sendImage(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String) throws {
        sentImages.append((target, thumbnail, remoteURL))
    }

    func resend(localMessageId: Int64) throws {
        resentLocalMessageIds.append(localMessageId)
    }
}

private final class FakeImageUploading: ImageUploading {
    var nextResult: Result<String, MediaUploadError> = .failure(.invalidUploadURL)
    // The real `MediaUploadService` always completes asynchronously (network
    // round-trip); this fake defaults to completing inline for the tests
    // that assert the post-completion state with no wait. Setting this to
    // `false` lets a test observe the synchronously-published pending row
    // before any completion fires, matching production's actual timing.
    var completesSynchronously = true
    private(set) var uploadedData: [Data] = []
    private(set) var pendingCompletions: [(Result<String, MediaUploadError>) -> Void] = []

    func uploadImage(_ data: Data, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
        uploadedData.append(data)
        if completesSynchronously {
            completion(nextResult)
        } else {
            pendingCompletions.append(completion)
        }
    }
}

final class ConversationViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var sending: FakeMessageSending!
    private var uploading: FakeImageUploading!
    private var viewModel: ConversationViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        sending = FakeMessageSending()
        uploading = FakeImageUploading()
        viewModel = ConversationViewModel(storage: storage, messageSending: sending, imageUploading: uploading, target: "them", pageSize: 3, currentUserId: "me")
    }

    private func waitForFirstNonEmptyRows() {
        guard viewModel.rows.isEmpty else { return }
        let expectation = expectation(description: "row appears")
        // Multiple inserts can each trigger their own scheduled emission past
        // the synchronous-first-value guarantee of `.immediate` scheduling
        // (see MessageStore.messagesPublisher's doc comment), so this can
        // legitimately fire more than once — only the first occurrence is
        // significant here, but over-fulfillment must not crash the test.
        expectation.assertForOverFulfill = false
        viewModel.$rows.dropFirst().sink { rows in if !rows.isEmpty { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    func test_initialState_emptyRows() {
        XCTAssertEqual(viewModel.rows, [])
    }

    func test_existingMessage_loadsOnInit() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, conversationType: .single, target: "them", from: "them", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))

        waitForFirstNonEmptyRows()

        guard case .message(let row)? = viewModel.rows.first else { return XCTFail("expected a message row") }
        XCTAssertEqual(row.text, "hi")
        XCTAssertFalse(row.isOutgoing)
    }

    func test_sendText_callsMessageSendingWithFixedTarget() {
        viewModel.sendText("hello")
        XCTAssertEqual(sending.sentTexts.map { $0.text }, ["hello"])
        XCTAssertEqual(sending.sentTexts.map { $0.target }, ["them"])
    }

    func test_sendImage_showsPendingBubbleImmediately() {
        uploading.completesSynchronously = false // simulates the in-flight window before the (real, async) upload resolves

        viewModel.sendImage(fullImageData: Data([0x01]), thumbnail: Data([0x02]))

        guard case .pendingImage(let pending)? = viewModel.rows.first else { return XCTFail("expected a pending image row") }
        XCTAssertEqual(pending.thumbnail, Data([0x02]))
        XCTAssertEqual(pending.state, .uploading)
    }

    func test_sendImage_uploadSucceeds_removesPendingBubbleAndCallsSendImage() {
        uploading.nextResult = .success("https://example.com/img.png")

        viewModel.sendImage(fullImageData: Data([0x01]), thumbnail: Data([0x02]))

        XCTAssertTrue(viewModel.rows.isEmpty) // pending row removed; FakeMessageSending doesn't insert into storage, so no real row appears here
        XCTAssertEqual(sending.sentImages.count, 1)
        XCTAssertEqual(sending.sentImages.first?.remoteURL, "https://example.com/img.png")
        XCTAssertEqual(sending.sentImages.first?.thumbnail, Data([0x02]))
    }

    func test_sendImage_uploadFails_marksPendingBubbleAsFailed() {
        uploading.nextResult = .failure(.invalidUploadURL)

        viewModel.sendImage(fullImageData: Data([0x01]), thumbnail: Data([0x02]))

        guard case .pendingImage(let pending)? = viewModel.rows.first else { return XCTFail("expected a pending image row") }
        XCTAssertEqual(pending.state, .failed)
    }

    func test_retry_onFailedPendingImage_reUploadsWithSameData() {
        uploading.nextResult = .failure(.invalidUploadURL)
        viewModel.sendImage(fullImageData: Data([0x01]), thumbnail: Data([0x02]))
        guard case .pendingImage(let failedRow)? = viewModel.rows.first else { return XCTFail("expected a pending image row") }

        uploading.nextResult = .success("https://example.com/retried.png")
        viewModel.retry(row: .pendingImage(failedRow))

        XCTAssertEqual(uploading.uploadedData, [Data([0x01]), Data([0x01])])
        XCTAssertEqual(sending.sentImages.last?.remoteURL, "https://example.com/retried.png")
        XCTAssertTrue(viewModel.rows.isEmpty)
    }

    func test_retry_onFailedStoredMessage_callsResend() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 9, conversationType: .single, target: "them", from: "me", content: .text("oops"), timestamp: 1_000, status: .sendFailure, direction: .send))
        waitForFirstNonEmptyRows()

        guard case .message(let failedRow)? = viewModel.rows.first else { return XCTFail("expected a message row") }
        viewModel.retry(row: .message(failedRow))

        XCTAssertEqual(sending.resentLocalMessageIds, [9])
    }

    func test_retry_onNonFailedMessage_isANoOp() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 9, conversationType: .single, target: "them", from: "me", content: .text("ok"), timestamp: 1_000, status: .sent, direction: .send))
        waitForFirstNonEmptyRows()

        guard case .message(let row)? = viewModel.rows.first else { return XCTFail("expected a message row") }
        viewModel.retry(row: .message(row))

        XCTAssertTrue(sending.resentLocalMessageIds.isEmpty)
    }

    func test_loadMore_prependsOlderHistory() throws {
        for i in 0..<5 {
            try storage.messages.insert(StoredMessage(localMessageId: Int64(i), conversationType: .single, target: "them", from: "them", content: .text("msg\(i)"), timestamp: Int64(1_000 + i), status: .unread, direction: .receive))
        }
        waitForFirstNonEmptyRows()

        XCTAssertEqual(viewModel.rows.count, 3) // pageSize: 3 — newest 3 of 5

        viewModel.loadMore()

        XCTAssertEqual(viewModel.rows.count, 5)
        guard case .message(let first)? = viewModel.rows.first else { return XCTFail("expected a message row") }
        XCTAssertEqual(first.text, "msg0")
    }

    func test_loadMore_setsCanLoadMoreFalseWhenFewerThanAPageRemains() throws {
        for i in 0..<4 {
            try storage.messages.insert(StoredMessage(localMessageId: Int64(i), conversationType: .single, target: "them", from: "them", content: .text("msg\(i)"), timestamp: Int64(1_000 + i), status: .unread, direction: .receive))
        }
        waitForFirstNonEmptyRows()

        XCTAssertTrue(viewModel.canLoadMore)
        viewModel.loadMore() // only 1 older message exists beyond the initial page of 3

        XCTAssertFalse(viewModel.canLoadMore)
    }

    func test_newLiveMessageArrivingAfterLoadMore_doesNotDropThePreviouslyVisibleOldestLiveRow() throws {
        for i in 0..<5 {
            try storage.messages.insert(StoredMessage(localMessageId: Int64(i), conversationType: .single, target: "them", from: "them", content: .text("msg\(i)"), timestamp: Int64(1_000 + i), status: .unread, direction: .receive))
        }
        waitForFirstNonEmptyRows()
        viewModel.loadMore() // olderRows now holds msg0,msg1; liveRows holds msg2,msg3,msg4

        let expectation = expectation(description: "new message arrives")
        expectation.assertForOverFulfill = false
        viewModel.$rows.dropFirst().sink { rows in if rows.count == 6 { expectation.fulfill() } }.store(in: &cancellables)
        try storage.messages.insert(StoredMessage(localMessageId: 5, conversationType: .single, target: "them", from: "them", content: .text("msg5"), timestamp: 1_005, status: .unread, direction: .receive))
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.compactMap { row -> String? in if case .message(let m) = row { return m.text } else { return nil } }, ["msg0", "msg1", "msg2", "msg3", "msg4", "msg5"])
    }

    func test_systemTipRowEvictedFromLiveWindow_migratesIntoOlderRowsDuringPaging() throws {
        let groupViewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, target: "g1", conversationType: .group, pageSize: 3, currentUserId: "me")
        try storage.users.upsertProfile(uid: "u1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        try storage.messages.insert(StoredMessage(localMessageId: 0, messageUid: 0, conversationType: .group, target: "g1", from: "them", content: .text("msg0"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .createGroup, operatorUid: "u1", memberUids: [], value: nil),
            timestamp: 1_001, status: .unread, direction: .receive
        ))
        for i in 2..<5 {
            try storage.messages.insert(StoredMessage(localMessageId: Int64(i), messageUid: Int64(i), conversationType: .group, target: "g1", from: "them", content: .text("msg\(i)"), timestamp: Int64(1_000 + i), status: .unread, direction: .receive))
        }
        let expectationFirst = expectation(description: "row appears")
        expectationFirst.assertForOverFulfill = false
        groupViewModel.$rows.dropFirst().sink { rows in if !rows.isEmpty { expectationFirst.fulfill() } }.store(in: &cancellables)
        wait(for: [expectationFirst], timeout: 2)

        groupViewModel.loadMore() // olderRows now holds msg0,(systemTip); liveRows holds msg2,msg3,msg4

        let expectation = expectation(description: "new message arrives")
        expectation.assertForOverFulfill = false
        groupViewModel.$rows.dropFirst().sink { rows in if rows.count == 6 { expectation.fulfill() } }.store(in: &cancellables)
        try storage.messages.insert(StoredMessage(localMessageId: 5, messageUid: 5, conversationType: .group, target: "g1", from: "them", content: .text("msg5"), timestamp: 1_005, status: .unread, direction: .receive))
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(groupViewModel.rows.count, 6)
        guard case .systemTip(let tip) = groupViewModel.rows[1] else { return XCTFail("expected the createGroup notification to have migrated into olderRows as a .systemTip row, in timestamp order between msg0 and msg2") }
        XCTAssertEqual(tip.text, "Alice创建了群组")
        XCTAssertEqual(groupViewModel.rows.compactMap { row -> String? in
            switch row {
            case .message(let m): return m.text
            case .systemTip: return "<systemTip>"
            case .pendingImage: return nil
            }
        }, ["msg0", "<systemTip>", "msg2", "msg3", "msg4", "msg5"])
    }

    func test_groupTextMessage_received_populatesSenderDisplayNameAndAvatar() throws {
        try storage.users.upsertProfile(uid: "sender1", name: nil, displayName: "Alice", portrait: "http://x/a.png", mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "sender1", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .message(let message) = row else { return XCTFail("expected .message") }
        XCTAssertEqual(message.senderDisplayName, "Alice")
        XCTAssertEqual(message.senderAvatarURL, "http://x/a.png")
    }

    func test_groupTextMessage_sentByMe_hasNilSenderFields() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "me", content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .message(let message) = row else { return XCTFail("expected .message") }
        XCTAssertNil(message.senderDisplayName)
    }

    func test_singleChatTextMessage_neverHasSenderFields() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .single, target: "u2", from: "u2", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))
        let viewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, target: "u2", conversationType: .single, currentUserId: "me")

        let row = try waitForFirstRow(viewModel)

        guard case .message(let message) = row else { return XCTFail("expected .message") }
        XCTAssertNil(message.senderDisplayName)
    }

    func test_groupNotificationMessage_rendersAsSystemTipWithChineseText() throws {
        try storage.users.upsertProfile(uid: "u1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .createGroup, operatorUid: "u1", memberUids: [], value: nil),
            timestamp: 1_000, status: .unread, direction: .receive
        ))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .systemTip(let tip) = row else { return XCTFail("expected .systemTip") }
        XCTAssertEqual(tip.text, "Alice创建了群组")
    }

    func test_groupNotificationMessage_operatorIsMe_substitutesNin() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "me",
            content: .groupNotification(type: .quitGroup, operatorUid: "me", memberUids: [], value: nil),
            timestamp: 1_000, status: .sent, direction: .send
        ))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .systemTip(let tip) = row else { return XCTFail("expected .systemTip") }
        XCTAssertEqual(tip.text, "您退出了群组")
    }

    func test_groupNotificationMessage_changeGroupName_includesNewNameInQuotes() throws {
        try storage.users.upsertProfile(uid: "u1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .changeGroupName, operatorUid: "u1", memberUids: [], value: "新群名"),
            timestamp: 1_000, status: .unread, direction: .receive
        ))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .systemTip(let tip) = row else { return XCTFail("expected .systemTip") }
        XCTAssertEqual(tip.text, "Alice修改群名为「新群名」")
    }

    func test_retry_onSystemTipRow_isNoOp() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .dismissGroup, operatorUid: "u1", memberUids: [], value: nil),
            timestamp: 1_000, status: .unread, direction: .receive
        ))
        let viewModel = makeGroupViewModel(target: "g1")
        let row = try waitForFirstRow(viewModel)

        viewModel.retry(row: row) // must not crash
    }

    func test_sendText_withMentionParams_forwardsThemToMessageSending() throws {
        // Uses the file's existing `sending` fixture (the updated
        // `FakeMessageSending` from this task's Step 3) rather than
        // constructing a separate one.
        viewModel.sendText("hi @u2", mentionedType: 1, mentionedTargets: ["u2"])

        XCTAssertEqual(sending.lastMentionedType, 1)
        XCTAssertEqual(sending.lastMentionedTargets, ["u2"])
    }

    func test_groupMemberCandidatesForMention_returnsActiveMembersWithDisplayNames() throws {
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u2", memberType: .normal, updateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u3", memberType: .removed, updateDt: 0))
        try storage.users.upsertProfile(uid: "u2", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        let viewModel = makeGroupViewModel(target: "g1")

        let candidates = viewModel.groupMemberCandidatesForMention()

        XCTAssertEqual(candidates.map(\.uid), ["u2"])
        XCTAssertEqual(candidates.map(\.displayName), ["Bob"])
    }

    func test_groupMemberCandidatesForMention_onSingleChat_returnsEmpty() throws {
        let viewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, target: "u2", conversationType: .single, currentUserId: "me")

        XCTAssertEqual(viewModel.groupMemberCandidatesForMention().count, 0)
    }

    private func makeGroupViewModel(target: String) -> ConversationViewModel {
        ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, target: target, conversationType: .group, currentUserId: "me")
    }

    private func waitForFirstRow(_ viewModel: ConversationViewModel) throws -> ChatMessageRow {
        try XCTUnwrap(viewModel.rows.first)
    }

    func test_callRecordRow_audioOnlyConnected_showsDurationText() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "them", from: "me",
            content: .callRecord(callId: "call-1", targetId: "them", audioOnly: true, status: 2, connectTime: 5_000, endTime: 65_000),
            timestamp: 1_000, status: .sent, direction: .send
        ))
        waitForFirstNonEmptyRows()

        guard case .message(let row)? = viewModel.rows.first else { return XCTFail("expected a message row") }
        XCTAssertEqual(row.text, "📞 语音通话 01:00")
    }

    func test_callRecordRow_videoConnected_showsDurationTextWithVideoIcon() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "them", from: "me",
            content: .callRecord(callId: "call-1", targetId: "them", audioOnly: false, status: 2, connectTime: 5_000, endTime: 35_000),
            timestamp: 1_000, status: .sent, direction: .send
        ))
        waitForFirstNonEmptyRows()

        guard case .message(let row)? = viewModel.rows.first else { return XCTFail("expected a message row") }
        XCTAssertEqual(row.text, "📹 视频通话 00:30")
    }

    func test_callRecordRow_neverConnected_outgoing_showsCancelledText() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "them", from: "me",
            content: .callRecord(callId: "call-1", targetId: "them", audioOnly: true, status: 2, connectTime: 0, endTime: 0),
            timestamp: 1_000, status: .sent, direction: .send
        ))
        waitForFirstNonEmptyRows()

        guard case .message(let row)? = viewModel.rows.first else { return XCTFail("expected a message row") }
        XCTAssertEqual(row.text, "📞 已取消")
    }

    func test_callRecordRow_neverConnected_incoming_showsMissedText() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "them", from: "them",
            content: .callRecord(callId: "call-1", targetId: "me", audioOnly: false, status: 2, connectTime: 0, endTime: 0),
            timestamp: 1_000, status: .read, direction: .receive
        ))
        waitForFirstNonEmptyRows()

        guard case .message(let row)? = viewModel.rows.first else { return XCTFail("expected a message row") }
        XCTAssertEqual(row.text, "📹 未接听")
    }
}
