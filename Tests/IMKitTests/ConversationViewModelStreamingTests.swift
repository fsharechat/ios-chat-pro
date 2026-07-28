import XCTest
import Combine
import IMStorage
import IMMessaging
@testable import IMKit

private final class FakeStreamingAiObserving: StreamingAiObserving {
    var onSaiToken: ((String, String, Bool, String) -> Void)?
    var activeStream: StreamingState?
    private(set) var clearCount = 0

    func clearActiveStream() {
        activeStream = nil
        clearCount += 1
    }

    func emit(streamId: String, delta: String, done: Bool, target: String) {
        onSaiToken?(streamId, delta, done, target)
    }
}

final class ConversationViewModelStreamingTests: XCTestCase {
    private var storage: IMStorage!
    private var streaming: FakeStreamingAiObserving!
    private var viewModel: ConversationViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        streaming = FakeStreamingAiObserving()
        viewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, streaming: streaming, target: "agent", currentUserId: "me")
    }

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func streamingRowInRows() -> StreamingRow? {
        for row in viewModel.rows {
            if case .streaming(let streamingRow) = row { return streamingRow }
        }
        return nil
    }

    func test_emptyDelta_createsPlaceholderRow() {
        streaming.emit(streamId: "s1", delta: "", done: false, target: "agent")

        XCTAssertEqual(streamingRowInRows(), StreamingRow(streamId: "s1", text: "", done: false))
    }

    func test_placeholderRow_carriesAgentAvatarAcrossDeltas() throws {
        try storage.users.upsertProfile(uid: "agent", name: nil, displayName: "客服", portrait: "https://example.com/agent.png", mobile: nil, gender: 0, updateDt: 0)

        streaming.emit(streamId: "s1", delta: "", done: false, target: "agent")
        XCTAssertEqual(streamingRowInRows()?.senderAvatarURL, "https://example.com/agent.png")

        streaming.emit(streamId: "s1", delta: "你好", done: false, target: "agent")
        streaming.emit(streamId: "s1", delta: "", done: true, target: "agent")
        XCTAssertEqual(streamingRowInRows()?.senderAvatarURL, "https://example.com/agent.png")
    }

    func test_delta_appendsText() {
        streaming.emit(streamId: "s1", delta: "", done: false, target: "agent")
        streaming.emit(streamId: "s1", delta: "你", done: false, target: "agent")
        streaming.emit(streamId: "s1", delta: "好", done: false, target: "agent")

        XCTAssertEqual(streamingRowInRows(), StreamingRow(streamId: "s1", text: "你好", done: false))
    }

    func test_done_marksDoneAndKeepsRow() {
        streaming.emit(streamId: "s1", delta: "", done: false, target: "agent")
        streaming.emit(streamId: "s1", delta: "你好", done: false, target: "agent")
        streaming.emit(streamId: "s1", delta: "", done: true, target: "agent")

        XCTAssertEqual(streamingRowInRows(), StreamingRow(streamId: "s1", text: "你好", done: true))
    }

    func test_otherTarget_isIgnored() {
        streaming.emit(streamId: "s1", delta: "", done: false, target: "someoneElse")

        XCTAssertNil(streamingRowInRows())
    }

    func test_mismatchedStreamId_deltaIgnored() {
        streaming.emit(streamId: "s1", delta: "", done: false, target: "agent")
        streaming.emit(streamId: "s2", delta: "串台", done: false, target: "agent")

        XCTAssertEqual(streamingRowInRows(), StreamingRow(streamId: "s1", text: "", done: false))
    }

    func test_groupConversation_doesNotBind() {
        let groupStreaming = FakeStreamingAiObserving()
        let groupViewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, streaming: groupStreaming, target: "g1", conversationType: .group, currentUserId: "me")

        XCTAssertNil(groupStreaming.onSaiToken)
        _ = groupViewModel
    }

    func test_init_restoresUnfinishedActiveStream() {
        let restored = FakeStreamingAiObserving()
        restored.activeStream = StreamingState(streamId: "s9", target: "agent", accumulatedText: "写了一半", done: false)

        let restoredViewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, streaming: restored, target: "agent", currentUserId: "me")

        XCTAssertEqual(restoredViewModel.rows.last, .streaming(StreamingRow(streamId: "s9", text: "写了一半", done: false)))
    }

    func test_init_doesNotRestoreDoneOrForeignStream() {
        let doneStreaming = FakeStreamingAiObserving()
        doneStreaming.activeStream = StreamingState(streamId: "s9", target: "agent", accumulatedText: "已完成", done: true)
        let doneViewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, streaming: doneStreaming, target: "agent", currentUserId: "me")
        XCTAssertTrue(doneViewModel.rows.isEmpty)

        let foreignStreaming = FakeStreamingAiObserving()
        foreignStreaming.activeStream = StreamingState(streamId: "s9", target: "other", accumulatedText: "别人的", done: false)
        let foreignViewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, streaming: foreignStreaming, target: "agent", currentUserId: "me")
        XCTAssertTrue(foreignViewModel.rows.isEmpty)
    }

    func test_newIncomingMessage_removesPlaceholderAndClearsActiveStream() throws {
        streaming.emit(streamId: "s1", delta: "", done: false, target: "agent")
        streaming.emit(streamId: "s1", delta: "你好", done: false, target: "agent")
        streaming.emit(streamId: "s1", delta: "", done: true, target: "agent")
        XCTAssertNotNil(streamingRowInRows())

        let messageArrived = expectation(description: "real message arrives")
        messageArrived.assertForOverFulfill = false
        viewModel.$rows.dropFirst().sink { rows in
            if rows.contains(where: { if case .message = $0 { return true }; return false }) {
                messageArrived.fulfill()
            }
        }.store(in: &cancellables)
        try storage.messages.insert(StoredMessage(localMessageId: 1, conversationType: .single, target: "agent", from: "agent", content: .text("你好,有什么可以帮您?"), timestamp: 1_000, status: .unread, direction: .receive))
        wait(for: [messageArrived], timeout: 2)

        XCTAssertNil(streamingRowInRows())
        XCTAssertEqual(streaming.clearCount, 1)
    }

    func test_markActive_rebindsListener() {
        // 模拟另一个会话页抢走了单监听者
        streaming.onSaiToken = nil

        viewModel.markActive()

        XCTAssertNotNil(streaming.onSaiToken)
    }
}
