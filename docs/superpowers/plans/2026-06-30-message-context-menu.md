# Message Context Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add long-press context menu to chat messages with copy, forward, recall, delete, and save image/video actions.

**Architecture:** Five vertical slices from storage upward: (1) storage foundations, (2) wire-level recall protocol, (3) ViewModel methods, (4) context menu UI, (5) forward picker/preview UI. Each task is independently testable before the next begins.

**Tech Stack:** Swift, UIKit, GRDB, Combine, UIContextMenuConfiguration (iOS 13+), PHPhotoLibrary

## Global Constraints

- All code must be called from the main queue (no internal locking — existing codebase-wide contract)
- New files in `App/` are auto-discovered by project.yml (`sources: - App`); SPM modules auto-discover from `Sources/`
- Run `swift test --filter <ModuleTests>` after every task's test step
- `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build` must pass after every task
- Never use the system `protoc` binary (pinned to 2.5.0 — incompatible)
- No new singletons; dependency injection via init parameters or closures

---

### Task 1: Storage Foundations — StoredMessageRow new fields + MessageStore.deleteMessage

**Files:**
- Modify: `Sources/IMKit/ChatMessageRow.swift` — add `messageUid`, `voiceDuration`, `fileSize`, `fileName` to `StoredMessageRow`
- Modify: `Sources/IMKit/ConversationViewModel.swift` — update `buildStoredMessageRow` + `.voice`/`.file` cases in `makeRow`
- Modify: `Sources/IMStorage/MessageStore.swift` — add `deleteMessage(id:)` and `deleteMessage(id:db:)`
- Test: `Tests/IMStorageTests/MessageStoreTests.swift`
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift`

**Interfaces:**
- Produces: `StoredMessageRow.messageUid: Int64`, `.voiceDuration: Int?`, `.fileSize: Int?`, `.fileName: String?`
- Produces: `MessageStore.deleteMessage(id: Int64) throws`, `MessageStore.deleteMessage(id: Int64, db: Database) throws`
- Later tasks rely on `row.messageUid` (Task 2 recall), `row.voiceDuration`/`row.fileSize`/`row.fileName` (Task 3 forward)

- [ ] **Step 1: Write failing tests for MessageStore.deleteMessage**

Add to `Tests/IMStorageTests/MessageStoreTests.swift`:

```swift
func test_deleteMessage_removesRowFromStorage() throws {
    let inserted = try store.insert(makeMessage(localMessageId: 10))
    let id = try XCTUnwrap(inserted.id)

    try store.deleteMessage(id: id)

    XCTAssertNil(try store.message(localMessageId: 10))
}

func test_deleteMessage_doesNotAffectOtherMessages() throws {
    let a = try store.insert(makeMessage(localMessageId: 11, text: "keep"))
    let b = try store.insert(makeMessage(localMessageId: 12, text: "delete me"))
    let bId = try XCTUnwrap(b.id)

    try store.deleteMessage(id: bId)

    XCTAssertNotNil(try store.message(localMessageId: 11))
    XCTAssertNil(try store.message(localMessageId: 12))
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter IMStorageTests/MessageStoreTests/test_deleteMessage
```

Expected: FAIL — `value of type 'MessageStore' has no member 'deleteMessage'`

- [ ] **Step 3: Add deleteMessage to MessageStore**

In `Sources/IMStorage/MessageStore.swift`, after `updateContent(id:content:db:)`:

```swift
public func deleteMessage(id: Int64) throws {
    try dbQueue.write { db in try self.deleteMessage(id: id, db: db) }
}

public func deleteMessage(id: Int64, db: Database) throws {
    try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id])
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter IMStorageTests/MessageStoreTests/test_deleteMessage
```

Expected: PASS

- [ ] **Step 5: Write failing tests for StoredMessageRow new fields**

Add to `Tests/IMKitTests/ConversationViewModelTests.swift` (inside `ConversationViewModelTests`):

```swift
func test_voiceMessage_rowHasVoiceDuration() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 50, conversationType: .single, target: "them", from: "them",
        content: .voice(remoteURL: "https://cdn/v.amr", localPath: nil, duration: 12),
        timestamp: 1_000, status: .unread, direction: .receive
    ))
    waitForFirstNonEmptyRows()

    guard case .message(let row) = viewModel.rows.first else { return XCTFail("expected message row") }
    XCTAssertEqual(row.voiceDuration, 12)
    XCTAssertEqual(row.imageRemoteURL, "https://cdn/v.amr")
}

func test_fileMessage_rowHasFileNameAndSize() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 51, conversationType: .single, target: "them", from: "them",
        content: .file(name: "report.pdf", size: 204800, remoteURL: "https://cdn/r.pdf", localPath: nil),
        timestamp: 1_000, status: .unread, direction: .receive
    ))
    waitForFirstNonEmptyRows()

    guard case .message(let row) = viewModel.rows.first else { return XCTFail("expected message row") }
    XCTAssertEqual(row.fileName, "report.pdf")
    XCTAssertEqual(row.fileSize, 204800)
    XCTAssertEqual(row.imageRemoteURL, "https://cdn/r.pdf")
}

func test_sentMessage_rowHasMessageUid() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 52, messageUid: 9999,
        conversationType: .single, target: "them", from: "me",
        content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send
    ))
    waitForFirstNonEmptyRows()

    guard case .message(let row) = viewModel.rows.first else { return XCTFail("expected message row") }
    XCTAssertEqual(row.messageUid, 9999)
}
```

- [ ] **Step 6: Run tests to verify they fail**

```bash
swift test --filter IMKitTests/ConversationViewModelTests/test_voiceMessage_rowHasVoiceDuration
swift test --filter IMKitTests/ConversationViewModelTests/test_fileMessage_rowHasFileNameAndSize
swift test --filter IMKitTests/ConversationViewModelTests/test_sentMessage_rowHasMessageUid
```

Expected: FAIL — `StoredMessageRow` has no member `voiceDuration` / `fileName` / `messageUid`

- [ ] **Step 7: Update StoredMessageRow**

In `Sources/IMKit/ChatMessageRow.swift`, update `StoredMessageRow`:

```swift
public struct StoredMessageRow: Equatable, Hashable {
    public let storageId: Int64
    public let localMessageId: Int64
    public let messageUid: Int64          // server-assigned uid; 0 until acked
    public let isOutgoing: Bool
    public let status: MessageStatus
    public let timestamp: Int64
    public let text: String?
    public let imageThumbnail: Data?
    public let imageRemoteURL: String?    // also holds voice/file remote URLs
    public let senderDisplayName: String?
    public let senderAvatarURL: String?
    public let videoDuration: Int?
    public let voiceDuration: Int?        // non-nil for voice messages
    public let fileSize: Int?             // non-nil for file messages
    public let fileName: String?          // non-nil for file messages
    public let locationLat: Double?
    public let locationLng: Double?

