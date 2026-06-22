import XCTest
import Combine
import IMStorage
import IMMedia
@testable import IMKit

private final class FakeMessageSending: MessageSending {
    private(set) var sentTexts: [(target: String, text: String)] = []
    private(set) var sentImages: [(target: String, thumbnail: Data?, remoteURL: String)] = []
    private(set) var resentLocalMessageIds: [Int64] = []

    func sendText(to target: String, conversationType: ConversationType, line: Int, text: String, mentionedType: Int32, mentionedTargets: [String]) throws {
        sentTexts.append((target, text))
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
        viewModel = ConversationViewModel(storage: storage, messageSending: sending, imageUploading: uploading, target: "them", pageSize: 3)
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
}
