# Message Recall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display "XXX 撤回了一条消息" in the chat and conversation list when a recall notification arrives from the server.

**Architecture:** The server pushes a `PUBLISH/RMN` frame containing `Im_NotifyRecallMessage {id, fromUser}`. A new `RecallNotifyMessageHandler` receives it, replaces the original message's content with `.recalled(operatorId:)` in-place, and re-saves the conversation row to trigger the Combine publisher chain. Both `ConversationViewModel` and `ConversationListViewModel` render the recalled content as a centred tip row / preview text.

**Tech Stack:** Swift, GRDB, Combine, SwiftProtobuf, XCTest

## Global Constraints

- `MessageContentType.recalled` raw value = 80 (matches Android `ContentType_Recall = 80`)
- No new DB migration — `textContent` column stores `operatorId` for recalled messages
- Signal for incoming recall notify: `.publish / .rmn` (SubSignal 31, not 30)
- Display text format: "你撤回了一条消息" (self) / "XXX撤回了一条消息" (others)
- No re-edit affordance — tip row is non-interactive

---

## Task 1: Storage Layer — `.recalled` content type

**Files:**
- Modify: `Sources/IMStorage/MessageEnums.swift`
- Modify: `Sources/IMStorage/StoredMessage.swift`
- Modify: `Sources/IMStorage/MessageStore.swift`
- Test: `Tests/IMStorageTests/StoredMessageTests.swift` (add cases)
- Test: `Tests/IMStorageTests/MessageStoreTests.swift` (add cases)

**Interfaces:**
- Produces:
  - `MessageContentType.recalled` (raw value `80`)
  - `MessageContent.recalled(operatorId: String)`
  - `MessageStore.updateContent(id: Int64, content: MessageContent, db: Database) throws`

---

- [ ] **Step 1: Write the failing StoredMessage tests**

Add at the bottom of `Tests/IMStorageTests/StoredMessageTests.swift`:

```swift
func test_recalledMessage_initFlattensOperatorIdIntoTextContent() {
    let message = StoredMessage(
        localMessageId: 99,
        conversationType: .single,
        target: "them",
        from: "them",
        content: .recalled(operatorId: "them"),
        timestamp: 2_000,
        status: .unread,
        direction: .receive
    )

    XCTAssertEqual(message.contentType, .recalled)
    XCTAssertEqual(message.textContent, "them")
    XCTAssertEqual(message.searchableContent, "[撤回消息]")
    XCTAssertNil(message.mediaRemoteURL)
    XCTAssertNil(message.mediaThumbnail)
    XCTAssertNil(message.groupNotificationOperator)
    XCTAssertNil(message.callId)
    XCTAssertEqual(message.callAudioOnly, false)
    XCTAssertEqual(message.callStatus, 0)
}

func test_recalledMessage_contentComputedPropertyRoundTrips() {
    let message = StoredMessage(
        localMessageId: 99, conversationType: .single, target: "them", from: "them",
        content: .recalled(operatorId: "them"), timestamp: 2_000, status: .unread, direction: .receive
    )
    XCTAssertEqual(message.content, .recalled(operatorId: "them"))
}

func test_setContent_recalled_clearsAllOtherColumns() {
    var message = StoredMessage(
        localMessageId: 1, conversationType: .single, target: "them", from: "them",
        content: .image(thumbnail: Data([0x01]), remoteURL: "https://example.com/a.jpg", localPath: nil),
        timestamp: 1_000, status: .unread, direction: .receive
    )
    message.setContent(.recalled(operatorId: "op"))

    XCTAssertEqual(message.contentType, .recalled)
    XCTAssertEqual(message.textContent, "op")
    XCTAssertEqual(message.searchableContent, "[撤回消息]")
    XCTAssertNil(message.mediaRemoteURL)
    XCTAssertNil(message.mediaThumbnail)
    XCTAssertNil(message.callId)
    XCTAssertNil(message.groupNotificationOperator)
}
```

- [ ] **Step 2: Run storage tests to confirm they fail**

```
swift test --filter IMStorageTests.StoredMessageTests 2>&1 | tail -20
```

Expected: compile error — `MessageContentType` has no member `recalled`, `MessageContent` has no case `recalled`.

