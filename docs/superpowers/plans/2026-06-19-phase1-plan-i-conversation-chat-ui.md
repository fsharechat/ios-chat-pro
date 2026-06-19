# Plan I: 单聊聊天界面 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现单聊(1:1)聊天界面:文字+图片消息收发展示、下拉加载历史、发送失败重试、图片点击全屏预览,替换掉 `App/ConversationViewController.swift` 当前的占位实现。

**Architecture:** 不新增 SwiftPM target。`Sources/IMStorage/MessageStore.swift` 新增响应式"最新一页"查询 + 一次性"翻页历史"查询;`Sources/IMMessaging/MessagingService.swift` 新增 `resend(localMessageId:)`;`Sources/IMKit` 新增 `ConversationViewModel`(依赖 `MessageSending`/`ImageUploading` 两个窄接口,而非具体类型,复用 `ContactInfoFetching` 已确立的解耦套路)+ 展示行模型;`App/` 新增聊天界面的 `UIViewController`/`UITableViewCell`/输入栏/全屏预览,均不写自动化测试(与本项目其它 `*ViewController`/`*Cell` 的既定取向一致),仅靠编译 + 模拟器验证。

**Tech Stack:** UIKit + Combine + GRDB(已有),`PHPickerViewController`(新)用于选图。

参考设计文档:`docs/superpowers/specs/2026-06-19-plan-i-conversation-chat-ui-design.md`

---

## Task 1: `MessageStore.messagesPublisher`

**Files:**
- Modify: `Sources/IMStorage/MessageStore.swift`
- Test: `Tests/IMStorageTests/MessageStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/IMStorageTests/MessageStoreTests.swift` 目前没有 `import Combine` 也没有 `cancellables` 属性。在文件顶部加 `import Combine`,在 `MessageStoreTests` 类里加一个属性,并在文件末尾(最后一个 `}` 之前)追加两个测试:

```swift
import GRDB
import Combine
import XCTest
@testable import IMStorage

final class MessageStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: MessageStore!
    private var cancellables: Set<AnyCancellable> = []
```

(其余现有内容不变,只在类顶部加上 `cancellables` 属性声明。)

在文件末尾追加:

```swift
    func test_messagesPublisher_emitsLatestMessagesInAscendingOrder() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "first"))
        try store.insert(makeMessage(localMessageId: 2, timestamp: 2_000, text: "second"))

        var received: [[MessageContent]] = []
        let expectation = expectation(description: "received at least 2 updates")
        expectation.expectedFulfillmentCount = 2

        store.messagesPublisher(conversationType: .single, target: "u2")
            .sink(receiveCompletion: { _ in }, receiveValue: { messages in
                received.append(messages.map { $0.content })
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.insert(makeMessage(localMessageId: 3, timestamp: 3_000, text: "third"))

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(received[0], [.text("first"), .text("second")])
        XCTAssertEqual(received[1], [.text("first"), .text("second"), .text("third")])
    }

    func test_messagesPublisher_respectsLimit_keepingNewestWithinWindow() throws {
        for i in 0..<5 {
            try store.insert(makeMessage(localMessageId: Int64(i), timestamp: Int64(i), text: "msg\(i)"))
        }

        var received: [MessageContent] = []
        let expectation = expectation(description: "received update")
        store.messagesPublisher(conversationType: .single, target: "u2", limit: 2)
            .sink(receiveCompletion: { _ in }, receiveValue: { messages in
                received = messages.map { $0.content }
                expectation.fulfill()
            })
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(received, [.text("msg3"), .text("msg4")])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MessageStoreTests`
Expected: FAIL with `value of type 'MessageStore' has no member 'messagesPublisher'`

- [ ] **Step 3: Implement**

在 `Sources/IMStorage/MessageStore.swift` 顶部加 `import Combine`,在 `messages(conversationType:target:line:limit:)` 方法后面加:

```swift
    /// Reactive "latest `limit` messages" query, ascending by time (oldest
    /// first) — the opposite order from `messages(...)` above, because this
    /// feeds a chat screen that renders top-to-bottom. Re-fires on any
    /// insert/update affecting this conversation (new sends, new receives,
    /// ack status changes). See `olderMessages` below for paging further
    /// back — this method's `limit` is fixed, not meant to grow as the user
    /// scrolls.
    public func messagesPublisher(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        limit: Int = 50
    ) -> AnyPublisher<[StoredMessage], Error> {
        ValueObservation
            .tracking { db in
                try StoredMessage
                    .filter(Column("conversationType") == conversationType.rawValue)
                    .filter(Column("target") == target)
                    .filter(Column("line") == line)
                    .order(Column("timestamp").desc, Column("id").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            .publisher(in: dbQueue, scheduling: .immediate)
            .map { Array($0.reversed()) }
            .eraseToAnyPublisher()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MessageStoreTests`
Expected: `Executed <N> tests, with 0 failures` (existing tests + 2 new ones, all passing)

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests pass (223 + 2 = 225).

- [ ] **Step 6: Commit**

```bash
git add Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/MessageStoreTests.swift
git commit -m "feat(IMStorage): add MessageStore.messagesPublisher"
```

---

## Task 2: `MessageStore.olderMessages`

**Files:**
- Modify: `Sources/IMStorage/MessageStore.swift`
- Test: `Tests/IMStorageTests/MessageStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/IMStorageTests/MessageStoreTests.swift` (before the final closing `}`):