    public init(
        storageId: Int64,
        localMessageId: Int64,
        messageUid: Int64 = 0,
        isOutgoing: Bool,
        status: MessageStatus,
        timestamp: Int64,
        text: String?,
        imageThumbnail: Data?,
        imageRemoteURL: String?,
        senderDisplayName: String? = nil,
        senderAvatarURL: String? = nil,
        videoDuration: Int? = nil,
        voiceDuration: Int? = nil,
        fileSize: Int? = nil,
        fileName: String? = nil,
        locationLat: Double? = nil,
        locationLng: Double? = nil
    ) {
        self.storageId = storageId
        self.localMessageId = localMessageId
        self.messageUid = messageUid
        self.isOutgoing = isOutgoing
        self.status = status
        self.timestamp = timestamp
        self.text = text
        self.imageThumbnail = imageThumbnail
        self.imageRemoteURL = imageRemoteURL
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.videoDuration = videoDuration
        self.voiceDuration = voiceDuration
        self.fileSize = fileSize
        self.fileName = fileName
        self.locationLat = locationLat
        self.locationLng = locationLng
    }
}
```

- [ ] **Step 8: Update ConversationViewModel.buildStoredMessageRow**

In `Sources/IMKit/ConversationViewModel.swift`, change the signature and body of `buildStoredMessageRow`:

```swift
private func buildStoredMessageRow(
    _ message: StoredMessage,
    text: String?,
    imageThumbnail: Data?,
    imageRemoteURL: String?,
    videoDuration: Int? = nil,
    voiceDuration: Int? = nil,
    fileSize: Int? = nil,
    fileName: String? = nil,
    locationLat: Double? = nil,
    locationLng: Double? = nil
) -> StoredMessageRow {
    var senderDisplayName: String?
    let avatarUid = message.direction == .send ? currentUserId : message.from
    let user = try? storage.users.user(uid: avatarUid)
    let senderAvatarURL = user?.portrait
    if conversationType == .group, message.direction == .receive {
        let key = "showMemberNicknames_\(target)"
        let showNicknames = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        if showNicknames {
            senderDisplayName = user?.displayName ?? user?.name ?? message.from
        }
    }
    return StoredMessageRow(
        storageId: message.id ?? -1,
        localMessageId: message.localMessageId,
        messageUid: message.messageUid,
        isOutgoing: message.direction == .send,
        status: message.status,
        timestamp: message.timestamp,
        text: text,
        imageThumbnail: imageThumbnail,
        imageRemoteURL: imageRemoteURL,
        senderDisplayName: senderDisplayName,
        senderAvatarURL: senderAvatarURL,
        videoDuration: videoDuration,
        voiceDuration: voiceDuration,
        fileSize: fileSize,
        fileName: fileName,
        locationLat: locationLat,
        locationLng: locationLng
    )
}
```

Update the `.voice` and `.file` cases in `makeRow`:

```swift
case .voice(let remoteURL, _, let duration):
    return .message(buildStoredMessageRow(message, text: "[语音] \(duration)秒",
        imageThumbnail: nil, imageRemoteURL: remoteURL, voiceDuration: duration))

case .file(let name, let size, let remoteURL, _):
    let sizeStr = size > 1024*1024 ? String(format: "%.1fMB", Double(size)/1024/1024) : "\(size/1024)KB"
    return .message(buildStoredMessageRow(message, text: "[文件] \(name) \(sizeStr)",
        imageThumbnail: nil, imageRemoteURL: remoteURL, fileSize: size, fileName: name))
```

- [ ] **Step 9: Run all new tests**

```bash
swift test --filter IMStorageTests/MessageStoreTests/test_deleteMessage
swift test --filter IMKitTests/ConversationViewModelTests/test_voiceMessage_rowHasVoiceDuration
swift test --filter IMKitTests/ConversationViewModelTests/test_fileMessage_rowHasFileNameAndSize
swift test --filter IMKitTests/ConversationViewModelTests/test_sentMessage_rowHasMessageUid
```

Expected: all PASS

- [ ] **Step 10: Run full test suite**

```bash
swift test
```

Expected: all PASS (no regressions from changed `StoredMessageRow` init — callers use label-based init so existing callers need only add the missing new params with their defaults, but since all new fields have default values of `nil` the existing call sites in `buildStoredMessageRow` callers compile without changes)

- [ ] **Step 11: Commit**

```bash
git add Sources/IMKit/ChatMessageRow.swift Sources/IMKit/ConversationViewModel.swift Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/MessageStoreTests.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat(storage): add deleteMessage + voiceDuration/fileSize/fileName/messageUid to StoredMessageRow"
```

---

### Task 2: Wire Recall Protocol — RecallAckHandler + MessagingService.recall

**Files:**
- Create: `Sources/IMMessaging/RecallAckHandler.swift`
- Modify: `Sources/IMKit/MessageSending.swift` — add `recall(...)` to protocol
- Modify: `Sources/IMMessaging/MessagingService.swift` — `pendingRecalls` dict + `recall` method + register handler
- Modify: `Tests/IMKitTests/ConversationViewModelTests.swift` — update `FakeMessageSending`
- Create: `Tests/IMMessagingTests/RecallAckHandlerTests.swift`
- Modify: `Tests/IMMessagingTests/MessagingServiceTests.swift`

**Interfaces:**
- Consumes: `Im_INT64Buf` (already in `Sources/IMProto/Generated/WFCMessage.pb.swift`), `SubSignal.mr`/`.pubAck`
- Produces: `MessageSending.recall(messageUid:storageId:conversationType:target:line:completion:)`
- Produces: `MessagingService` conforms to updated `MessageSending`

- [ ] **Step 1: Write failing test for RecallAckHandler**

Create `Tests/IMMessagingTests/RecallAckHandlerTests.swift`:

```swift
import XCTest
import IMClient
import IMTransport
@testable import IMMessaging