- [ ] **Step 3: Add `recalled = 80` to `MessageContentType` in `MessageEnums.swift`**

In `Sources/IMStorage/MessageEnums.swift`, add the new case after `callStart`:

```swift
public enum MessageContentType: Int, Codable, Equatable {
    case text = 1
    case voice = 2
    case image = 3
    case file = 5
    case createGroup = 104
    case addGroupMember = 105
    case kickoffGroupMember = 106
    case quitGroup = 107
    case dismissGroup = 108
    case changeGroupName = 110
    case changeGroupPortrait = 112
    case callStart = 400
    /// Matches Android ContentType_Recall = 80. Stored in-place: the original
    /// message row is updated to this type when a RMN recall notification arrives.
    case recalled = 80
}
```

- [ ] **Step 4: Add `.recalled` to `MessageContent` and wire `setContent` / `content` in `StoredMessage.swift`**

In `Sources/IMStorage/StoredMessage.swift`, add the case to the enum:

```swift
public enum MessageContent: Equatable {
    case text(String)
    case image(thumbnail: Data?, remoteURL: String?, localPath: String?)
    case groupNotification(type: MessageContentType, operatorUid: String, memberUids: [String], value: String?)
    case callRecord(callId: String, targetId: String, audioOnly: Bool, status: Int, connectTime: Int64, endTime: Int64)
    case voice(remoteURL: String?, localPath: String?, duration: Int)
    case file(name: String, size: Int, remoteURL: String?, localPath: String?)
    /// The original message was recalled by `operatorId`. Stored in-place:
    /// `textContent` holds the operator uid; `searchableContent` is "[撤回消息]".
    case recalled(operatorId: String)
}
```

In the `content` computed var, add inside the switch (after the `case .file` branch, before the closing brace of the switch):

```swift
case .recalled:
    return .recalled(operatorId: textContent ?? "")
```

In `setContent(_:)`, add a new case at the end of the switch (before the closing brace):

```swift
case .recalled(let operatorId):
    contentType = .recalled
    textContent = operatorId
    searchableContent = "[撤回消息]"
    mediaRemoteURL = nil
    mediaLocalPath = nil
    mediaThumbnail = nil
    groupNotificationOperator = nil
    groupNotificationMembersRaw = nil
    groupNotificationValue = nil
    callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0
```

- [ ] **Step 5: Run StoredMessage tests to confirm they pass**

```
swift test --filter IMStorageTests.StoredMessageTests 2>&1 | tail -20
```

Expected: all StoredMessageTests pass (new and existing).

- [ ] **Step 6: Write the failing MessageStore test**

Add at the bottom of `Tests/IMStorageTests/MessageStoreTests.swift`:

```swift
func test_updateContent_db_updatesRecalledContent() throws {
    let inserted = try store.insert(makeMessage(localMessageId: 55, text: "original"))
    let rowId = try XCTUnwrap(inserted.id)

    try database.dbQueue.write { db in
        try store.updateContent(id: rowId, content: .recalled(operatorId: "them"), db: db)
    }

    let updated = try store.message(localMessageId: 55)
    XCTAssertEqual(updated?.content, .recalled(operatorId: "them"))
    XCTAssertEqual(updated?.searchableContent, "[撤回消息]")
}
```

- [ ] **Step 7: Run MessageStore test to confirm it fails**

```
swift test --filter IMStorageTests.MessageStoreTests.test_updateContent_db 2>&1 | tail -10
```

Expected: compile error — `updateContent` has no `db:` argument.

- [ ] **Step 8: Add `updateContent(id:content:db:)` to `MessageStore.swift`**

In `Sources/IMStorage/MessageStore.swift`, add the following method directly after the existing `updateContent(id:content:)` method:

```swift
/// Same as `updateContent(id:content:)`, run against a caller-managed
/// transaction — used by `RecallNotifyMessageHandler` to batch the
/// content update and the conversation row touch in one write transaction.
public func updateContent(id: Int64, content: MessageContent, db: Database) throws {
    guard var existing = try StoredMessage.fetchOne(db, key: id) else { return }
    existing.setContent(content)
    try existing.update(db)
}
```

- [ ] **Step 9: Run MessageStore tests to confirm they pass**

```
swift test --filter IMStorageTests.MessageStoreTests 2>&1 | tail -20
```