```swift
    func test_olderMessages_returnsMessagesBeforeAnchorInAscendingOrder() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "first"))
        try store.insert(makeMessage(localMessageId: 2, timestamp: 2_000, text: "second"))
        try store.insert(makeMessage(localMessageId: 3, timestamp: 3_000, text: "third"))

        let older = try store.olderMessages(conversationType: .single, target: "u2", beforeTimestamp: 3_000, beforeId: 3, limit: 50)

        XCTAssertEqual(older.map { $0.content }, [.text("first"), .text("second")])
    }

    func test_olderMessages_respectsLimit() throws {
        for i in 0..<5 {
            try store.insert(makeMessage(localMessageId: Int64(i), timestamp: Int64(i), text: "msg\(i)"))
        }

        let older = try store.olderMessages(conversationType: .single, target: "u2", beforeTimestamp: 5_000, beforeId: 999, limit: 2)

        XCTAssertEqual(older.map { $0.content }, [.text("msg3"), .text("msg4")])
    }

    func test_olderMessages_tieBreaksOnIdWhenTimestampsCollide() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "a"))
        try store.insert(makeMessage(localMessageId: 2, timestamp: 1_000, text: "b"))
        let third = try store.insert(makeMessage(localMessageId: 3, timestamp: 1_000, text: "c"))

        let older = try store.olderMessages(conversationType: .single, target: "u2", beforeTimestamp: third.timestamp, beforeId: third.id!, limit: 50)

        XCTAssertEqual(older.map { $0.content }, [.text("a"), .text("b")])
    }

    func test_olderMessages_emptyWhenNoOlderHistoryExists() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "only"))

        let older = try store.olderMessages(conversationType: .single, target: "u2", beforeTimestamp: 1_000, beforeId: 1, limit: 50)

        XCTAssertTrue(older.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MessageStoreTests`
Expected: FAIL with `value of type 'MessageStore' has no member 'olderMessages'`

- [ ] **Step 3: Implement**

In `Sources/IMStorage/MessageStore.swift`, after `messagesPublisher`, add:

```swift
    /// One-shot (non-reactive) page of history strictly before
    /// `(beforeTimestamp, beforeId)` — `id` (GRDB's autoincrement primary
    /// key) breaks ties when multiple messages share the same millisecond
    /// timestamp, which plain `timestamp` comparison can't disambiguate.
    /// Returns ascending order (oldest first), matching `messagesPublisher`'s
    /// contract, so callers can simply prepend the result to what they
    /// already have.
    public func olderMessages(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        beforeTimestamp: Int64,
        beforeId: Int64,
        limit: Int = 50
    ) throws -> [StoredMessage] {
        try dbQueue.read { db in
            let rows = try StoredMessage.fetchAll(db, sql: """
                SELECT * FROM message
                WHERE conversationType = ? AND target = ? AND line = ?
                  AND (timestamp < ? OR (timestamp = ? AND id < ?))
                ORDER BY timestamp DESC, id DESC
                LIMIT ?
                """, arguments: [
                    conversationType.rawValue, target, line,
                    beforeTimestamp, beforeTimestamp, beforeId,
                    limit,
                ])
            return Array(rows.reversed())
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MessageStoreTests`
Expected: all `MessageStoreTests` pass.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests pass (225 + 4 = 229).

- [ ] **Step 6: Commit**

```bash
git add Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/MessageStoreTests.swift
git commit -m "feat(IMStorage): add MessageStore.olderMessages for chat history pagination"
```

---

## Task 3: `MessagingService.resend`

**Files:**
- Modify: `Sources/IMMessaging/MessagingService.swift`
- Test: `Tests/IMMessagingTests/MessagingServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/IMMessagingTests/MessagingServiceTests.swift` (before the final closing `}`):

```swift
    func test_resend_afterSendFailure_resetsStatusAndSendsNewWireFrame() throws {
        try service.sendText(to: "them", text: "hello")
        scheduler.fireNext() // 5s ack timeout fires -> .sendFailure
        let failed = try storage.messages.messages(conversationType: .single, target: "them").first!
        XCTAssertEqual(failed.status, .sendFailure)

        try service.resend(localMessageId: failed.localMessageId)

        let resending = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(resending?.status, .sending)

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .ms)
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.localMessageID, failed.localMessageId)
        XCTAssertEqual(try MessageContentCodec.decode(wireMessage.content), .text("hello"))
    }

    func test_resend_ackArrival_updatesStatusAndMessageUid() throws {
        try service.sendText(to: "them", text: "hello")
        scheduler.fireNext()
        let failed = try storage.messages.messages(conversationType: .single, target: "them").first!

        try service.resend(localMessageId: failed.localMessageId)
        let resendFrame = try decodeOnlySentFrame()

        var ackBody: [UInt8] = [0x00]
        let uidBytes = (0..<8).map { UInt8((UInt64(bitPattern: 999) >> (8 * (7 - $0))) & 0xFF) }
        let tsBytes = (0..<8).map { UInt8((UInt64(bitPattern: 1_234) >> (8 * (7 - $0))) & 0xFF) }
        ackBody += uidBytes + tsBytes
        let ackFrameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .ms, messageId: resendFrame.header.messageId, body: Data(ackBody))
        fakeTransport.simulateReceivedData(ackFrameBytes)

        let updated = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(updated?.status, .sent)
        XCTAssertEqual(updated?.messageUid, 999)
    }

    func test_resend_unknownLocalMessageId_isANoOp() throws {
        let countBefore = fakeTransport.sentFrames.count

        try service.resend(localMessageId: 99999)

        XCTAssertEqual(fakeTransport.sentFrames.count, countBefore)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MessagingServiceTests`
Expected: FAIL with `value of type 'MessagingService' has no member 'resend'`

- [ ] **Step 3: Implement**

Replace the existing `private func send(...)` method in `Sources/IMMessaging/MessagingService.swift` with a refactored version that extracts the wire-send+tracking logic into a shared private helper, and add the new public `resend` method. Replace this block:

```swift
    private func send(to target: String, conversationType: ConversationType, line: Int, content: MessageContent) throws {
        let localMessageId = idGenerator.next()
        let timestamp = nowMillis()

        let echo = try storage.messages.insert(StoredMessage(
            localMessageId: localMessageId,
            conversationType: conversationType,
            target: target,
            line: line,
            from: imClient.userId,
            content: content,
            timestamp: timestamp,
            status: .sending,
            direction: .send
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: conversationType, target: target, line: line,
            messageUid: 0, timestamp: timestamp, incrementUnread: false
        )
        // No transaction wraps the two calls above: if `recordIncomingMessage`
        // throws after `insert` succeeds, this function returns early (never
        // reaching `sendFrame`/`tracker.track`), leaving a message row stuck
        // in `.sending` with no conversation update — the same accepted-for-
        // Phase-1 gap documented in `ReceiveMessageHandler.persist`.

        var wireMessage = Im_Message()
        wireMessage.conversation.type = Int32(conversationType.rawValue)
        wireMessage.conversation.target = target
        wireMessage.conversation.line = Int32(line)
        wireMessage.fromUser = imClient.userId
        wireMessage.content = MessageContentCodec.encode(content)
        wireMessage.localMessageID = localMessageId

        let body = try wireMessage.serializedData()
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .ms, body: body)
        tracker.track(wireMessageId: wireMessageId, localMessageId: echo.localMessageId) { [weak self] localId, result in
            guard let self else { return }
            switch result {
            case .acked(let messageUid, _):
                try? self.storage.messages.updateMessageUid(localMessageId: localId, messageUid: messageUid)
                try? self.storage.messages.updateStatus(localMessageId: localId, status: .sent)
            case .failed:
                try? self.storage.messages.updateStatus(localMessageId: localId, status: .sendFailure)
            }
        }
    }
```

with:

```swift
    private func send(to target: String, conversationType: ConversationType, line: Int, content: MessageContent) throws {
        let localMessageId = idGenerator.next()
        let timestamp = nowMillis()

        let echo = try storage.messages.insert(StoredMessage(
            localMessageId: localMessageId,
            conversationType: conversationType,
            target: target,
            line: line,
            from: imClient.userId,
            content: content,
            timestamp: timestamp,
            status: .sending,
            direction: .send
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: conversationType, target: target, line: line,
            messageUid: 0, timestamp: timestamp, incrementUnread: false
        )
        // No transaction wraps the two calls above: if `recordIncomingMessage`
        // throws after `insert` succeeds, this function returns early (never
        // reaching `sendWireMessage`), leaving a message row stuck in
        // `.sending` with no conversation update — the same accepted-for-
        // Phase-1 gap documented in `ReceiveMessageHandler.persist`.

        try sendWireMessage(localMessageId: echo.localMessageId, conversationType: conversationType, target: target, line: line, content: content)
    }

    /// Re-sends an already-stored message that previously failed (`status
    /// == .sendFailure`) — e.g. the user tapped a retry affordance on a
    /// failed bubble. Reuses the existing row's `localMessageId`/content
    /// rather than inserting a new row, so the UI sees the same message
    /// transition back to `.sending` rather than a duplicate appearing.
    /// Doesn't touch the conversation's last-message preview/timestamp —
    /// unlike a fresh `send`, this isn't a new logical message, so there's
    /// nothing new to reflect there. A no-op if no such sent-direction row
    /// exists for `localMessageId` (mirrors `MessageStore.updateStatus`'s
    /// own silent-no-op-on-not-found behavior).
    public func resend(localMessageId: Int64) throws {
        guard let message = try storage.messages.message(localMessageId: localMessageId) else { return }
        try storage.messages.updateStatus(localMessageId: localMessageId, status: .sending)
        try sendWireMessage(localMessageId: localMessageId, conversationType: message.conversationType, target: message.target, line: message.line, content: message.content)
    }

    private func sendWireMessage(localMessageId: Int64, conversationType: ConversationType, target: String, line: Int, content: MessageContent) throws {
        var wireMessage = Im_Message()
        wireMessage.conversation.type = Int32(conversationType.rawValue)
        wireMessage.conversation.target = target
        wireMessage.conversation.line = Int32(line)
        wireMessage.fromUser = imClient.userId
        wireMessage.content = MessageContentCodec.encode(content)
        wireMessage.localMessageID = localMessageId

        let body = try wireMessage.serializedData()
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .ms, body: body)
        tracker.track(wireMessageId: wireMessageId, localMessageId: localMessageId) { [weak self] localId, result in
            guard let self else { return }
            switch result {
            case .acked(let messageUid, _):
                try? self.storage.messages.updateMessageUid(localMessageId: localId, messageUid: messageUid)
                try? self.storage.messages.updateStatus(localMessageId: localId, status: .sent)
            case .failed:
                try? self.storage.messages.updateStatus(localMessageId: localId, status: .sendFailure)
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MessagingServiceTests`
Expected: all pass, including the 3 new ones.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests pass (229 + 3 = 232).

- [ ] **Step 6: Commit**

```bash
git add Sources/IMMessaging/MessagingService.swift Tests/IMMessagingTests/MessagingServiceTests.swift
git commit -m "feat(IMMessaging): add MessagingService.resend for failed-message retry"
```

---

## Task 4: IMKit scaffolding — `MessageSending`/`ImageUploading`/row models

**Files:**
- Modify: `Package.swift`
- Create: `Sources/IMKit/MessageSending.swift`
- Create: `Sources/IMKit/ImageUploading.swift`
- Create: `Sources/IMKit/ChatMessageRow.swift`

No dedicated tests in this task — these are narrow protocols/retroactive conformances/plain data types with no independent logic to test; they're exercised indirectly by Task 5's `ConversationViewModelTests` (same precedent as `ContactInfoFetching.swift`, which also has no dedicated test file).

- [ ] **Step 1: Add `IMMessaging`/`IMMedia` as `IMKit` dependencies**

In `Package.swift`, change:

```swift
        .target(name: "IMKit", dependencies: ["IMStorage", "IMContacts"]),
```

to:

```swift
        .target(name: "IMKit", dependencies: ["IMStorage", "IMContacts", "IMMessaging", "IMMedia"]),
```

- [ ] **Step 2: Create `MessageSending`**

```swift
// Sources/IMKit/MessageSending.swift
import Foundation
import IMStorage
import IMMessaging

/// Narrow interface `ConversationViewModel` depends on instead of the
/// concrete `MessagingService` — same decoupling-for-testability pattern as
/// `ContactInfoFetching`/`ContactSyncService` above.
public protocol MessageSending: AnyObject {
    func sendText(to target: String, conversationType: ConversationType, line: Int, text: String) throws
    func sendImage(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String) throws
    func resend(localMessageId: Int64) throws
}

extension MessagingService: MessageSending {}
```

- [ ] **Step 3: Create `ImageUploading`**

```swift
// Sources/IMKit/ImageUploading.swift
import Foundation
import IMMedia

/// Narrow interface `ConversationViewModel` depends on instead of the
/// concrete `MediaUploadService` — same decoupling-for-testability pattern
/// as `ContactInfoFetching`/`ContactSyncService`.
public protocol ImageUploading: AnyObject {
    func uploadImage(_ data: Data, completion: @escaping (Result<String, MediaUploadError>) -> Void)
}

extension MediaUploadService: ImageUploading {}
```

- [ ] **Step 4: Create the row models**

```swift
// Sources/IMKit/ChatMessageRow.swift
import Foundation
import IMStorage

/// A message still uploading (or that failed to upload) its image data —
/// deliberately never written to `IMStorage`: until the upload succeeds
/// there's no `remoteURL` yet, and persisting a row without one would be an
/// ambiguous half-sent state. Lives only in `ConversationViewModel`'s
/// in-memory state until upload succeeds, at which point
/// `MessageSending.sendImage(...)` inserts the real, persisted row and this
/// one is removed.
public struct PendingImageUpload: Equatable, Hashable {
    public enum State: Equatable, Hashable {
        case uploading
        case failed
    }

    public let id: UUID
    public let thumbnail: Data
    public let fullImageData: Data
    public var state: State

    public init(id: UUID, thumbnail: Data, fullImageData: Data, state: State) {
        self.id = id
        self.thumbnail = thumbnail
        self.fullImageData = fullImageData
        self.state = state
    }
}

/// Flattened, `Hashable` presentation of a `StoredMessage` — same
/// flattening rationale as `ConversationRow`: diffable data sources need
/// stable `Hashable` item identifiers, and `StoredMessage`/`MessageContent`
/// aren't `Hashable` themselves.
public struct StoredMessageRow: Equatable, Hashable {
    public let storageId: Int64
    public let localMessageId: Int64
    public let isOutgoing: Bool
    public let status: MessageStatus
    public let timestamp: Int64
    public let text: String?
    public let imageThumbnail: Data?
    public let imageRemoteURL: String?

    public init(storageId: Int64, localMessageId: Int64, isOutgoing: Bool, status: MessageStatus, timestamp: Int64, text: String?, imageThumbnail: Data?, imageRemoteURL: String?) {
        self.storageId = storageId
        self.localMessageId = localMessageId
        self.isOutgoing = isOutgoing
        self.status = status
        self.timestamp = timestamp
        self.text = text
        self.imageThumbnail = imageThumbnail
        self.imageRemoteURL = imageRemoteURL
    }
}

/// A single row in the chat message list — either a real, persisted
/// message or an in-flight image upload placeholder (see
/// `PendingImageUpload`).
public enum ChatMessageRow: Equatable, Hashable {
    case message(StoredMessageRow)
    case pendingImage(PendingImageUpload)
}
```

- [ ] **Step 5: Confirm it builds**

Run: `swift build`
Expected: builds successfully (no tests reference these types yet, just confirming compilation).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/IMKit/MessageSending.swift Sources/IMKit/ImageUploading.swift Sources/IMKit/ChatMessageRow.swift
git commit -m "feat(IMKit): scaffold MessageSending/ImageUploading protocols and chat row models"
```

---

## Task 5: `ConversationViewModel`

**Files:**
- Create: `Sources/IMKit/ConversationViewModel.swift`
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMKitTests/ConversationViewModelTests.swift
import XCTest
import Combine
import IMStorage
import IMMedia
@testable import IMKit

private final class FakeMessageSending: MessageSending {
    private(set) var sentTexts: [(target: String, text: String)] = []
    private(set) var sentImages: [(target: String, thumbnail: Data?, remoteURL: String)] = []
    private(set) var resentLocalMessageIds: [Int64] = []

    func sendText(to target: String, conversationType: ConversationType, line: Int, text: String) throws {
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
    private(set) var uploadedData: [Data] = []

    func uploadImage(_ data: Data, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
        uploadedData.append(data)
        completion(nextResult)
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConversationViewModelTests`
Expected: FAIL with `cannot find type 'ConversationViewModel' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMKit/ConversationViewModel.swift
import Foundation
import Combine
import IMStorage

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ConversationViewModel {
    @Published public private(set) var rows: [ChatMessageRow] = []
    @Published public private(set) var canLoadMore: Bool = true

    private let storage: IMStorage
    private let messageSending: MessageSending?
    private let imageUploading: ImageUploading?
    private let target: String
    private let conversationType: ConversationType
    private let line: Int
    private let pageSize: Int

    private var storedRows: [StoredMessageRow] = []
    private var pendingImages: [PendingImageUpload] = []
    private var cancellable: AnyCancellable?

    public init(
        storage: IMStorage,
        messageSending: MessageSending?,
        imageUploading: ImageUploading?,
        target: String,
        conversationType: ConversationType = .single,
        line: Int = 0,
        pageSize: Int = 30
    ) {
        self.storage = storage
        self.messageSending = messageSending
        self.imageUploading = imageUploading
        self.target = target
        self.conversationType = conversationType
        self.line = line
        self.pageSize = pageSize

        cancellable = storage.messages
            .messagesPublisher(conversationType: conversationType, target: target, line: line, limit: pageSize)
            .replaceError(with: [])
            .sink { [weak self] messages in self?.handleMessagesUpdate(messages) }
    }

    /// Failure (e.g. serialization, or no `messageSending` configured) is
    /// silently dropped — accepted Phase-1 gap, no logging facility yet,
    /// same as `ContactSyncService`/`FriendSyncHandler` elsewhere.
    public func sendText(_ text: String) {
        try? messageSending?.sendText(to: target, conversationType: conversationType, line: line, text: text)
    }

    public func sendImage(fullImageData: Data, thumbnail: Data) {
        let pending = PendingImageUpload(id: UUID(), thumbnail: thumbnail, fullImageData: fullImageData, state: .uploading)
        pendingImages.append(pending)
        publishRows()
        startUpload(pending)
    }

    /// Retries a failed send: a `.pendingImage` row re-runs the upload from
    /// scratch; a `.message` row with `status == .sendFailure` re-sends the
    /// already-stored row via `MessageSending.resend(localMessageId:)`. A
    /// no-op for any other row/status combination.
    public func retry(row: ChatMessageRow) {
        switch row {
        case .pendingImage(let pending):
            guard let index = pendingImages.firstIndex(where: { $0.id == pending.id }) else { return }
            pendingImages[index].state = .uploading
            publishRows()
            startUpload(pendingImages[index])
        case .message(let message):
            guard message.status == .sendFailure else { return }
            try? messageSending?.resend(localMessageId: message.localMessageId)
        }
    }

    /// Loads one older page of history before the currently-oldest loaded
    /// message. A no-op if nothing is loaded yet or a previous call already
    /// determined there's no more history (`canLoadMore == false`).
    public func loadMore() {
        guard canLoadMore, let oldest = storedRows.first else { return }
        let older = (try? storage.messages.olderMessages(
            conversationType: conversationType, target: target, line: line,
            beforeTimestamp: oldest.timestamp, beforeId: oldest.storageId, limit: pageSize
        )) ?? []
        if older.count < pageSize { canLoadMore = false }
        guard !older.isEmpty else { return }
        storedRows.insert(contentsOf: older.map(Self.makeRow), at: 0)
        publishRows()
    }

    private func startUpload(_ pending: PendingImageUpload) {
        imageUploading?.uploadImage(pending.fullImageData) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let remoteURL):
                try? self.messageSending?.sendImage(to: self.target, conversationType: self.conversationType, line: self.line, thumbnail: pending.thumbnail, remoteURL: remoteURL)
                self.pendingImages.removeAll { $0.id == pending.id }
            case .failure:
                if let index = self.pendingImages.firstIndex(where: { $0.id == pending.id }) {
                    self.pendingImages[index].state = .failed
                }
            }
            self.publishRows()
        }
    }

    private func handleMessagesUpdate(_ messages: [StoredMessage]) {
        for message in messages {
            let row = Self.makeRow(message)
            if let index = storedRows.firstIndex(where: { $0.storageId == row.storageId }) {
                storedRows[index] = row
            } else {
                storedRows.append(row)
            }
        }
        storedRows.sort { $0.timestamp == $1.timestamp ? $0.storageId < $1.storageId : $0.timestamp < $1.timestamp }
        publishRows()
    }

    private func publishRows() {
        rows = storedRows.map { .message($0) } + pendingImages.map { .pendingImage($0) }
    }

    /// `message.id` is always non-nil for a row fetched back from the
    /// database (`FetchableRecord` only ever omits it before insertion) —
    /// the `-1` fallback is unreachable in practice, not a real sentinel.
    private static func makeRow(_ message: StoredMessage) -> StoredMessageRow {
        var text: String?
        var imageThumbnail: Data?
        var imageRemoteURL: String?
        switch message.content {
        case .text(let value):
            text = value
        case .image(let thumbnail, let remoteURL, _):
            imageThumbnail = thumbnail
            imageRemoteURL = remoteURL
        }
        return StoredMessageRow(
            storageId: message.id ?? -1,
            localMessageId: message.localMessageId,
            isOutgoing: message.direction == .send,
            status: message.status,
            timestamp: message.timestamp,
            text: text,
            imageThumbnail: imageThumbnail,
            imageRemoteURL: imageRemoteURL
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConversationViewModelTests`
Expected: all pass (11 tests).

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests pass (232 + 11 = 243).

- [ ] **Step 6: Commit**

```bash
git add Sources/IMKit/ConversationViewModel.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat(IMKit): add ConversationViewModel"
```

---

## Task 6: `TextMessageCell`

**Files:**
- Create: `App/TextMessageCell.swift`

No automated tests — `App/` has no test target; verified by build + later manual/simulator check (Task 12), same as every existing `App/*Cell.swift`.

- [ ] **Step 1: Create the cell**

```swift
// App/TextMessageCell.swift
import UIKit
import IMKit

final class TextMessageCell: UITableViewCell {
    static let reuseIdentifier = "TextMessageCell"

    private let bubbleView = UIView()
    private let textLabel = UILabel()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()

    var onRetryTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        bubbleView.layer.cornerRadius = Theme.bubbleCornerRadius
        textLabel.numberOfLines = 0
        textLabel.font = .systemFont(ofSize: 16)
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            textLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            textLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            textLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
        ])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel

        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(bubbleView)
        bubbleColumn.addArrangedSubview(statusLabel)

        retryButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        retryButton.tintColor = .systemRed
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bubbleColumn.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.7),
        ])
    }

    func configure(with row: StoredMessageRow) {
        textLabel.text = row.text

        let isOutgoing = row.isOutgoing
        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.incomingBubble
        textLabel.textColor = isOutgoing ? Theme.textOnAccent : Theme.textPrimary
        bubbleColumn.alignment = isOutgoing ? .trailing : .leading
        statusLabel.textAlignment = isOutgoing ? .right : .left

        switch row.status {
        case .sending: statusLabel.text = "发送中"
        case .sendFailure: statusLabel.text = "发送失败"
        default: statusLabel.text = nil
        }

        rowStack.arrangedSubviews.forEach { rowStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        retryButton.removeFromSuperview()

        if isOutgoing {
            rowStack.addArrangedSubview(spacer)
            if row.status == .sendFailure { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(bubbleColumn)
        } else {
            rowStack.addArrangedSubview(bubbleColumn)
            if row.status == .sendFailure { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(spacer)
        }
    }

    @objc private func retryTapped() { onRetryTapped?() }
}
```

- [ ] **Step 2: Regenerate the Xcode project and build**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`. `App/*.swift` uses an explicit file list in `project.pbxproj` — a new file here requires the regenerated pbxproj to be committed too.

- [ ] **Step 3: Commit**

```bash
git add App/TextMessageCell.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add TextMessageCell"
```

---

## Task 7: `ImageMessageCell`

**Files:**
- Create: `App/ImageMessageCell.swift`

- [ ] **Step 1: Create the cell**

```swift
// App/ImageMessageCell.swift
import UIKit

struct ImageBubbleData: Equatable {
    let thumbnail: Data?
    let isOutgoing: Bool
    let isUploading: Bool
    let isFailed: Bool
}

final class ImageMessageCell: UITableViewCell {
    static let reuseIdentifier = "ImageMessageCell"

    private let bubbleImageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()

    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        bubbleImageView.contentMode = .scaleAspectFill
        bubbleImageView.clipsToBounds = true
        bubbleImageView.layer.cornerRadius = Theme.bubbleCornerRadius
        bubbleImageView.backgroundColor = Theme.backgroundTertiary
        bubbleImageView.isUserInteractionEnabled = true
        bubbleImageView.translatesAutoresizingMaskIntoConstraints = false
        bubbleImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        bubbleImageView.addSubview(activityIndicator)

        retryButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        retryButton.tintColor = .systemRed
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        bubbleColumn.axis = .vertical
        bubbleColumn.addArrangedSubview(bubbleImageView)

        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            bubbleImageView.widthAnchor.constraint(equalToConstant: 160),
            bubbleImageView.heightAnchor.constraint(equalToConstant: 160),

            activityIndicator.centerXAnchor.constraint(equalTo: bubbleImageView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: bubbleImageView.centerYAnchor),
        ])
    }

    func configure(with data: ImageBubbleData) {
        bubbleImageView.image = data.thumbnail.flatMap { UIImage(data: $0) }
        activityIndicator.isHidden = !data.isUploading
        if data.isUploading { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        retryButton.isHidden = !data.isFailed

        rowStack.arrangedSubviews.forEach { rowStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        retryButton.removeFromSuperview()

        if data.isOutgoing {
            rowStack.addArrangedSubview(spacer)
            if data.isFailed { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(bubbleColumn)
        } else {
            rowStack.addArrangedSubview(bubbleColumn)
            if data.isFailed { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(spacer)
        }
    }

    @objc private func tapped() { onTapped?() }
    @objc private func retryTapped() { onRetryTapped?() }
}
```

- [ ] **Step 2: Regenerate the Xcode project and build**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/ImageMessageCell.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add ImageMessageCell"
```

---

## Task 8: `MessageInputBar`

**Files:**
- Create: `App/MessageInputBar.swift`

- [ ] **Step 1: Create the input bar**

```swift
// App/MessageInputBar.swift
import UIKit

final class MessageInputBar: UIView {
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let imageButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private var textViewHeightConstraint: NSLayoutConstraint!

    var onSendText: ((String) -> Void)?
    var onPickImage: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        imageButton.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        imageButton.tintColor = Theme.accent
        imageButton.addTarget(self, action: #selector(imageTapped), for: .touchUpInside)
        imageButton.translatesAutoresizingMaskIntoConstraints = false

        textView.font = .systemFont(ofSize: 16)
        textView.backgroundColor = Theme.backgroundTertiary
        textView.layer.cornerRadius = Theme.cardCornerRadius
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.text = "发消息..."
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        sendButton.setTitle("发送", for: .normal)
        sendButton.tintColor = Theme.accent
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageButton)
        addSubview(textView)
        textView.addSubview(placeholderLabel)
        addSubview(sendButton)

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)

        NSLayoutConstraint.activate([
            imageButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            imageButton.widthAnchor.constraint(equalToConstant: 28),
            imageButton.heightAnchor.constraint(equalToConstant: 28),

            textView.leadingAnchor.constraint(equalTo: imageButton.trailingAnchor, constant: 8),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            textViewHeightConstraint,

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 8),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.topAnchor, constant: 18),

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
        ])
    }

    @objc private func imageTapped() { onPickImage?() }

    @objc private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSendText?(text)
        textView.text = ""
        placeholderLabel.isHidden = false
        updateHeight()
    }

    private func updateHeight() {
        let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        textViewHeightConstraint.constant = min(max(size.height, 36), 120)
    }
}

extension MessageInputBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateHeight()
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project and build**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/MessageInputBar.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add MessageInputBar"
```

---

## Task 9: `ImagePreviewViewController`

**Files:**
- Create: `App/ImagePreviewViewController.swift`

- [ ] **Step 1: Create the preview screen**

```swift
// App/ImagePreviewViewController.swift
import UIKit
import IMKit

final class ImagePreviewViewController: UIViewController {
    private let loader: AvatarLoading
    private let localThumbnail: Data?
    private let remoteURL: String?
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(localThumbnail: Data?, remoteURL: String?, loader: AvatarLoading = AvatarLoader()) {
        self.localThumbnail = localThumbnail
        self.remoteURL = remoteURL
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutViews()
        if let localThumbnail, let image = UIImage(data: localThumbnail) {
            imageView.image = image
        }
        if let remoteURL {
            Task {
                guard let data = await loader.loadAvatarData(from: remoteURL), let image = UIImage(data: data) else { return }
                imageView.image = image
            }
        }
    }

    private func layoutViews() {
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            imageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func handleDoubleTap() {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            scrollView.setZoomScale(scrollView.maximumZoomScale, animated: true)
        }
    }
}

extension ImagePreviewViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}
```

- [ ] **Step 2: Regenerate the Xcode project and build**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/ImagePreviewViewController.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add ImagePreviewViewController"
```

---

## Task 10: `ConversationViewController` — replace the placeholder

**Files:**
- Modify: `App/ConversationViewController.swift`

- [ ] **Step 1: Replace the placeholder implementation**

Replace the entire content of `App/ConversationViewController.swift` with:

```swift
// App/ConversationViewController.swift
import UIKit
import PhotosUI
import Combine
import IMKit

final class ConversationViewController: UIViewController {
    private let row: ConversationRow
    private let viewModel: ConversationViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, ChatMessageRow>!

    private let tableView = UITableView()
    private let inputBar = MessageInputBar()
    private var inputBarBottomConstraint: NSLayoutConstraint!

    init(row: ConversationRow, viewModel: ConversationViewModel) {
        self.row = row
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = row.displayName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        configureDataSource()
        bindViewModel()
        bindInputBar()
        observeKeyboard()
    }

    private func layoutViews() {
        tableView.register(TextMessageCell.self, forCellReuseIdentifier: TextMessageCell.reuseIdentifier)
        tableView.register(ImageMessageCell.self, forCellReuseIdentifier: ImageMessageCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorStyle = .none
        tableView.translatesAutoresizingMaskIntoConstraints = false

        inputBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(inputBar)

        inputBarBottomConstraint = inputBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBarBottomConstraint,
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, ChatMessageRow>(tableView: tableView) { tableView, indexPath, row in
            switch row {
            case .message(let message) where message.text != nil:
                let cell = tableView.dequeueReusableCell(withIdentifier: TextMessageCell.reuseIdentifier, for: indexPath) as! TextMessageCell
                cell.configure(with: message)
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                return cell
            case .message(let message):
                let cell = tableView.dequeueReusableCell(withIdentifier: ImageMessageCell.reuseIdentifier, for: indexPath) as! ImageMessageCell
                cell.configure(with: ImageBubbleData(thumbnail: message.imageThumbnail, isOutgoing: message.isOutgoing, isUploading: message.status == .sending, isFailed: message.status == .sendFailure))
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onTapped = { [weak self] in self?.presentImagePreview(thumbnail: message.imageThumbnail, remoteURL: message.imageRemoteURL) }
                return cell
            case .pendingImage(let pending):
                let cell = tableView.dequeueReusableCell(withIdentifier: ImageMessageCell.reuseIdentifier, for: indexPath) as! ImageMessageCell
                cell.configure(with: ImageBubbleData(thumbnail: pending.thumbnail, isOutgoing: true, isUploading: pending.state == .uploading, isFailed: pending.state == .failed))
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onTapped = { [weak self] in self?.presentImagePreview(thumbnail: pending.thumbnail, remoteURL: nil) }
                return cell
            }
        }
    }

    private func bindViewModel() {
        viewModel.$rows
            .sink { [weak self] rows in self?.applySnapshot(rows: rows) }
            .store(in: &cancellables)
    }

    /// Distinguishes three update shapes so scroll position behaves
    /// sensibly: a prepend (loaded older history — keep the user's current
    /// reading position by offsetting `contentOffset` by the inserted
    /// height), an append (a new message arrived — scroll to the bottom),
    /// or an in-place update elsewhere (e.g. an ack status flip on a row
    /// that isn't the last one — leave scroll position untouched).
    private func applySnapshot(rows: [ChatMessageRow]) {
        let oldRows = dataSource.snapshot().itemIdentifiers
        let isPrepend = !oldRows.isEmpty && rows.count > oldRows.count && Array(rows.suffix(oldRows.count)) == oldRows
        let isAppend = rows.last != oldRows.last
        let previousContentHeight = tableView.contentSize.height

        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatMessageRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: !isPrepend) { [weak self] in
            guard let self else { return }
            if isPrepend {
                let delta = self.tableView.contentSize.height - previousContentHeight
                self.tableView.contentOffset.y += delta
            } else if isAppend {
                self.scrollToBottom(animated: !oldRows.isEmpty)
            }
        }
    }

    private func scrollToBottom(animated: Bool) {
        let rowCount = dataSource.snapshot().itemIdentifiers.count
        guard rowCount > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: rowCount - 1, section: 0), at: .bottom, animated: animated)
    }

    private func bindInputBar() {
        inputBar.onSendText = { [weak self] text in self?.viewModel.sendText(text) }
        inputBar.onPickImage = { [weak self] in self?.presentImagePicker() }
    }

    private func presentImagePicker() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func handlePickedImage(_ image: UIImage) {
        guard let thumbnail = Self.makeThumbnail(image)?.jpegData(compressionQuality: 0.7),
              let fullImageData = image.jpegData(compressionQuality: 0.9) else { return }
        viewModel.sendImage(fullImageData: fullImageData, thumbnail: thumbnail)
    }

    private static func makeThumbnail(_ image: UIImage, maxDimension: CGFloat = 480) -> UIImage? {
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1)
        guard scale < 1 else { return image }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private func presentImagePreview(thumbnail: Data?, remoteURL: String?) {
        present(ImagePreviewViewController(localThumbnail: thumbnail, remoteURL: remoteURL), animated: true)
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        let keyboardHeight = max(0, view.bounds.maxY - endFrame.minY - view.safeAreaInsets.bottom)
        inputBarBottomConstraint.constant = -keyboardHeight
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }
}

extension ConversationViewController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.contentOffset.y < 100 else { return }
        viewModel.loadMore()
    }
}

extension ConversationViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async { self?.handlePickedImage(image) }
        }
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project and build**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`. (This will currently fail to link/compile until Task 11 updates the only call site — `SceneDelegate.swift` — to pass a `viewModel:`; if so, proceed straight to Task 11 and build at the end of that task instead. Note this explicitly if it happens rather than treating it as a real regression.)

- [ ] **Step 3: Commit**

```bash
git add App/ConversationViewController.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): replace ConversationViewController placeholder with the real chat screen"
```

---

## Task 11: Wire `SceneDelegate` to construct the real `ConversationViewModel`

**Files:**
- Modify: `App/SceneDelegate.swift`

- [ ] **Step 1: Update the conversation-selected callback**

In `App/SceneDelegate.swift`, replace:

```swift
    private func makeConversationListNavigationController() -> UIViewController {
        let viewModel = ConversationListViewModel(storage: environment.storage, contactSync: environment.contactSyncService)
        let listViewController = ConversationListViewController(viewModel: viewModel)
        listViewController.onConversationSelected = { [weak listViewController] row in
            listViewController?.navigationController?.pushViewController(ConversationViewController(row: row), animated: true)
        }
        return UINavigationController(rootViewController: listViewController)
    }
```

with:

```swift
    private func makeConversationListNavigationController() -> UIViewController {
        let viewModel = ConversationListViewModel(storage: environment.storage, contactSync: environment.contactSyncService)
        let listViewController = ConversationListViewController(viewModel: viewModel)
        listViewController.onConversationSelected = { [weak self, weak listViewController] row in
            guard let self else { return }
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
                target: row.target,
                conversationType: row.conversationType,
                line: row.line
            )
            listViewController?.navigationController?.pushViewController(
                ConversationViewController(row: row, viewModel: conversationViewModel),
                animated: true
            )
        }
        return UINavigationController(rootViewController: listViewController)
    }
```

(No new `import` needed — `environment.messagingService`/`environment.mediaUploadService` are passed through opaquely into `ConversationViewModel`'s already-`IMKit`-imported parameter types, same as the existing `environment.contactSyncService` → `contactSync: ContactInfoFetching?` pass-through just above, which already works today without importing `IMContacts` here.)

- [ ] **Step 2: Regenerate the Xcode project and build**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`. This is the call site that needed Task 10's `ConversationViewController(row:viewModel:)` signature — the build should now succeed end-to-end.

- [ ] **Step 3: Commit**

```bash
git add App/SceneDelegate.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): wire ConversationViewModel into the conversation-selected navigation flow"
```

---

## Task 12: End-to-end build/test verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full `swift test` suite**

```bash
swift test
```

Expected: all tests pass (243 from Tasks 1–5, no new SPM tests added in Tasks 6–11 since those are `App/`-only UI files).

- [ ] **Step 2: Build the App target**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Simulator smoke test**

```bash
xcrun simctl boot "iPhone 15" 2>/dev/null || true
APP_PATH=$(find .build/xcode/Build/Products -name "App.app" -maxdepth 2 | head -1)
xcrun simctl install "iPhone 15" "$APP_PATH"
xcrun simctl launch "iPhone 15" com.fshare.ios-chat-pro.App
xcrun simctl io "iPhone 15" screenshot /tmp/plan-i-smoke-test.png
```

Manually tap into a conversation and confirm: the chat screen loads without crashing, the input bar renders, typing and tapping "发送" inserts a bubble, tapping the image button opens the system photo picker. This environment has repeatedly hit a `simctl install` hang in earlier plans (documented in Plans E/F/G/H's self-review notes) — if it hangs again here, fall back to `swift test` + `xcodebuild` as the strongest available verification rather than re-litigating the known environment quirk at length.

No commit for this task — it's a verification gate, not new code.

---

## Plan Self-Review Notes

- **Spec coverage:** every section of `docs/superpowers/specs/2026-06-19-plan-i-conversation-chat-ui-design.md` maps to a task — data layer (Tasks 1–2), send flow incl. retry (Tasks 3, 5), IMKit decoupling layer (Task 4), UI components (Tasks 6–9), assembly + wiring (Tasks 10–11), verification (Task 12). All three optional features the user selected (pagination, retry-on-failure, full-screen image preview) are implemented.
- **Pagination cursor refinement:** the spec's design doc described `olderMessages(before: StoredMessage, ...)`; this plan uses primitive `beforeTimestamp`/`beforeId` parameters instead — equivalent intent, simpler signature, avoids the `ConversationViewModel` needing to retain full `StoredMessage` objects just to page backward.
- **Threading consistency:** `MediaUploadService.uploadImage`'s completion (invoked from inside an unstructured `Task` for the HTTP-PUT path) is called directly without explicit main-thread dispatch in `ConversationViewModel.startUpload` — this matches the already-merged, already-reviewed precedent in `AvatarImageView.setAvatar`'s `Task { ... self.image = uiImage }`, not a new gap introduced by this plan. `PHPickerViewController`'s `loadObject` completion, by contrast, is an old completion-handler API with no actor-isolation guarantee, so `ConversationViewController.picker(_:didFinishPicking:)` explicitly dispatches back to the main queue — a deliberate, necessary difference, not an inconsistency.
- **No automated tests for Tasks 6–11:** consistent with this project's established convention — `App/` has no test target, and no existing `*ViewController`/`*Cell` has dedicated tests. Verified via compilation + Task 12's manual/simulator pass instead.
- **Swipe-to-dismiss trimmed from `ImagePreviewViewController`:** the design doc mentioned "下滑或点击关闭"; this plan implements only tap-to-close (button) plus double-tap-to-zoom, dropping the swipe gesture as unnecessary polish for Phase 1 — a tap target is sufficient and simpler to get right.
- **No placeholders:** every step has complete, runnable code; nothing is left as "TODO" or "similar to above."