final class RecallAckHandlerTests: XCTestCase {
    private var handler: RecallAckHandler!

    override func setUp() {
        super.setUp()
        handler = RecallAckHandler()
    }

    func test_canHandle_onlyMatchesPubAckAndMR() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .mr))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .ms))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mr))
    }

    func test_handle_successBody_firesOnAckWithTrue() {
        var captured: (UInt16, Bool)?
        handler.onAck = { id, success in captured = (id, success) }

        let frame = Frame(
            header: Header(signal: .pubAck, subSignal: .mr, bodyLength: 1, messageId: 7),
            body: Data([0x00])
        )
        handler.handle(frame: frame)

        XCTAssertEqual(captured?.0, 7)
        XCTAssertEqual(captured?.1, true)
    }

    func test_handle_failureBody_firesOnAckWithFalse() {
        var captured: (UInt16, Bool)?
        handler.onAck = { id, success in captured = (id, success) }

        let frame = Frame(
            header: Header(signal: .pubAck, subSignal: .mr, bodyLength: 1, messageId: 7),
            body: Data([0x05])
        )
        handler.handle(frame: frame)

        XCTAssertEqual(captured?.0, 7)
        XCTAssertEqual(captured?.1, false)
    }

    func test_handle_emptyBody_doesNotCrash() {
        let frame = Frame(
            header: Header(signal: .pubAck, subSignal: .mr, bodyLength: 0, messageId: 1),
            body: Data()
        )
        handler.handle(frame: frame) // must not crash
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter IMMessagingTests/RecallAckHandlerTests
```

Expected: FAIL — `cannot find type 'RecallAckHandler'`

- [ ] **Step 3: Create RecallAckHandler**

Create `Sources/IMMessaging/RecallAckHandler.swift`:

```swift
import IMClient
import IMTransport

/// Handles `PUB_ACK`/`MR` (subSignal 30) — the server's one-byte confirmation
/// that a recall request succeeded (errorCode == 0) or failed (errorCode != 0).
/// Mirrors `MessageSendAckHandler` but for recall: no messageUid/timestamp
/// in the response body, just a single error byte.
public final class RecallAckHandler: MessageHandler {
    /// Fired when an ack arrives. Arguments: wireMessageId, success (errorCode==0).
    var onAck: ((UInt16, Bool) -> Void)?

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .mr
    }

    public func handle(frame: Frame) {
        guard !frame.body.isEmpty else { return }
        let errorCode = frame.body[0]
        onAck?(frame.header.messageId, errorCode == 0)
    }
}
```

- [ ] **Step 4: Run RecallAckHandler tests**

```bash
swift test --filter IMMessagingTests/RecallAckHandlerTests
```

Expected: all PASS

- [ ] **Step 5: Write failing tests for MessagingService.recall**

Add to `Tests/IMMessagingTests/MessagingServiceTests.swift`:

```swift
func test_recall_sendsPublishMRWithMessageUid() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 99, messageUid: 500,
        conversationType: .single, target: "them", from: "me",
        content: .text("hello"), timestamp: 1_000, status: .sent, direction: .send
    ))
    try storage.conversations.recordIncomingMessage(
        conversationType: .single, target: "them", line: 0,
        messageUid: 500, timestamp: 1_000, incrementUnread: false
    )
    let inserted = try XCTUnwrap(storage.messages.message(localMessageId: 99))

    service.recall(messageUid: 500, storageId: inserted.id!, conversationType: .single, target: "them", line: 0) { _ in }

    let frame = try decodeOnlySentFrame()
    XCTAssertEqual(frame.header.signal, .publish)
    XCTAssertEqual(frame.header.subSignal, .mr)
    let buf = try Im_INT64Buf(serializedBytes: frame.body)
    XCTAssertEqual(buf.id, 500)
}

func test_recall_ackSuccess_updatesLocalMessageToRecalled() throws {
    try storage.conversations.recordIncomingMessage(
        conversationType: .single, target: "them", line: 0,
        messageUid: 0, timestamp: 1_000, incrementUnread: false
    )
    let inserted = try storage.messages.insert(StoredMessage(
        localMessageId: 100, messageUid: 501,
        conversationType: .single, target: "them", from: "me",
        content: .text("bye"), timestamp: 1_000, status: .sent, direction: .send
    ))

    var capturedSuccess: Bool?
    service.recall(messageUid: 501, storageId: inserted.id!, conversationType: .single, target: "them", line: 0) { capturedSuccess = $0 }

    let sentFrame = try decodeOnlySentFrame()
    let ackBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mr, messageId: sentFrame.header.messageId, body: Data([0x00]))
    fakeTransport.simulateReceivedData(ackBytes)

    XCTAssertEqual(capturedSuccess, true)
    let updated = try storage.messages.message(localMessageId: 100)
    XCTAssertEqual(updated?.content, .recalled(operatorId: "me"))
}

