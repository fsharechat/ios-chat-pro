import XCTest
import Combine
import IMStorage
@testable import IMKit

private final class FakeRemoteHistoryFetching: RemoteHistoryFetching {
    private(set) var calls: [(beforeUid: Int64, count: Int)] = []
    /// When set, invoked instead of the default `completion(0)` so a test can
    /// insert rows into storage (as the real service does) before completing.
    var onLoad: ((_ beforeUid: Int64, _ count: Int, _ completion: @escaping (Int?) -> Void) -> Void)?

    func loadRemoteMessages(conversationType: ConversationType, target: String, line: Int, beforeUid: Int64, count: Int, completion: @escaping (Int?) -> Void) {
        calls.append((beforeUid, count))
        if let onLoad {
            onLoad(beforeUid, count, completion)
        } else {
            completion(0)
        }
    }
}

/// Covers `ConversationViewModel.loadMoreHistory` — the pull-to-refresh
/// entry point mirroring Android's `loadOldMessages`: local storage first,
/// remote fallback only once local history is exhausted.
final class ConversationViewModelRemoteHistoryTests: XCTestCase {
    private var storage: IMStorage!
    private var remote: FakeRemoteHistoryFetching!
    private var viewModel: ConversationViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        remote = FakeRemoteHistoryFetching()
        viewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, remoteHistory: remote, target: "them", pageSize: 3, currentUserId: "me")
    }

    private func insertMessage(uid: Int64, text: String, timestamp: Int64) throws {
        try storage.messages.insert(StoredMessage(localMessageId: uid, messageUid: uid, conversationType: .single, target: "them", from: "them", content: .text(text), timestamp: timestamp, status: .unread, direction: .receive))
    }

    private func waitForFirstNonEmptyRows() {
        guard viewModel.rows.isEmpty else { return }
        let expectation = expectation(description: "row appears")
        expectation.assertForOverFulfill = false
        viewModel.$rows.dropFirst().sink { rows in if !rows.isEmpty { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    private func rowTexts() -> [String] {
        viewModel.rows.compactMap { if case .message(let m) = $0 { return m.text } else { return nil } }
    }

    func test_loadMoreHistory_localPageAvailable_doesNotHitRemote() throws {
        for i in 0..<6 { try insertMessage(uid: Int64(i + 1), text: "msg\(i)", timestamp: Int64(1_000 + i)) }
        waitForFirstNonEmptyRows()

        var completed = false
        viewModel.loadMoreHistory { completed = true }

        XCTAssertTrue(completed)
        XCTAssertTrue(remote.calls.isEmpty)
        XCTAssertEqual(rowTexts().first, "msg0")
    }

    func test_loadMoreHistory_localExhausted_fetchesRemoteBeforeOldestUid() throws {
        for i in 0..<3 { try insertMessage(uid: Int64(i + 10), text: "msg\(i)", timestamp: Int64(1_000 + i)) }
        waitForFirstNonEmptyRows()

        remote.onLoad = { [storage] _, _, completion in
            // The real service persists fetched history before completing.
            try? storage!.messages.insert(StoredMessage(localMessageId: 5, messageUid: 5, conversationType: .single, target: "them", from: "them", content: .text("remote-old"), timestamp: 500, status: .read, direction: .receive))
            completion(1)
        }

        var completed = false
        viewModel.loadMoreHistory { completed = true }

        XCTAssertTrue(completed)
        XCTAssertEqual(remote.calls.count, 1)
        XCTAssertEqual(remote.calls.first?.beforeUid, 10) // oldest loaded message's uid
        XCTAssertEqual(remote.calls.first?.count, 3) // pageSize
        XCTAssertEqual(rowTexts().first, "remote-old")
    }

    func test_loadMoreHistory_remoteReturnsNothing_stopsAskingRemote() throws {
        for i in 0..<3 { try insertMessage(uid: Int64(i + 1), text: "msg\(i)", timestamp: Int64(1_000 + i)) }
        waitForFirstNonEmptyRows()

        viewModel.loadMoreHistory {}
        viewModel.loadMoreHistory {}

        XCTAssertEqual(remote.calls.count, 1)
    }

    /// Regression: the remote fetch completing `nil` means the *request*
    /// failed (timeout, server error) — not that history is exhausted. The
    /// next pull must issue a fresh LRM request instead of staying latched
    /// off forever; only a successful-but-empty page (0) may latch.
    func test_loadMoreHistory_remoteFailedOnce_retriesOnNextPull() throws {
        for i in 0..<3 { try insertMessage(uid: Int64(i + 1), text: "msg\(i)", timestamp: Int64(1_000 + i)) }
        waitForFirstNonEmptyRows()

        remote.onLoad = { _, _, completion in completion(nil) }
        viewModel.loadMoreHistory {}
        XCTAssertEqual(remote.calls.count, 1)

        // Second pull retries; this time the fetch succeeds and pages in.
        remote.onLoad = { [storage] _, _, completion in
            try? storage!.messages.insert(StoredMessage(localMessageId: 100, messageUid: 0, conversationType: .single, target: "them", from: "them", content: .text("remote-old"), timestamp: 500, status: .read, direction: .receive))
            completion(1)
        }
        viewModel.loadMoreHistory {}

        XCTAssertEqual(remote.calls.count, 2)
        XCTAssertEqual(rowTexts().first, "remote-old")
    }

    /// Regression: with fewer local messages than pageSize the live window
    /// isn't full, so persisting remote history makes `messagesPublisher`
    /// re-emit a window *expanded backward* over the very rows
    /// `loadMoreHistory` just paged into `olderRows`. Without dedup in
    /// `handleMessagesUpdate`, `olderRows + liveRows` then contains the same
    /// storageId twice — crashing the diffable data source ("supplied item
    /// identifiers are not unique").
    func test_remoteHistoryExpandingLiveWindow_doesNotDuplicateRows() throws {
        for i in 0..<2 { try insertMessage(uid: Int64(i + 10), text: "msg\(i)", timestamp: Int64(1_000 + i)) }
        waitForFirstNonEmptyRows()

        remote.onLoad = { [storage] _, _, completion in
            try? storage!.messages.insert(StoredMessage(localMessageId: 5, messageUid: 5, conversationType: .single, target: "them", from: "them", content: .text("remote-old"), timestamp: 500, status: .read, direction: .receive))
            completion(1)
        }
        viewModel.loadMoreHistory {}

        // The publisher's expanded-window emission arrives asynchronously —
        // fail if any emission within the window ever contains a duplicate.
        let duplicate = expectation(description: "a published rows array contains duplicate storageIds")
        duplicate.isInverted = true
        viewModel.$rows.sink { rows in
            let ids = rows.compactMap(\.storageId)
            if Set(ids).count != ids.count { duplicate.fulfill() }
        }.store(in: &cancellables)
        wait(for: [duplicate], timeout: 1)

        XCTAssertEqual(rowTexts(), ["remote-old", "msg0", "msg1"])
    }

    /// Regression: a first-login sync can leave a conversation whose only
    /// rows render as `.systemTip` (a recalled message, a group notification).
    /// The remote cursor must still use that row's real messageUid — sending
    /// 0 makes the server page "from the newest", skipping actual history.
    func test_loadMoreHistory_onlySystemTipRows_usesTheirUidAsCursor() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 562_596_170_937_926_434, conversationType: .single, target: "them", from: "them", content: .recalled(operatorId: "them"), timestamp: 1_000, status: .read, direction: .receive))
        waitForFirstNonEmptyRows()

        viewModel.loadMoreHistory {}

        XCTAssertEqual(remote.calls.count, 1)
        XCTAssertEqual(remote.calls.first?.beforeUid, 562_596_170_937_926_434)
    }

    func test_loadMoreHistory_withoutRemoteFetcher_stillCompletes() throws {
        let localOnly = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, target: "them", pageSize: 3, currentUserId: "me")
        var completed = false
        localOnly.loadMoreHistory { completed = true }
        XCTAssertTrue(completed)
    }
}