Expected: all MessageStoreTests pass.

- [ ] **Step 10: Commit**

```bash
git add Sources/IMStorage/MessageEnums.swift Sources/IMStorage/StoredMessage.swift Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/StoredMessageTests.swift Tests/IMStorageTests/MessageStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(Storage): add MessageContent.recalled + updateContent(id:content:db:)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Transport Handler — `RecallNotifyMessageHandler`

**Files:**
- Create: `Sources/IMMessaging/RecallNotifyMessageHandler.swift`
- Modify: `Sources/IMMessaging/MessagingService.swift`
- Create: `Tests/IMMessagingTests/RecallNotifyMessageHandlerTests.swift`

**Interfaces:**
- Consumes: `MessageContent.recalled(operatorId:)`, `MessageStore.updateContent(id:content:db:)`, `ConversationStore.recordIncomingMessage(...)`, `SubSignal.rmn`, `Im_NotifyRecallMessage`
- Produces:
  - `RecallNotifyMessageHandler` (public final class)
  - `RecallNotifyMessageHandler.onRecalled: ((Int64) -> Void)?`
  - `MessagingService.onMessageRecalled: ((Int64) -> Void)?`

---

- [ ] **Step 1: Write the failing handler tests**

Create `Tests/IMMessagingTests/RecallNotifyMessageHandlerTests.swift`:

```swift
import XCTest
import Combine
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMMessaging

final class RecallNotifyMessageHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: RecallNotifyMessageHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = RecallNotifyMessageHandler(storage: storage)
    }

    private func makeRecallFrame(messageUid: Int64, fromUser: String) throws -> Frame {
        var notify = Im_NotifyRecallMessage()
        notify.id = messageUid
        notify.fromUser = fromUser
        let body = try notify.serializedData()
        return Frame(
            header: Header(signal: .publish, subSignal: .rmn, bodyLength: UInt32(body.count), messageId: 1),
            body: body
        )
    }

    func test_canHandle_onlyMatchesPublishAndRMN() {
        XCTAssertTrue(handler.canHandle(signal: .publish, subSignal: .rmn))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mn))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mr))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .rmn))
    }

    func test_handle_updatesMessageContentToRecalled() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 100,
            conversationType: .single, target: "them", from: "them",
            content: .text("original"), timestamp: 1_000, status: .unread, direction: .receive
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: .single, target: "them", line: 0,
            messageUid: 100, timestamp: 1_000, incrementUnread: true
        )

        let frame = try makeRecallFrame(messageUid: 100, fromUser: "them")
        handler.handle(frame: frame)

        XCTAssertEqual(try storage.messages.message(uid: 100)?.content, .recalled(operatorId: "them"))
    }

    func test_handle_firesOnRecalledWithTheMessageUid() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 2, messageUid: 200,
            conversationType: .single, target: "them", from: "them",
            content: .text("bye"), timestamp: 2_000, status: .unread, direction: .receive
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: .single, target: "them", line: 0,
            messageUid: 200, timestamp: 2_000, incrementUnread: true
        )

        var firedUid: Int64?
        handler.onRecalled = { uid in firedUid = uid }

        let frame = try makeRecallFrame(messageUid: 200, fromUser: "them")
        handler.handle(frame: frame)

        XCTAssertEqual(firedUid, 200)
    }

    func test_handle_messageNotFound_doesNotCrashAndDoesNotFireCallback() throws {
        var firedUid: Int64?
        handler.onRecalled = { uid in firedUid = uid }

        let frame = try makeRecallFrame(messageUid: 999, fromUser: "them")
        handler.handle(frame: frame)

        XCTAssertNil(firedUid)
    }

    func test_handle_malformedBody_doesNotCrash() {
        handler.handle(frame: Frame(
            header: Header(signal: .publish, subSignal: .rmn, bodyLength: 2, messageId: 1),
            body: Data([0xFF, 0xFF])
        ))
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```
swift test --filter IMMessagingTests.RecallNotifyMessageHandlerTests 2>&1 | tail -10
```

Expected: compile error — `RecallNotifyMessageHandler` does not exist.

- [ ] **Step 3: Create `RecallNotifyMessageHandler.swift`**

Create `Sources/IMMessaging/RecallNotifyMessageHandler.swift`:

```swift
import IMClient
import IMTransport
import IMProto
import IMStorage

public final class RecallNotifyMessageHandler: MessageHandler {
    private let storage: IMStorage

    /// Fired after the recalled message has been updated in storage.
    /// The argument is the `messageUid` of the recalled message.
    /// Not fired when the message is not found locally (e.g. outside sync window).
    public var onRecalled: ((Int64) -> Void)?

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .publish && subSignal == .rmn
    }

    public func handle(frame: Frame) {
        guard let notify = try? Im_NotifyRecallMessage(serializedBytes: frame.body) else { return }
        let messageUid = notify.id
        let operatorId = notify.fromUser

        // `didUpdate` is mutated inside the synchronous `storage.write` block.
        // It stays false when the message row is not found locally so the
        // callback is not fired for a recall the client never stored.
        var didUpdate = false
        try? storage.write { db in
            guard let existing = try storage.messages.message(uid: messageUid, db: db),
                  let rowId = existing.id else { return }
            try storage.messages.updateContent(id: rowId, content: .recalled(operatorId: operatorId), db: db)
            try storage.conversations.recordIncomingMessage(
                conversationType: existing.conversationType,
                target: existing.target,
                line: existing.line,
                messageUid: existing.messageUid,
                timestamp: existing.timestamp,
                incrementUnread: false,
                db: db
            )
            didUpdate = true
        }
        if didUpdate { onRecalled?(messageUid) }
    }
}
```

- [ ] **Step 4: Run handler tests to confirm they pass**

```
swift test --filter IMMessagingTests.RecallNotifyMessageHandlerTests 2>&1 | tail -20
```

Expected: all 5 tests pass.

- [ ] **Step 5: Register handler and expose closure in `MessagingService.swift`**

In `Sources/IMMessaging/MessagingService.swift`, add the stored property after `receiveMessageHandler`:

```swift
private let recallNotifyHandler: RecallNotifyMessageHandler
```

Add the public closure after the `onCallSignal` property:

```swift
/// Forwards to the internal `RecallNotifyMessageHandler`'s closure.
/// Wire this to any UI that needs to react when a message is recalled
/// (e.g. to scroll to the updated row or dismiss a reply composer).
public var onMessageRecalled: ((Int64) -> Void)? {
    get { recallNotifyHandler.onRecalled }
    set { recallNotifyHandler.onRecalled = newValue }
}
```

In `init(...)`, add inside the body after the `notifyHandler` block:

```swift
let recallHandler = RecallNotifyMessageHandler(storage: storage)
recallNotifyHandler = recallHandler
imClient.register(recallHandler)
```

And initialise the stored property before `imClient.register(MessageSendAckHandler(...))` (Swift requires all stored properties to be set before calling methods):

Because Swift requires all stored properties to be initialised before any method is called on `self`, rearrange `init` so `recallNotifyHandler` is assigned before the first `imClient.register(...)` call. The full updated `init` body:

```swift
public init(
    imClient: IMClient,
    storage: IMStorage,
    scheduler: Scheduler = DispatchQueueScheduler(),
    idGenerator: LocalMessageIdGenerator = LocalMessageIdGenerator(),
    nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
) {
    self.imClient = imClient
    self.storage = storage
    tracker = OutgoingMessageTracker(scheduler: scheduler)
    self.idGenerator = idGenerator
    self.nowMillis = nowMillis

    imClient.register(MessageSendAckHandler(tracker: tracker))

    let receiveHandler = ReceiveMessageHandler(storage: storage, myUserId: { [weak imClient] in imClient?.userId ?? "" })
    receiveMessageHandler = receiveHandler
    imClient.register(receiveHandler)

    let notifyHandler = NotifyMessageHandler()
    notifyHandler.onNotify = { [weak self] head, type in self?.pullMessages(from: head, type: type) }
    imClient.register(notifyHandler)

    let recallHandler = RecallNotifyMessageHandler(storage: storage)
    recallNotifyHandler = recallHandler
    imClient.register(recallHandler)
}
```

- [ ] **Step 6: Run all messaging tests**

```
swift test --filter IMMessagingTests 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/IMMessaging/RecallNotifyMessageHandler.swift Sources/IMMessaging/MessagingService.swift Tests/IMMessagingTests/RecallNotifyMessageHandlerTests.swift
git commit -m "$(cat <<'EOF'
feat(Messaging): add RecallNotifyMessageHandler for PUBLISH/RMN signal

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: ConversationViewModel — render `.recalled` as system tip

**Files:**
- Modify: `Sources/IMKit/ConversationViewModel.swift`
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift` (add cases)

**Interfaces:**
- Consumes: `MessageContent.recalled(operatorId:)`, `SystemTipRow`, `ChatMessageRow.systemTip`
- Produces: `.systemTip` row with text "你撤回了一条消息" or "XXX撤回了一条消息"

---

- [ ] **Step 1: Write the failing ConversationViewModel tests**

Add at the bottom of `Tests/IMKitTests/ConversationViewModelTests.swift`:

```swift
func test_recalledBySelf_rendersAsSystemTipWithNi() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 10, messageUid: 500,
        conversationType: .single, target: "them", from: "me",
        content: .recalled(operatorId: "me"),
        timestamp: 5_000, status: .sent, direction: .send
    ))
    try storage.conversations.recordIncomingMessage(
        conversationType: .single, target: "them", line: 0,
        messageUid: 500, timestamp: 5_000, incrementUnread: false
    )

    waitForFirstNonEmptyRows()

    let tipRows = viewModel.rows.compactMap { row -> SystemTipRow? in
        if case .systemTip(let tip) = row { return tip }
        return nil
    }
    XCTAssertTrue(tipRows.contains { $0.text == "你撤回了一条消息" }, "rows: \(viewModel.rows)")
}

func test_recalledByOther_rendersAsSystemTipWithDisplayName() throws {
    try storage.users.upsertProfile(uid: "them", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
    try storage.messages.insert(StoredMessage(
        localMessageId: 11, messageUid: 501,
        conversationType: .single, target: "them", from: "them",
        content: .recalled(operatorId: "them"),
        timestamp: 5_001, status: .unread, direction: .receive
    ))
    try storage.conversations.recordIncomingMessage(
        conversationType: .single, target: "them", line: 0,
        messageUid: 501, timestamp: 5_001, incrementUnread: true
    )

    waitForFirstNonEmptyRows()

    let tipRows = viewModel.rows.compactMap { row -> SystemTipRow? in
        if case .systemTip(let tip) = row { return tip }
        return nil
    }
    XCTAssertTrue(tipRows.contains { $0.text == "Alice撤回了一条消息" }, "rows: \(viewModel.rows)")
}

func test_recalledByOtherWithNoProfile_fallsBackToUid() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 12, messageUid: 502,
        conversationType: .single, target: "unknown-uid", from: "unknown-uid",
        content: .recalled(operatorId: "unknown-uid"),
        timestamp: 5_002, status: .unread, direction: .receive
    ))
    try storage.conversations.recordIncomingMessage(
        conversationType: .single, target: "unknown-uid", line: 0,
        messageUid: 502, timestamp: 5_002, incrementUnread: true
    )

    waitForFirstNonEmptyRows()

    let tipRows = viewModel.rows.compactMap { row -> SystemTipRow? in
        if case .systemTip(let tip) = row { return tip }
        return nil
    }
    XCTAssertTrue(tipRows.contains { $0.text == "unknown-uid撤回了一条消息" }, "rows: \(viewModel.rows)")
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```
swift test --filter IMKitTests.ConversationViewModelTests.test_recalled 2>&1 | tail -10
```

Expected: compile error — `StoredMessage` init with `.recalled` fails until the switch in `makeRow` is exhausted.

Actually the compile error will be a non-exhaustive switch in `makeRow`. Confirm by running:

```
swift build 2>&1 | grep "error:" | head -5
```

Expected: error about non-exhaustive switch on `MessageContent`.

- [ ] **Step 3: Add `.recalled` case to `makeRow` in `ConversationViewModel.swift`**

In `Sources/IMKit/ConversationViewModel.swift`, find the `makeRow(_:)` method's switch statement and add the new case after `case .file`:

```swift
case .recalled(let operatorId):
    let name: String
    if operatorId == currentUserId {
        name = "你"
    } else {
        let user = try? storage.users.user(uid: operatorId)
        name = user?.displayName ?? user?.name ?? operatorId
    }
    return .systemTip(SystemTipRow(
        storageId: message.id ?? -1,
        text: "\(name)撤回了一条消息",
        timestamp: message.timestamp
    ))
```

- [ ] **Step 4: Run ConversationViewModel tests**

```
swift test --filter IMKitTests.ConversationViewModelTests 2>&1 | tail -20
```

Expected: all pass including the 3 new recalled tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/ConversationViewModel.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(IMKit): render recalled messages as system tip in ConversationViewModel

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: ConversationListViewModel preview + SceneDelegate wiring

**Files:**
- Modify: `Sources/IMKit/ConversationListViewModel.swift`
- Modify: `App/SceneDelegate.swift`
- Test: `Tests/IMKitTests/ConversationListViewModelTests.swift` (add cases + update setUp)

**Interfaces:**
- Consumes: `MessageContentType.recalled`, `StoredMessage.textContent` (holds operatorId)
- Produces: `ConversationListViewModel.init(storage:contactSync:groupSync:currentUserId:)`

---

- [ ] **Step 1: Write the failing ConversationListViewModel tests**

Add at the bottom of `Tests/IMKitTests/ConversationListViewModelTests.swift`:

```swift
func test_recalledBySelf_showsNiPreview() throws {
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
    viewModel.$rows.dropFirst().sink { rows in
        if !rows.isEmpty { expectation.fulfill() }
    }.store(in: &cancellables)
    wait(for: [expectation], timeout: 2)

    XCTAssertEqual(viewModel.rows.first?.previewText, "你撤回了一条消息")
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
```

- [ ] **Step 2: Run tests to confirm they fail**

```
swift test --filter IMKitTests.ConversationListViewModelTests.test_recalled 2>&1 | tail -10
```

Expected: fail with "XCTAssertEqual failed: ("hello") is not equal to ("你撤回了一条消息")" — the code compiles but hasn't been updated yet.

- [ ] **Step 3: Add `currentUserId` to `ConversationListViewModel` and handle recalled preview**

Replace the entire `Sources/IMKit/ConversationListViewModel.swift` with:

```swift
import Foundation
import Combine
import IMStorage

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ConversationListViewModel {
    @Published public private(set) var rows: [ConversationRow] = []

    private let storage: IMStorage
    private let contactSync: ContactInfoFetching?
    private let groupSync: GroupSyncing?
    private let currentUserId: String
    private var cancellable: AnyCancellable?

    public init(storage: IMStorage, contactSync: ContactInfoFetching?, groupSync: GroupSyncing? = nil, currentUserId: String = "") {
        self.storage = storage
        self.contactSync = contactSync
        self.groupSync = groupSync
        self.currentUserId = currentUserId

        cancellable = storage.conversations.conversationsPublisher()
            .replaceError(with: [])
            .combineLatest(
                storage.users.usersPublisher().replaceError(with: []),
                storage.groups.groupsPublisher().replaceError(with: [])
            )
            .map { conversations, _, _ in conversations }
            .sink { [weak self] conversations in self?.handleConversationsUpdate(conversations) }
    }

    private func handleConversationsUpdate(_ conversations: [StoredConversation]) {
        var unresolvedUids: [String] = []
        var unresolvedGroupIds: [String] = []

        rows = conversations.map { conversation in
            let lastMessage = (try? storage.messages.messages(
                conversationType: conversation.conversationType,
                target: conversation.target,
                line: conversation.line,
                limit: 1
            ))?.first

            if conversation.conversationType == .group {
                return makeGroupRow(conversation: conversation, lastMessage: lastMessage, unresolvedGroupIds: &unresolvedGroupIds)
            }

            let user = try? storage.users.user(uid: conversation.target)
            if user?.displayName == nil && user?.name == nil {
                unresolvedUids.append(conversation.target)
            }
            return ConversationRow(
                conversationType: conversation.conversationType,
                target: conversation.target,
                line: conversation.line,
                displayName: user?.displayName ?? user?.name ?? conversation.target,
                avatarURL: user?.portrait,
                previewText: conversation.draft.map { "[草稿] \($0)" } ?? recalledPreviewText(for: lastMessage) ?? lastMessage?.searchableContent ?? "",
                timestamp: conversation.timestamp,
                unreadCount: conversation.unreadCount,
                hasUnreadMention: conversation.unreadMentionCount > 0,
                isTop: conversation.isTop,
                isMuted: conversation.isMuted,
                lastMessageStatus: lastMessage?.status
            )
        }

        if !unresolvedUids.isEmpty {
            contactSync?.fetchUserInfo(uids: unresolvedUids, forceRefresh: false)
        }
        for groupId in unresolvedGroupIds {
            groupSync?.refreshGroup(targetId: groupId)
        }
    }

    private func makeGroupRow(conversation: StoredConversation, lastMessage: StoredMessage?, unresolvedGroupIds: inout [String]) -> ConversationRow {
        let group = try? storage.groups.group(groupId: conversation.target)
        if group == nil {
            unresolvedGroupIds.append(conversation.target)
        }
        let previewText: String
        if let draft = conversation.draft {
            previewText = "[草稿] \(draft)"
        } else if let recalled = recalledPreviewText(for: lastMessage) {
            previewText = recalled
        } else if let lastMessage {
            let sender = try? storage.users.user(uid: lastMessage.from)
            let senderName = sender?.displayName ?? sender?.name ?? lastMessage.from
            previewText = "\(senderName): \(lastMessage.searchableContent ?? "")"
        } else {
            previewText = ""
        }
        return ConversationRow(
            conversationType: .group,
            target: conversation.target,
            line: conversation.line,
            displayName: group?.name ?? conversation.target,
            avatarURL: group?.portrait,
            previewText: previewText,
            timestamp: conversation.timestamp,
            unreadCount: conversation.unreadCount,
            hasUnreadMention: conversation.unreadMentionCount > 0,
            isTop: conversation.isTop,
            isMuted: conversation.isMuted,
            lastMessageStatus: lastMessage?.status
        )
    }

    /// Returns a recall notice string if `lastMessage` is a recalled message,
    /// nil otherwise. Caller falls through to normal preview text on nil.
    private func recalledPreviewText(for lastMessage: StoredMessage?) -> String? {
        guard let msg = lastMessage, msg.contentType == .recalled else { return nil }
        let operatorId = msg.textContent ?? ""
        if operatorId == currentUserId { return "你撤回了一条消息" }
        let user = try? storage.users.user(uid: operatorId)
        let name = user?.displayName ?? user?.name ?? operatorId
        return "\(name)撤回了一条消息"
    }
}
```

- [ ] **Step 4: Run ConversationListViewModel tests**

```
swift test --filter IMKitTests.ConversationListViewModelTests 2>&1 | tail -20
```

Expected: all pass. The `setUp` already passes `currentUserId: ""` via the default (tests that don't test recall still work). The two new tests should now pass with "你撤回了一条消息" and "Bob撤回了一条消息".

> **If setUp fails:** If the existing `setUp` that builds `ConversationListViewModel(storage:contactSync:groupSync:)` breaks because of a missing argument, add `currentUserId: ""` as the default value makes it optional so it won't break. If it still fails, update the `setUp` line to explicitly pass `currentUserId: ""`.

- [ ] **Step 5: Wire `currentUserId` in `SceneDelegate.swift`**

In `App/SceneDelegate.swift`, find the line that creates `ConversationListViewModel` (around line 126):

```swift
let viewModel = ConversationListViewModel(storage: environment.storage, contactSync: environment.contactSyncService, groupSync: environment.groupSyncService)
```

Replace it with:

```swift
let viewModel = ConversationListViewModel(storage: environment.storage, contactSync: environment.contactSyncService, groupSync: environment.groupSyncService, currentUserId: environment.imClient?.userId ?? "")
```

- [ ] **Step 6: Build to verify no compile errors**

```
swift build 2>&1 | grep "error:" | head -10
```

Expected: no errors.

- [ ] **Step 7: Run the full test suite**

```
swift test 2>&1 | tail -30
```

Expected: all tests pass. No regressions.

- [ ] **Step 8: Commit**

```bash
git add Sources/IMKit/ConversationListViewModel.swift Tests/IMKitTests/ConversationListViewModelTests.swift App/SceneDelegate.swift
git commit -m "$(cat <<'EOF'
feat(IMKit): show recalled message preview in ConversationListViewModel

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```