func test_recall_ackFailure_doesNotUpdateMessageAndCallsCompletionFalse() throws {
    let inserted = try storage.messages.insert(StoredMessage(
        localMessageId: 101, messageUid: 502,
        conversationType: .single, target: "them", from: "me",
        content: .text("keep me"), timestamp: 1_000, status: .sent, direction: .send
    ))

    var capturedSuccess: Bool?
    service.recall(messageUid: 502, storageId: inserted.id!, conversationType: .single, target: "them", line: 0) { capturedSuccess = $0 }

    let sentFrame = try decodeOnlySentFrame()
    let ackBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mr, messageId: sentFrame.header.messageId, body: Data([0x06]))
    fakeTransport.simulateReceivedData(ackBytes)

    XCTAssertEqual(capturedSuccess, false)
    let unchanged = try storage.messages.message(localMessageId: 101)
    XCTAssertEqual(unchanged?.content, .text("keep me"))
}
```

- [ ] **Step 6: Run tests to verify they fail**

```bash
swift test --filter IMMessagingTests/MessagingServiceTests/test_recall
```

Expected: FAIL — `value of type 'MessagingService' has no member 'recall'`

- [ ] **Step 7: Add recall to MessageSending protocol**

In `Sources/IMKit/MessageSending.swift`, add to the protocol:

```swift
func recall(
    messageUid: Int64,
    storageId: Int64,
    conversationType: ConversationType,
    target: String,
    line: Int,
    completion: @escaping (Bool) -> Void
)
```

- [ ] **Step 8: Implement recall in MessagingService**

In `Sources/IMMessaging/MessagingService.swift`:

Add stored property after `recallNotifyHandler`:
```swift
private let recallAckHandler: RecallAckHandler
private var pendingRecalls: [UInt16: (Bool) -> Void] = [:]
```

In `init`, after `imClient.register(recallHandler)`:
```swift
let recallAckHandlerInstance = RecallAckHandler()
recallAckHandler = recallAckHandlerInstance
recallAckHandlerInstance.onAck = { [weak self] wireId, success in
    self?.pendingRecalls.removeValue(forKey: wireId)?(success)
}
imClient.register(recallAckHandlerInstance)
```

Add the `recall` method (after `resend`):
```swift
public func recall(
    messageUid: Int64,
    storageId: Int64,
    conversationType: ConversationType,
    target: String,
    line: Int,
    completion: @escaping (Bool) -> Void
) {
    var buf = Im_INT64Buf()
    buf.id = messageUid
    guard let body = try? buf.serializedData() else { completion(false); return }
    let wireId = imClient.sendFrame(signal: .publish, subSignal: .mr, body: body)
    pendingRecalls[wireId] = { [weak self] success in
        guard let self, success else { completion(false); return }
        try? self.storage.write { db in
            try self.storage.messages.updateContent(id: storageId, content: .recalled(operatorId: self.imClient.userId), db: db)
            try self.storage.conversations.touchConversation(conversationType: conversationType, target: target, line: line, db: db)
        }
        completion(true)
    }
}
```

- [ ] **Step 9: Update FakeMessageSending in ConversationViewModelTests**

In `Tests/IMKitTests/ConversationViewModelTests.swift`, inside `FakeMessageSending`:

```swift
private(set) var recallCalls: [(messageUid: Int64, storageId: Int64)] = []
var nextRecallSuccess = true

func recall(messageUid: Int64, storageId: Int64, conversationType: ConversationType, target: String, line: Int, completion: @escaping (Bool) -> Void) {
    recallCalls.append((messageUid, storageId))
    completion(nextRecallSuccess)
}
```

- [ ] **Step 10: Run all recall-related tests**

```bash
swift test --filter IMMessagingTests/RecallAckHandlerTests
swift test --filter IMMessagingTests/MessagingServiceTests/test_recall
```

Expected: all PASS

- [ ] **Step 11: Run full test suite**

```bash
swift test
```

Expected: all PASS

- [ ] **Step 12: Commit**

```bash
git add Sources/IMMessaging/RecallAckHandler.swift Sources/IMKit/MessageSending.swift Sources/IMMessaging/MessagingService.swift Tests/IMMessagingTests/RecallAckHandlerTests.swift Tests/IMMessagingTests/MessagingServiceTests.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat(messaging): add recall wire protocol (PUBLISH/MR + PUB_ACK/MR)"
```

---

### Task 3: ViewModel Layer — canRecall, recallMessage, deleteMessage, forward

**Files:**
- Modify: `Sources/IMKit/ConversationViewModel.swift`
- Modify: `Tests/IMKitTests/ConversationViewModelTests.swift`

**Interfaces:**
- Consumes: `MessageSending.recall(...)`, `MessageStore.deleteMessage(id:db:)`, `GroupStore.members(groupId:)`, `ConversationStore.touchConversation(...)`
- Produces: `ConversationViewModel.canRecall(row:) -> Bool`, `ConversationViewModel.recallMessage(row:completion:)`, `ConversationViewModel.deleteMessage(row:)`, `ConversationViewModel.forward(row:to:note:)`

- [ ] **Step 1: Write failing tests**

Add to `Tests/IMKitTests/ConversationViewModelTests.swift`:

```swift
// MARK: - canRecall

func test_canRecall_outgoingAckedMessage_returnsTrue() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 200, messageUid: 1001,
        conversationType: .single, target: "them", from: "me",
        content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send
    ))
    waitForFirstNonEmptyRows()
    guard case .message(let row) = viewModel.rows.first else { return XCTFail() }
    XCTAssertTrue(viewModel.canRecall(row: row))
}

func test_canRecall_outgoingUnackedMessage_returnsFalse() throws {
    // messageUid == 0 means not yet acked
    try storage.messages.insert(StoredMessage(
        localMessageId: 201, messageUid: 0,
        conversationType: .single, target: "them", from: "me",
        content: .text("pending"), timestamp: 1_000, status: .sending, direction: .send
    ))
    waitForFirstNonEmptyRows()
    guard case .message(let row) = viewModel.rows.first else { return XCTFail() }
    XCTAssertFalse(viewModel.canRecall(row: row))
}

func test_canRecall_incomingSingleChatMessage_returnsFalse() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 202, messageUid: 1002,
        conversationType: .single, target: "them", from: "them",
        content: .text("their msg"), timestamp: 1_000, status: .unread, direction: .receive
    ))
    waitForFirstNonEmptyRows()
    guard case .message(let row) = viewModel.rows.first else { return XCTFail() }
    XCTAssertFalse(viewModel.canRecall(row: row))
}

// MARK: - deleteMessage

func test_deleteMessage_removesRowFromStorageAndPublisher() throws {
    let inserted = try storage.messages.insert(StoredMessage(
        localMessageId: 300, conversationType: .single, target: "them", from: "them",
        content: .text("delete me"), timestamp: 1_000, status: .unread, direction: .receive
    ))
    waitForFirstNonEmptyRows()
    guard case .message(let row) = viewModel.rows.first else { return XCTFail() }

    let disappearExpectation = expectation(description: "rows becomes empty")
    disappearExpectation.assertForOverFulfill = false
    viewModel.$rows.dropFirst().sink { rows in
        if rows.isEmpty { disappearExpectation.fulfill() }
    }.store(in: &cancellables)

    viewModel.deleteMessage(row: row)
    wait(for: [disappearExpectation], timeout: 2)

    XCTAssertNil(try storage.messages.message(localMessageId: 300))
}

// MARK: - recallMessage

func test_recallMessage_callsSendingRecallWithCorrectUid() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 400, messageUid: 2000,
        conversationType: .single, target: "them", from: "me",
        content: .text("recall me"), timestamp: 1_000, status: .sent, direction: .send
    ))
    waitForFirstNonEmptyRows()
    guard case .message(let row) = viewModel.rows.first else { return XCTFail() }

    var completionFired = false
    viewModel.recallMessage(row: row) { _ in completionFired = true }

    XCTAssertEqual(sending.recallCalls.last?.messageUid, 2000)
    XCTAssertTrue(completionFired)
}

// MARK: - forward

func test_forward_textMessage_callsSendTextOnTarget() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 500, messageUid: 3000,
        conversationType: .single, target: "them", from: "me",
        content: .text("forward this"), timestamp: 1_000, status: .sent, direction: .send
    ))
    waitForFirstNonEmptyRows()
    guard case .message(let row) = viewModel.rows.first else { return XCTFail() }

    let targetConv = ConversationRow(
        conversationType: .single, target: "other", line: 0,
        displayName: "Other", avatarURL: nil, previewText: "",
        timestamp: 0, unreadCount: 0, hasUnreadMention: false,
        isTop: false, isMuted: false, lastMessageStatus: nil
    )
    viewModel.forward(row: row, to: targetConv, note: nil)

    XCTAssertEqual(sending.sentTexts.last?.target, "other")
    XCTAssertEqual(sending.sentTexts.last?.text, "forward this")
}

func test_forward_withNote_sendsTwoMessages() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 501, messageUid: 3001,
        conversationType: .single, target: "them", from: "me",
        content: .text("msg"), timestamp: 1_000, status: .sent, direction: .send
    ))
    waitForFirstNonEmptyRows()
    guard case .message(let row) = viewModel.rows.first else { return XCTFail() }

    let targetConv = ConversationRow(
        conversationType: .single, target: "other", line: 0,
        displayName: "Other", avatarURL: nil, previewText: "",
        timestamp: 0, unreadCount: 0, hasUnreadMention: false,
        isTop: false, isMuted: false, lastMessageStatus: nil
    )
    viewModel.forward(row: row, to: targetConv, note: "check this out")

    XCTAssertEqual(sending.sentTexts.count, 2)
    XCTAssertEqual(sending.sentTexts[0].text, "msg")
    XCTAssertEqual(sending.sentTexts[1].text, "check this out")
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter IMKitTests/ConversationViewModelTests/test_canRecall
swift test --filter IMKitTests/ConversationViewModelTests/test_deleteMessage
swift test --filter IMKitTests/ConversationViewModelTests/test_recallMessage
swift test --filter IMKitTests/ConversationViewModelTests/test_forward
```

Expected: FAIL — methods don't exist yet

- [ ] **Step 3: Implement the four methods in ConversationViewModel**

Add to `Sources/IMKit/ConversationViewModel.swift`:

```swift
/// Returns true if the current user may recall this message.
/// Rule: outgoing acked messages always; incoming group messages when current
/// user is .manager or .owner of the group.
public func canRecall(row: StoredMessageRow) -> Bool {
    guard row.messageUid != 0 else { return false }
    if row.isOutgoing { return true }
    guard conversationType == .group else { return false }
    let members = (try? storage.groups.members(groupId: target)) ?? []
    let myMember = members.first { $0.memberId == currentUserId }
    return myMember?.memberType == .manager || myMember?.memberType == .owner
}

/// Sends a recall request to the server. On success the message content is
/// updated to `.recalled` in storage. Calls `completion(false)` immediately
/// when `messageSending` is nil.
public func recallMessage(row: StoredMessageRow, completion: @escaping (Bool) -> Void) {
    guard let sending = messageSending else { completion(false); return }
    sending.recall(
        messageUid: row.messageUid,
        storageId: row.storageId,
        conversationType: conversationType,
        target: target,
        line: line,
        completion: completion
    )
}

/// Deletes a single message from local storage only. No server request.
public func deleteMessage(row: StoredMessageRow) {
    try? storage.write { db in
        try storage.messages.deleteMessage(id: row.storageId, db: db)
        try storage.conversations.touchConversation(
            conversationType: conversationType, target: target, line: line, db: db
        )
    }
}

/// Forwards a message to a different conversation, then sends an optional
/// note as a separate text message. Determines message type by inspecting
/// the row's fields in priority order: file → voice → video → location →
/// image → text/call-record.
public func forward(row: StoredMessageRow, to targetConv: ConversationRow, note: String?) {
    let t = targetConv.target
    let ct = targetConv.conversationType
    let l = targetConv.line

    if let name = row.fileName, let size = row.fileSize, let url = row.imageRemoteURL {
        try? messageSending?.sendFile(to: t, conversationType: ct, line: l, name: name, size: size, remoteURL: url)
    } else if let duration = row.voiceDuration, let url = row.imageRemoteURL {
        try? messageSending?.sendVoice(to: t, conversationType: ct, line: l, remoteURL: url, duration: duration)
    } else if let duration = row.videoDuration, let url = row.imageRemoteURL {
        try? messageSending?.sendVideo(to: t, conversationType: ct, line: l, thumbnail: row.imageThumbnail, remoteURL: url, duration: duration)
    } else if let lat = row.locationLat, let lng = row.locationLng {
        try? messageSending?.sendLocation(to: t, conversationType: ct, line: l, lat: lat, lng: lng, title: row.text ?? "", thumbnail: row.imageThumbnail)
    } else if let url = row.imageRemoteURL {
        try? messageSending?.sendImage(to: t, conversationType: ct, line: l, thumbnail: row.imageThumbnail, remoteURL: url)
    } else if let text = row.text {
        try? messageSending?.sendText(to: t, conversationType: ct, line: l, text: text, mentionedType: 0, mentionedTargets: [])
    }

    if let note, !note.isEmpty {
        try? messageSending?.sendText(to: t, conversationType: ct, line: l, text: note, mentionedType: 0, mentionedTargets: [])
    }
}
```

- [ ] **Step 4: Run all ViewModel tests**

```bash
swift test --filter IMKitTests/ConversationViewModelTests
```

Expected: all PASS

- [ ] **Step 5: Run full suite**

```bash
swift test
```

Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMKit/ConversationViewModel.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat(IMKit): add canRecall/recallMessage/deleteMessage/forward to ConversationViewModel"
```

---

### Task 4: Context Menu UI — Long-press menu in ConversationViewController

**Files:**
- Modify: `App/ConversationViewController.swift`
- Modify: `project.yml` — add `NSPhotoLibraryAddUsageDescription`

**Interfaces:**
- Consumes: `ConversationViewModel.canRecall(row:)`, `ConversationViewModel.recallMessage(row:completion:)`, `ConversationViewModel.deleteMessage(row:)`
- Produces: `ConversationViewController.var onForwardTapped: ((StoredMessageRow) -> Void)?` (wired in Task 5)

No automated tests for this task (UIKit layer). Manual test plan at step end.

- [ ] **Step 1: Add NSPhotoLibraryAddUsageDescription to project.yml**

In `project.yml`, inside the `info.properties` block alongside the existing usage descriptions:

```yaml
NSPhotoLibraryAddUsageDescription: "保存图片或视频到相册"
```

- [ ] **Step 2: Regenerate Xcode project**

```bash
bash Scripts/generate-xcodeproj.sh
```

- [ ] **Step 3: Add Photos import and onForwardTapped property to ConversationViewController**

At the top of `App/ConversationViewController.swift`, add after existing imports:

```swift
import Photos
```

Inside `final class ConversationViewController`, add the property:

```swift
var onForwardTapped: ((StoredMessageRow) -> Void)?
```

- [ ] **Step 4: Implement contextMenuConfigurationForRowAt in the UITableViewDelegate extension**

In `App/ConversationViewController.swift`, add inside `extension ConversationViewController: UITableViewDelegate`:

```swift
func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
    guard let item = dataSource.itemIdentifier(for: indexPath),
          case .message(let message) = item else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
        guard let self else { return UIMenu(title: "", children: []) }
        return self.buildContextMenu(for: message)
    }
}
```

- [ ] **Step 5: Add buildContextMenu and all action handlers**

Add as private methods inside `ConversationViewController` (not in the extension):

```swift
private func buildContextMenu(for message: StoredMessageRow) -> UIMenu {
    var actions: [UIAction] = []

    // Copy — text-only (excludes voice/file prefixes, location, video)
    if let text = message.text,
       message.voiceDuration == nil,
       message.fileName == nil,
       message.locationLat == nil,
       message.videoDuration == nil {
        actions.append(UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = text
        })
    }

    // Forward
    actions.append(UIAction(title: "转发", image: UIImage(systemName: "arrowshape.turn.up.right")) { [weak self] _ in
        self?.onForwardTapped?(message)
    })

    // Recall
    if viewModel.canRecall(row: message) {
        actions.append(UIAction(title: "撤回", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
            self?.handleRecall(message: message)
        })
    }

    // Delete
    actions.append(UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
        self?.handleDelete(message: message)
    })

    // Save image — image messages only (has thumbnail, no video/voice/file)
    if message.imageThumbnail != nil,
       message.videoDuration == nil,
       message.voiceDuration == nil,
       message.fileName == nil {
        actions.append(UIAction(title: "保存图片", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.saveMedia(urlString: message.imageRemoteURL, isVideo: false)
        })
    }

    // Save video
    if message.videoDuration != nil {
        actions.append(UIAction(title: "保存视频", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.saveMedia(urlString: message.imageRemoteURL, isVideo: true)
        })
    }

    return UIMenu(title: "", children: actions)
}

private func handleRecall(message: StoredMessageRow) {
    viewModel.recallMessage(row: message) { [weak self] success in
        DispatchQueue.main.async {
            guard !success else { return }
            let alert = UIAlertController(title: "撤回失败", message: "消息撤回失败，请稍后重试", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            self?.present(alert, animated: true)
        }
    }
}

private func handleDelete(message: StoredMessageRow) {
    let alert = UIAlertController(title: "删除消息", message: "删除后无法恢复，确认删除？", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
        self?.viewModel.deleteMessage(row: message)
    })
    present(alert, animated: true)
}

private func saveMedia(urlString: String?, isVideo: Bool) {
    guard let urlString, let url = URL(string: urlString) else { return }
    let indicator = UIActivityIndicatorView(style: .large)
    indicator.center = view.center
    view.addSubview(indicator)
    indicator.startAnimating()

    if isVideo {
        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, _ in
            DispatchQueue.main.async {
                indicator.removeFromSuperview()
                guard let tempURL, let self else { return }
                let destURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mp4")
                try? FileManager.default.moveItem(at: tempURL, to: destURL)
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: destURL)
                }) { success, _ in
                    DispatchQueue.main.async {
                        try? FileManager.default.removeItem(at: destURL)
                        self.showToast(success ? "视频已保存到相册" : "保存失败")
                    }
                }
            }
        }.resume()
    } else {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                indicator.removeFromSuperview()
                guard let data, let image = UIImage(data: data), let self else { return }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }) { success, _ in
                    DispatchQueue.main.async { self.showToast(success ? "图片已保存到相册" : "保存失败") }
                }
            }
        }.resume()
    }
}

private func showToast(_ message: String) {
    let toast = UILabel()
    toast.text = message
    toast.backgroundColor = UIColor.black.withAlphaComponent(0.7)
    toast.textColor = .white
    toast.textAlignment = .center
    toast.font = .systemFont(ofSize: 14)
    toast.layer.cornerRadius = 8
    toast.clipsToBounds = true
    toast.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(toast)
    NSLayoutConstraint.activate([
        toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
        toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        toast.heightAnchor.constraint(equalToConstant: 36),
    ])
    UIView.animate(withDuration: 0.3, delay: 1.5) { toast.alpha = 0 } completion: { _ in toast.removeFromSuperview() }
}
```

- [ ] **Step 6: Build to confirm it compiles**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Manual test checklist**

Run on Simulator, open a conversation with some messages:

- [ ] Long-press a **text message** → menu shows: 复制, 转发, 撤回(if own+acked), 删除
- [ ] Long-press an **image message** → menu shows: 转发, 撤回(if own), 删除, 保存图片
- [ ] Long-press a **video message** → menu shows: 转发, 撤回(if own), 删除, 保存视频
- [ ] Long-press a **voice message** → menu shows: 转发, 撤回(if own), 删除
- [ ] No menu on time headers or system tips
- [ ] "复制" copies text to clipboard (paste elsewhere to confirm)
- [ ] "删除" shows confirmation dialog; cancelling leaves message; confirming removes it
- [ ] "撤回" on own acked message shows success (bubble becomes "您撤回了一条消息")
- [ ] "保存图片" saves to Photos app

- [ ] **Step 8: Commit**

```bash
git add App/ConversationViewController.swift project.yml ios-chat-pro.xcodeproj
git commit -m "feat(App): add long-press context menu to chat messages (copy/recall/delete/save)"
```

---

### Task 5: Forward UI — ForwardPickerViewController + ForwardPreviewViewController

**Files:**
- Create: `App/ForwardPickerViewController.swift`
- Create: `App/ForwardPreviewViewController.swift`
- Modify: `App/ConversationViewController.swift` — add `forwardViewModelFactory` property
- Modify: `App/SceneDelegate.swift` — wire `forwardViewModelFactory`

**Interfaces:**
- Consumes: `ConversationListViewModel`, `ConversationListCell`, `ConversationViewModel.forward(row:to:note:)`, `ConversationRow`, `StoredMessageRow`
- Produces: Complete forward flow end-to-end

No automated tests (UIKit layer). Manual test plan at step end.

- [ ] **Step 1: Create ForwardPreviewViewController**

Create `App/ForwardPreviewViewController.swift`:

```swift
import UIKit
import IMKit

final class ForwardPreviewViewController: UIViewController {
    private let targetRow: ConversationRow
    private let sourceMessage: StoredMessageRow

    /// Called when the user taps "发送". Argument is the optional 留言 text.
    var onSend: ((String?) -> Void)?

    private let recipientLabel = UILabel()
    private let avatarImageView = AvatarImageView(loader: AvatarLoader.shared)
    private let previewContainer = UIView()
    private let noteField = UITextField()

    init(targetRow: ConversationRow, sourceMessage: StoredMessageRow) {
        self.targetRow = targetRow
        self.sourceMessage = sourceMessage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        configureContent()
    }

    private func layoutViews() {
        // Header: recipient info
        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .center

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 44),
            avatarImageView.heightAnchor.constraint(equalToConstant: 44),
        ])

        let sendToLabel = UILabel()
        sendToLabel.text = "发送给："
        sendToLabel.font = .systemFont(ofSize: 15)
        sendToLabel.textColor = Theme.textPrimary

        recipientLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        recipientLabel.textColor = Theme.textPrimary

        headerStack.addArrangedSubview(sendToLabel)
        headerStack.addArrangedSubview(avatarImageView)
        headerStack.addArrangedSubview(recipientLabel)
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        // Preview area
        previewContainer.backgroundColor = Theme.backgroundSecondary
        previewContainer.layer.cornerRadius = 8
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        // Note field
        noteField.placeholder = "给朋友留言"
        noteField.font = .systemFont(ofSize: 15)
        noteField.borderStyle = .none
        noteField.translatesAutoresizingMaskIntoConstraints = false

        let separator = UIView()
        separator.backgroundColor = Theme.backgroundTertiary
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Buttons
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let sendButton = UIButton(type: .system)
        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [cancelButton, sendButton])
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonSeparator = UIView()
        buttonSeparator.backgroundColor = Theme.backgroundTertiary
        buttonSeparator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerStack)
        view.addSubview(previewContainer)
        view.addSubview(noteField)
        view.addSubview(separator)
        view.addSubview(buttonSeparator)
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            previewContainer.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 16),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            noteField.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 16),
            noteField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            noteField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            noteField.heightAnchor.constraint(equalToConstant: 44),

            separator.topAnchor.constraint(equalTo: noteField.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            buttonSeparator.bottomAnchor.constraint(equalTo: buttonStack.topAnchor),
            buttonSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            buttonSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttonSeparator.heightAnchor.constraint(equalToConstant: 0.5),

            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttonStack.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    private func configureContent() {
        recipientLabel.text = targetRow.displayName
        avatarImageView.setAvatar(urlString: targetRow.avatarURL, displayName: targetRow.displayName)
        addPreviewContent()
    }

    private func addPreviewContent() {
        let msg = sourceMessage
        if let thumbnail = msg.imageThumbnail {
            let imageView = UIImageView(image: UIImage(data: thumbnail))
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
                imageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8),
                imageView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
                imageView.heightAnchor.constraint(equalToConstant: 120),
                imageView.widthAnchor.constraint(lessThanOrEqualTo: previewContainer.widthAnchor, constant: -16),
            ])
        } else {
            let previewText: String
            if msg.voiceDuration != nil { previewText = "🎤 语音消息" }
            else if let name = msg.fileName { previewText = "📄 \(name)" }
            else if msg.locationLat != nil { previewText = "📍 \(msg.text ?? "位置")" }
            else { previewText = msg.text.map { String($0.prefix(50)) } ?? "" }

            let label = UILabel()
            label.text = previewText
            label.font = .systemFont(ofSize: 14)
            label.textColor = Theme.textPrimary
            label.numberOfLines = 2
            label.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -12),
                label.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -12),
            ])
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func sendTapped() {
        let note = noteField.text?.trimmingCharacters(in: .whitespaces)
        dismiss(animated: true) { [weak self] in
            self?.onSend?(note?.isEmpty == false ? note : nil)
        }
    }
}
```

- [ ] **Step 2: Create ForwardPickerViewController**

Create `App/ForwardPickerViewController.swift`:

```swift
import UIKit
import Combine
import IMKit

final class ForwardPickerViewController: UIViewController {
    private let sourceMessage: StoredMessageRow
    private let viewModel: ConversationListViewModel
    private var cancellables = Set<AnyCancellable>()
    private var allRows: [ConversationRow] = []
    private var dataSource: UITableViewDiffableDataSource<Int, ConversationRow>!

    private let tableView = UITableView()
    private let searchBar = UISearchBar()

    /// Called after the user confirms the forward (preview sheet sent).
    /// Arguments: target conversation row, optional留言 note.
    var onConfirmForward: ((ConversationRow, String?) -> Void)?

    init(sourceMessage: StoredMessageRow, viewModel: ConversationListViewModel) {
        self.sourceMessage = sourceMessage
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "转发"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )
        layoutViews()
        configureDataSource()
        bindViewModel()
    }

    @objc private func cancelTapped() {
        navigationController?.popViewController(animated: true)
    }

    private func layoutViews() {
        searchBar.placeholder = "搜索"
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false

        tableView.register(ConversationListCell.self, forCellReuseIdentifier: ConversationListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchBar)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, ConversationRow>(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ConversationListCell.reuseIdentifier, for: indexPath) as! ConversationListCell
            cell.configure(with: row)
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$rows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rows in
                self?.allRows = rows
                self?.applyFilter(query: self?.searchBar.text ?? "")
            }
            .store(in: &cancellables)
    }

    private func applyFilter(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? allRows : allRows.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
        var snapshot = NSDiffableDataSourceSnapshot<Int, ConversationRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(filtered)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension ForwardPickerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let targetRow = dataSource.itemIdentifier(for: indexPath) else { return }
        let previewVC = ForwardPreviewViewController(targetRow: targetRow, sourceMessage: sourceMessage)
        previewVC.onSend = { [weak self] note in
            self?.onConfirmForward?(targetRow, note)
        }
        present(previewVC, animated: true)
    }
}

extension ForwardPickerViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applyFilter(query: searchText)
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
```

- [ ] **Step 3: Wire forwardViewModelFactory in ConversationViewController**

Add to `App/ConversationViewController.swift` inside the class body:

```swift
/// Set by SceneDelegate. Called each time the user initiates a forward to
/// produce a fresh ConversationListViewModel for the picker screen.
var forwardViewModelFactory: (() -> ConversationListViewModel)?
```

Add the private handler method (alongside the other `handle*` methods added in Task 4):

```swift
private func handleForward(message: StoredMessageRow) {
    guard let factory = forwardViewModelFactory else { return }
    let pickerVC = ForwardPickerViewController(sourceMessage: message, viewModel: factory())
    pickerVC.onConfirmForward = { [weak self, weak pickerVC] targetRow, note in
        self?.viewModel.forward(row: message, to: targetRow, note: note)
        self?.navigationController?.popViewController(animated: true)
    }
    navigationController?.pushViewController(pickerVC, animated: true)
}
```

In `buildContextMenu(for:)`, replace the "转发" action body (from Task 4, which called `onForwardTapped?`) with the new handler:

```swift
actions.append(UIAction(title: "转发", image: UIImage(systemName: "arrowshape.turn.up.right")) { [weak self] _ in
    self?.handleForward(message: message)
})
```

Remove the now-unused `onForwardTapped` property if it was added in Task 4.

- [ ] **Step 4: Wire forwardViewModelFactory in SceneDelegate**

In `App/SceneDelegate.swift`, inside `makeConversationListNavigationController()`, after creating `conversationViewController` (around line 142):

```swift
conversationViewController.forwardViewModelFactory = { [weak self] in
    ConversationListViewModel(
        storage: self?.environment.storage ?? (try! IMStorage.openInMemory()),
        contactSync: self?.environment.contactSyncService,
        groupSync: self?.environment.groupSyncService,
        currentUserId: self?.environment.imClient?.userId ?? ""
    )
}
```

Do the same inside `createGroupViewController.onGroupCreated` closure (around line 176) for the second `conversationViewController` created there.

- [ ] **Step 5: Build**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manual test checklist**

- [ ] Long-press a text message → tap "转发" → `ForwardPickerViewController` is pushed (shows conversation list with search bar)
- [ ] Search filters the list in real time
- [ ] Tap a conversation → `ForwardPreviewViewController` appears as a sheet
- [ ] Preview shows recipient name and message preview (thumbnail for image/video, text for text, "🎤 语音消息" for voice, filename for file)
- [ ] Type a 留言 in the text field
- [ ] Tap "取消" → sheet dismisses, stays on picker
- [ ] Tap "发送" → sheet dismisses, picker is popped, back in conversation; target conversation has new forwarded message + note
- [ ] Forward an image → target shows image bubble
- [ ] Forward a voice message → target shows voice bubble with correct duration
- [ ] Forward with no 留言 → only one message sent (no empty text)
- [ ] Tap cancel button (top-left) in picker → pops back to conversation

- [ ] **Step 7: Commit**

```bash
git add App/ForwardPickerViewController.swift App/ForwardPreviewViewController.swift App/ConversationViewController.swift App/SceneDelegate.swift
git commit -m "feat(App): add forward flow (ForwardPickerViewController + ForwardPreviewViewController)"
```

---

## Self-Review

**Spec coverage check:**
- ✅ 长按菜单 — Task 4: `UIContextMenuConfiguration` with `previewProvider: nil`
- ✅ 复制 — Task 4: `UIPasteboard.general.string`
- ✅ 转发 — Task 5: full picker + preview flow
- ✅ 撤回 — Task 2 (wire) + Task 3 (ViewModel) + Task 4 (menu item)
- ✅ 删除 — Task 1 (storage) + Task 3 (ViewModel) + Task 4 (menu item)
- ✅ 保存图片 / 保存视频 — Task 4: `PHPhotoLibrary`
- ✅ 群管理员撤回任意消息 — Task 3: `canRecall` checks `.manager`/`.owner`
- ✅ 撤回仅限服务端确认后 — Task 2: `pendingRecalls` + `RecallAckHandler`
- ✅ 转发附留言作为独立消息 — Task 3: `forward(row:to:note:)` calls `sendText` for note
- ✅ `voiceDuration`/`fileSize`/`fileName`/`messageUid` on StoredMessageRow — Task 1
- ✅ `NSPhotoLibraryAddUsageDescription` in Info.plist — Task 4
