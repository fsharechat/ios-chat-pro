# Phase 1 / Plan D: IMMessaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `IMMessaging` — the send/receive message protocol layer that bridges `IMClient` (Plan B) and `IMStorage` (Plan C): composing and sending text/image messages with ack-based status tracking, and receiving messages via the server's notify-then-pull cycle.

**Architecture:** A new `IMMessaging` SwiftPM target depending on `IMClient`, `IMStorage`, `IMProto`, and `IMTransport`. Two small, additive modifications to already-merged files (`IMClient.sendFrame` becomes public and returns the allocated wire `messageId`; `IMStorage.MessageStore` gains a `message(uid:)` lookup) unlock everything else. The rest is new: an `OutgoingMessageTracker` correlates outgoing sends to their acks by wire `messageId` (mirroring `AbstractProtoService`'s `requestMap`), three `MessageHandler`s registered with `IMClient` (`MessageSendAckHandler`, `ReceiveMessageHandler`, `NotifyMessageHandler`), a `MessageContentCodec` translating between the wire `Im_MessageContent` and `IMStorage.MessageContent`, and a `MessagingService` facade tying it all together.

**Tech Stack:** Swift 5.8+, builds entirely on existing Plan A/B/C targets — no new external dependencies.

**Reference facts this plan is built from** (verified by reading the actual Android source and the real generated `WFCMessage.pb.swift` — not assumed):
- **Send flow** (`ProtoService.sendMessage`, `AbstractProtoService.sendMessage(Signal,SubSignal,long,byte[],Object)`): a client-generated `local_message_id` (Snowflake-style, via `MessageShardingUtil.generateId()`) is assigned before anything else; the message is persisted locally with `status=Sending` *before* sending; the wire frame uses `Signal.PUBLISH`/`SubSignal.MS`; the wire-level 16-bit frame `messageId` (NOT `local_message_id`) is the correlation key stored in a `requestMap[wireMessageId] = RequestInfo{..., protoMessageId}`; a 5-second timeout timer is scheduled *only* for `SubSignal.MS` sends, which marks the message `Send_Failure` and forces a reconnect if no ack arrives in time.
- **Send ack is NOT protobuf** (`SendMessageHandler.match/processMessage`): matches `Signal.PUB_ACK`/`SubSignal.MS`; body is hand-rolled binary — 1 byte error code, then (only if `errorCode == 0`) 8 bytes big-endian `Int64` `messageUid` + 8 bytes big-endian `Int64` `timestamp` (confirmed big-endian via `ByteBufferList`'s `ByteOrder.BIG_ENDIAN` default). On success: update the local row's uid+status by `protoMessageId` (i.e. `local_message_id`), looked up via the wire `messageId` that arrived in the ack's frame header.
- **Receive is a notify-then-pull cycle, not direct push** (`NotifyMessageHandler`, `ReceiveMessageHandler`, `ProtoService.pullMessage`): server sends `Signal.PUBLISH`/`SubSignal.MN` with a `NotifyMessage{type, head, target}` ("you have messages up to sequence `head`"); client responds by sending `Signal.PUBLISH`/`SubSignal.MP` with a `PullMessageRequest{id: head-1, type}`; server responds `Signal.PUB_ACK`/`SubSignal.MP` with a `PullMessageResult{message: [Message], current, head}`. The client also proactively sends the same `MP` pull on login, seeded from the locally stored sync state's `msgHead` (this is what Plan B's `ConnectAckHandler.onSyncState` callback is for). Pulled messages are deduped by server-assigned `message_uid` before inserting (pull windows can overlap).
- **Wire-field mapping for text/image content** (already documented in Plan C's plan, repeated here for this plan's direct use): text body → `searchable_content`; image → `searchable_content` digest (`"[图片]"`) + `data` (thumbnail bytes) + `remoteMediaUrl`. `localMediaPath` is never a wire field.
- **Actual SwiftProtobuf-generated Swift names differ from naive camelCase** (verified by reading `Sources/IMProto/Generated/WFCMessage.pb.swift` directly, not guessed): `Im_Message.messageID` (not `messageId`), `Im_Message.localMessageID` (not `localMessageId`), `Im_MessageContent.remoteMediaURL`/`hasRemoteMediaURL` (not `remoteMediaUrl`) — SwiftProtobuf capitalizes the `Id`/`Url` suffix to `ID`/`URL` per Swift naming conventions. `Im_Message.fromUser`, `.toUser`, `.serverTimestamp`, `.conversation: Im_Conversation{type: Int32, target: String, line: Int32}` are plain camelCase as expected. `Im_PullMessageRequest{id: Int64, type: Int32, delay: Int64}`, `Im_PullMessageResult{message: [Im_Message], current: Int64, head: Int64}`, `Im_NotifyMessage{type: Int32, head: Int64, target: String}`.
- **A subtle race this plan's `ReceiveMessageHandler` must handle**: a pull can re-deliver a message I sent myself, before my own send's ack arrives (e.g. after a reconnect). Deduping purely by server `message_uid` isn't enough in that case, since my local echo row's `messageUid` is still `0` at that point — the handler must *also* check `IMStorage`'s existing `direction = .send`-scoped `message(localMessageId:)` lookup (Plan C Task 4) before inserting, and update-in-place instead of inserting a duplicate, or it will hit Plan C's `(localMessageId, direction = .send)` partial unique index.

---

## Task 1: Extend `IMClient`'s public surface

**Files:**
- Modify: `Sources/IMClient/IMClient.swift`

- [ ] **Step 1: Make `sendFrame` public and return the allocated wire `messageId`, and add a `userId` accessor**

In `Sources/IMClient/IMClient.swift`, replace:

```swift
    private func sendFrame(
        signal: Signal,
        subSignal: SubSignal,
        body: Data,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        nextMessageId = nextMessageId &+ 1
        let bytes = FrameEncoder.encode(signal: signal, subSignal: subSignal, messageId: nextMessageId, body: body)
        transport?.send(bytes, completion: completion)
    }
```

with:

```swift
    /// Encodes and sends one frame, returning the wire `messageId` it was
    /// allocated. Public so `IMMessaging` (Plan D) can send business
    /// messages and correlate their acks by this id, exactly like
    /// `AbstractProtoService`'s `requestMap` does in the Android reference.
    @discardableResult
    public func sendFrame(
        signal: Signal,
        subSignal: SubSignal,
        body: Data,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) -> UInt16 {
        nextMessageId = nextMessageId &+ 1
        let messageId = nextMessageId
        let bytes = FrameEncoder.encode(signal: signal, subSignal: subSignal, messageId: messageId, body: body)
        transport?.send(bytes, completion: completion)
        return messageId
    }
```

Also add this computed property anywhere inside the `IMClient` class body (e.g. right after `register(_:)`):

```swift
    /// The logged-in user's id, needed by `IMMessaging` to set `fromUser`
    /// on outgoing messages and to distinguish "my own message coming back
    /// through a pull" from a genuinely received one.
    public var userId: String { configuration.userId }
```

- [ ] **Step 2: Build and run the full suite to confirm no regressions**

Run: `swift build`
Expected: `Build complete!`

Run: `swift test`
Expected: all 107 previously-existing tests still pass (this change adds no new tests of its own — Task 1's only job is to widen `IMClient`'s existing, already-tested behavior to a public entry point; `IMClientTests` already exercises `sendFrame`'s behavior indirectly through `connect()`/heartbeat/CONNECT, so no behavior changed, only visibility and return type).

- [ ] **Step 3: Commit**

```bash
git add Sources/IMClient/IMClient.swift
git commit -m "feat(IMClient): expose sendFrame publicly with its allocated messageId, add userId accessor"
```

---

## Task 2: Add `MessageStore.message(uid:)` lookup

**Files:**
- Modify: `Sources/IMStorage/MessageStore.swift`
- Modify: `Tests/IMStorageTests/MessageStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/IMStorageTests/MessageStoreTests.swift` (inside the `MessageStoreTests` class):

```swift
    func test_messageByUid_findsInsertedMessage() throws {
        let inserted = try store.insert(makeMessage(localMessageId: 50, text: "has a uid"))
        try store.updateMessageUid(localMessageId: 50, messageUid: 777)

        let found = try store.message(uid: 777)

        XCTAssertEqual(found?.content, .text("has a uid"))
        _ = inserted
    }

    func test_messageByUid_returnsNilWhenNotFound() throws {
        XCTAssertNil(try store.message(uid: 12345))
    }

    func test_messageByUid_withUidZero_alwaysReturnsNil() throws {
        // messageUid defaults to 0 for every not-yet-acked sent message —
        // querying uid 0 would be ambiguous across multiple pending sends,
        // so it must short-circuit to nil rather than returning an arbitrary row.
        try store.insert(makeMessage(localMessageId: 51))
        try store.insert(makeMessage(localMessageId: 52))

        XCTAssertNil(try store.message(uid: 0))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MessageStoreTests`
Expected: FAIL with `error: value of type 'MessageStore' has no member 'message'` referring to the new `uid:` overload (the existing `message(localMessageId:)` already compiles, so the error will be specific to the new call sites).

- [ ] **Step 3: Implement**

In `Sources/IMStorage/MessageStore.swift`, add this method (e.g. right after `message(localMessageId:)`):

```swift
    /// Looks up a message by server-assigned `messageUid` — used by
    /// `IMMessaging`'s receive path to dedup pulled messages against ones
    /// already stored (pull windows can overlap). `messageUid == 0` means
    /// "not yet acked" and is shared by every pending sent message, so it
    /// would be ambiguous to look up — short-circuits to `nil`.
    public func message(uid: Int64) throws -> StoredMessage? {
        guard uid != 0 else { return nil }
        return try dbQueue.read { db in
            try StoredMessage.filter(Column("messageUid") == uid).fetchOne(db)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MessageStoreTests`
Expected: `Executed 13 tests, with 0 failures` (10 existing + 3 new)

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/MessageStoreTests.swift
git commit -m "feat(IMStorage): add MessageStore.message(uid:) lookup for receive-path dedup"
```

---

## Task 3: Scaffold the `IMMessaging` SwiftPM target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/IMMessaging/_Scaffold.swift`
- Create: `Tests/IMMessagingTests/_Scaffold.swift`

- [ ] **Step 1: Edit `Package.swift`**

```swift
// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "IMCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "IMProto", targets: ["IMProto"]),
        .library(name: "IMTransport", targets: ["IMTransport"]),
        .library(name: "IMClient", targets: ["IMClient"]),
        .library(name: "IMStorage", targets: ["IMStorage"]),
        .library(name: "IMMessaging", targets: ["IMMessaging"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "IMProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(name: "IMProtoTests", dependencies: ["IMProto"]),
        .target(name: "IMTransport"),
        .testTarget(name: "IMTransportTests", dependencies: ["IMTransport"]),
        .target(name: "IMClient", dependencies: ["IMTransport", "IMProto"]),
        .testTarget(name: "IMClientTests", dependencies: ["IMClient"]),
        .target(name: "IMStorage", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "IMStorageTests", dependencies: ["IMStorage"]),
        .target(name: "IMMessaging", dependencies: ["IMClient", "IMStorage", "IMProto", "IMTransport"]),
        .testTarget(name: "IMMessagingTests", dependencies: ["IMMessaging"]),
    ]
)
```

- [ ] **Step 2: Create placeholder source**

```bash
mkdir -p Sources/IMMessaging Tests/IMMessagingTests
echo "// IMMessaging placeholder, removed in Task 4" > Sources/IMMessaging/_Scaffold.swift
echo "// IMMessagingTests placeholder, removed in Task 4" > Tests/IMMessagingTests/_Scaffold.swift
```

- [ ] **Step 3: Build and test**

Run: `swift build`
Expected: `Build complete!`

Run: `swift test`
Expected: all 110 previously-existing tests still pass (107 + Task 2's 3 new ones; the new `IMMessaging`/`IMMessagingTests` targets have no real tests yet).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/IMMessaging Tests/IMMessagingTests
git commit -m "chore: scaffold IMMessaging SwiftPM target"
```

---

## Task 4: `LocalMessageIdGenerator`

**Files:**
- Create: `Sources/IMMessaging/LocalMessageIdGenerator.swift`
- Test: `Tests/IMMessagingTests/LocalMessageIdGeneratorTests.swift`
- Modify: delete `Sources/IMMessaging/_Scaffold.swift`, delete `Tests/IMMessagingTests/_Scaffold.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMMessagingTests/LocalMessageIdGeneratorTests.swift
import XCTest
@testable import IMMessaging

final class LocalMessageIdGeneratorTests: XCTestCase {
    func test_next_returnsDistinctValuesAcrossManyRapidCalls() {
        let generator = LocalMessageIdGenerator()

        let ids = (0..<500).map { _ in generator.next() }

        XCTAssertEqual(Set(ids).count, 500)
    }

    func test_next_valuesAreNonNegativeAndIncreasingOverall() {
        let generator = LocalMessageIdGenerator()

        let first = generator.next()
        let second = generator.next()

        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LocalMessageIdGeneratorTests`
Expected: FAIL with `error: cannot find type 'LocalMessageIdGenerator' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMMessaging/LocalMessageIdGenerator.swift
import Foundation

/// Generates the client-side `local_message_id` embedded in outgoing
/// messages (used for send/ack dedup — see `chat-proto`'s
/// `Message.local_message_id` and `IMStorage`'s partial-unique-index design
/// in Plan C Task 2/4). Loosely inspired by Android's
/// `MessageShardingUtil.generateId()` (timestamp + rotating counter), but
/// the exact bit layout does not need to match: this id is never parsed by
/// the server, only stored/echoed back opaquely as an `int64`, and
/// `IMStorage`'s uniqueness guarantee is already scoped per-sender (this
/// device), not global — see this plan's "Reference facts" above.
///
/// **Threading contract:** like the rest of this codebase (see `IMClient`'s
/// own threading-contract doc comment), this has no internal locking and
/// must be called from a single consistent queue.
public final class LocalMessageIdGenerator {
    private var lastTimestampMillis: Int64 = 0
    private var sequence: Int64 = 0

    public init() {}

    /// `now`-injectable for tests; production callers use the default.
    public func next(now: Date = Date()) -> Int64 {
        let currentMillis = Int64(now.timeIntervalSince1970 * 1000)
        if currentMillis == lastTimestampMillis {
            sequence += 1
        } else {
            lastTimestampMillis = currentMillis
            sequence = 0
        }
        // 12 low bits for the per-millisecond sequence (4096 ids/ms before
        // wrapping, at which point two ids within the same ms could collide
        // — acceptable for this app's send rate).
        return (currentMillis << 12) | (sequence & 0xFFF)
    }
}
```

- [ ] **Step 4: Remove Task 3 scaffolding**

```bash
rm -f Sources/IMMessaging/_Scaffold.swift Tests/IMMessagingTests/_Scaffold.swift
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LocalMessageIdGeneratorTests`
Expected: `Executed 2 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMMessaging/LocalMessageIdGenerator.swift Tests/IMMessagingTests/LocalMessageIdGeneratorTests.swift
git add -u Sources/IMMessaging Tests/IMMessagingTests
git commit -m "feat(IMMessaging): add LocalMessageIdGenerator"
```

---

## Task 5: `MessageContentCodec`

**Files:**
- Create: `Sources/IMMessaging/MessageContentCodec.swift`
- Test: `Tests/IMMessagingTests/MessageContentCodecTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMMessagingTests/MessageContentCodecTests.swift
import XCTest
import Foundation
import IMProto
import IMStorage
@testable import IMMessaging

final class MessageContentCodecTests: XCTestCase {
    func test_encodeText_setsTypeAndSearchableContent_notContent() {
        let wire = MessageContentCodec.encode(.text("hello"))

        XCTAssertEqual(wire.type, 1)
        XCTAssertEqual(wire.searchableContent, "hello")
        XCTAssertFalse(wire.hasContent) // text body goes in searchable_content, not content
    }

    func test_decodeText_readsSearchableContent() throws {
        var wire = Im_MessageContent()
        wire.type = 1
        wire.searchableContent = "hello"

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .text("hello"))
    }

    func test_encodeImage_setsDigestThumbnailAndRemoteURL() {
        let thumbnail = Data([0x01, 0x02])
        let wire = MessageContentCodec.encode(.image(thumbnail: thumbnail, remoteURL: "https://example.com/a.jpg", localPath: "/tmp/a.jpg"))

        XCTAssertEqual(wire.type, 3)
        XCTAssertEqual(wire.searchableContent, "[图片]")
        XCTAssertEqual(wire.data, thumbnail)
        XCTAssertEqual(wire.remoteMediaURL, "https://example.com/a.jpg")
    }

    func test_decodeImage_readsThumbnailAndRemoteURL_localPathAlwaysNil() throws {
        var wire = Im_MessageContent()
        wire.type = 3
        wire.data = Data([0x01, 0x02])
        wire.remoteMediaURL = "https://example.com/a.jpg"

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .image(thumbnail: Data([0x01, 0x02]), remoteURL: "https://example.com/a.jpg", localPath: nil))
    }

    func test_decodeUnsupportedType_throws() {
        var wire = Im_MessageContent()
        wire.type = 6 // voice — not in Phase 1 scope

        XCTAssertThrowsError(try MessageContentCodec.decode(wire)) { error in
            XCTAssertEqual(error as? MessageContentCodec.DecodeError, .unsupportedContentType(6))
        }
    }

    func test_encodeThenDecode_roundTrips_forBothContentTypes() throws {
        XCTAssertEqual(try MessageContentCodec.decode(MessageContentCodec.encode(.text("round trip"))), .text("round trip"))

        let imageContent = MessageContent.image(thumbnail: Data([0xAA]), remoteURL: "https://example.com/b.jpg", localPath: nil)
        XCTAssertEqual(try MessageContentCodec.decode(MessageContentCodec.encode(imageContent)), imageContent)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MessageContentCodecTests`
Expected: FAIL with `error: cannot find type 'MessageContentCodec' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMMessaging/MessageContentCodec.swift
import IMProto
import IMStorage
import Foundation

/// Converts between the wire `Im_MessageContent` protobuf type and
/// `IMStorage.MessageContent`. Field mapping verified against
/// `chat-proto`'s `MessageContent` message and the Android
/// `TextMessageContent`/`ImageMessageContent`/`MediaMessageContent`
/// `encode()`/`decode()` methods (see this plan's "Reference facts"):
/// - text: body goes in `searchableContent`, not `content`.
/// - image: `searchableContent` holds a `"[图片]"` digest, `data` holds the
///   thumbnail bytes, `remoteMediaURL` holds the uploaded image URL.
///   `localPath` is never a wire field — always `nil` on decode.
public enum MessageContentCodec {
    public enum DecodeError: Error, Equatable {
        case unsupportedContentType(Int32)
    }

    public static func encode(_ content: MessageContent) -> Im_MessageContent {
        var wire = Im_MessageContent()
        switch content {
        case .text(let text):
            wire.type = 1
            wire.searchableContent = text
        case .image(let thumbnail, let remoteURL, _):
            wire.type = 3
            wire.searchableContent = "[图片]"
            if let thumbnail {
                wire.data = thumbnail
            }
            if let remoteURL {
                wire.remoteMediaURL = remoteURL
            }
        }
        return wire
    }

    public static func decode(_ wire: Im_MessageContent) throws -> MessageContent {
        switch wire.type {
        case 1:
            return .text(wire.hasSearchableContent ? wire.searchableContent : "")
        case 3:
            return .image(
                thumbnail: wire.hasData ? wire.data : nil,
                remoteURL: wire.hasRemoteMediaURL ? wire.remoteMediaURL : nil,
                localPath: nil
            )
        default:
            throw DecodeError.unsupportedContentType(wire.type)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MessageContentCodecTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMMessaging/MessageContentCodec.swift Tests/IMMessagingTests/MessageContentCodecTests.swift
git commit -m "feat(IMMessaging): add MessageContentCodec for Im_MessageContent <-> MessageContent"
```

---

## Task 6: `OutgoingMessageTracker`

Correlates a sent message to its ack by the wire `messageId` `IMClient.sendFrame` returned, mirroring `AbstractProtoService`'s `requestMap` + the 5-second `sendMsTimer` (only for `SubSignal.MS` sends — this tracker is `MS`-specific by construction, so every tracked send gets the timeout).

**Files:**
- Create: `Sources/IMMessaging/OutgoingMessageTracker.swift`
- Test: `Tests/IMMessagingTests/OutgoingMessageTrackerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMMessagingTests/OutgoingMessageTrackerTests.swift
import XCTest
import IMClient
@testable import IMMessaging

final class OutgoingMessageTrackerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: OutgoingMessageTracker!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = OutgoingMessageTracker(scheduler: scheduler)
    }

    func test_resolve_afterTrack_invokesCompletionWithLocalMessageIdAndResult() {
        var captured: (Int64, OutgoingMessageTracker.SendResult)?
        tracker.track(wireMessageId: 7, localMessageId: 999) { localId, result in
            captured = (localId, result)
        }

        tracker.resolve(wireMessageId: 7, result: .acked(messageUid: 123, timestamp: 456))

        XCTAssertEqual(captured?.0, 999)
        switch captured?.1 {
        case .acked(let uid, let ts): XCTAssertEqual(uid, 123); XCTAssertEqual(ts, 456)
        default: XCTFail("expected .acked")
        }
    }

    func test_resolve_unknownWireMessageId_doesNothingNoCrash() {
        tracker.resolve(wireMessageId: 42, result: .acked(messageUid: 1, timestamp: 1)) // no track() call first — must not crash
    }

    func test_timeout_firesFailedCompletion_ifNoAckArrives() {
        var captured: OutgoingMessageTracker.SendResult?
        tracker.track(wireMessageId: 7, localMessageId: 999) { _, result in captured = result }

        XCTAssertEqual(scheduler.scheduledDelays, [5])
        XCTAssertTrue(scheduler.fireNext()) // simulates the 5s timeout firing

        switch captured {
        case .failed: break
        default: XCTFail("expected .failed")
        }
    }

    func test_resolve_beforeTimeoutFires_cancelsTheTimeout() {
        var completionCallCount = 0
        tracker.track(wireMessageId: 7, localMessageId: 999) { _, _ in completionCallCount += 1 }

        tracker.resolve(wireMessageId: 7, result: .acked(messageUid: 1, timestamp: 1))
        XCTAssertEqual(completionCallCount, 1)

        XCTAssertFalse(scheduler.fireNext()) // the timeout was cancelled, nothing left to fire
        XCTAssertEqual(completionCallCount, 1) // still only called once
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OutgoingMessageTrackerTests`
Expected: FAIL with `error: cannot find type 'OutgoingMessageTracker' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMMessaging/OutgoingMessageTracker.swift
import IMClient

/// Correlates an outgoing `Signal.PUBLISH`/`SubSignal.MS` send to its ack by
/// the wire `messageId` `IMClient.sendFrame` returned — mirrors
/// `AbstractProtoService`'s `requestMap`. Schedules a 5-second timeout
/// (matching the Android `sendMsTimer` constant) that resolves as `.failed`
/// if no ack arrives in time.
public final class OutgoingMessageTracker {
    public enum SendResult {
        case acked(messageUid: Int64, timestamp: Int64)
        case failed(errorCode: Int32?)
    }

    private final class Pending {
        let localMessageId: Int64
        let completion: (Int64, SendResult) -> Void
        var timeoutToken: SchedulerToken?

        init(localMessageId: Int64, completion: @escaping (Int64, SendResult) -> Void) {
            self.localMessageId = localMessageId
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    /// Registers a pending send. `completion` receives the same
    /// `localMessageId` passed in here, so callers don't need a second
    /// lookup to know which local row to update.
    public func track(wireMessageId: UInt16, localMessageId: Int64, completion: @escaping (Int64, SendResult) -> Void) {
        let entry = Pending(localMessageId: localMessageId, completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failed(errorCode: nil))
        }
        pending[wireMessageId] = entry
    }

    /// Called by `MessageSendAckHandler` when a `PUB_ACK`/`MS` frame
    /// arrives, or internally when the timeout fires. A no-op if
    /// `wireMessageId` isn't (or is no longer) tracked.
    public func resolve(wireMessageId: UInt16, result: SendResult) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(entry.localMessageId, result)
    }
}
```

- [ ] **Step 4: Remove the now-redundant placeholder import check** — N/A, no scaffolding left to remove in this task.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter OutgoingMessageTrackerTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMMessaging/OutgoingMessageTracker.swift Tests/IMMessagingTests/OutgoingMessageTrackerTests.swift
git commit -m "feat(IMMessaging): add OutgoingMessageTracker for send/ack correlation"
```

---

## Task 7: `MessageSendAckHandler`

**Files:**
- Create: `Sources/IMMessaging/MessageSendAckHandler.swift`
- Test: `Tests/IMMessagingTests/MessageSendAckHandlerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMMessagingTests/MessageSendAckHandlerTests.swift
import XCTest
import IMClient
import IMTransport
@testable import IMMessaging

final class MessageSendAckHandlerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: OutgoingMessageTracker!
    private var handler: MessageSendAckHandler!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = OutgoingMessageTracker(scheduler: scheduler)
        handler = MessageSendAckHandler(tracker: tracker)
    }

    private func bigEndianInt64Bytes(_ value: Int64) -> [UInt8] {
        let unsigned = UInt64(bitPattern: value)
        return (0..<8).map { UInt8((unsigned >> (8 * (7 - $0))) & 0xFF) }
    }

    func test_canHandle_onlyMatchesPubAckAndMS() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .ms))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .mp))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .ms))
    }

    func test_handle_successBody_resolvesTrackerWithAckedUidAndTimestamp() {
        var captured: OutgoingMessageTracker.SendResult?
        tracker.track(wireMessageId: 9, localMessageId: 555) { _, result in captured = result }

        var body: [UInt8] = [0x00] // error code 0 = success
        body += bigEndianInt64Bytes(123_456)
        body += bigEndianInt64Bytes(789)
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .ms, bodyLength: UInt32(body.count), messageId: 9), body: Data(body))

        handler.handle(frame: frame)

        switch captured {
        case .acked(let uid, let ts):
            XCTAssertEqual(uid, 123_456)
            XCTAssertEqual(ts, 789)
        default:
            XCTFail("expected .acked, got \(String(describing: captured))")
        }
    }

    func test_handle_failureBody_resolvesTrackerWithFailedErrorCode() {
        var captured: OutgoingMessageTracker.SendResult?
        tracker.track(wireMessageId: 9, localMessageId: 555) { _, result in captured = result }

        let frame = Frame(header: Header(signal: .pubAck, subSignal: .ms, bodyLength: 1, messageId: 9), body: Data([0x06]))

        handler.handle(frame: frame)

        switch captured {
        case .failed(let code): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failed, got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .ms, bodyLength: 0, messageId: 9), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MessageSendAckHandlerTests`
Expected: FAIL with `error: cannot find type 'MessageSendAckHandler' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMMessaging/MessageSendAckHandler.swift
import IMClient
import IMTransport

/// Parses the `PUB_ACK`/`MS` response to a sent message and resolves the
/// matching `OutgoingMessageTracker` entry. The body is **not** protobuf —
/// it's a hand-rolled binary format (see this plan's "Reference facts"):
/// 1 byte error code, then (only if `errorCode == 0`) 8 bytes big-endian
/// `Int64` `messageUid` + 8 bytes big-endian `Int64` `timestamp`.
public final class MessageSendAckHandler: MessageHandler {
    private let tracker: OutgoingMessageTracker

    public init(tracker: OutgoingMessageTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .ms
    }

    public func handle(frame: Frame) {
        guard !frame.body.isEmpty else { return }
        let bytes = [UInt8](frame.body)
        let errorCode = bytes[0]
        if errorCode == 0, bytes.count >= 17 {
            let messageUid = Self.readBigEndianInt64(bytes, at: 1)
            let timestamp = Self.readBigEndianInt64(bytes, at: 9)
            tracker.resolve(wireMessageId: frame.header.messageId, result: .acked(messageUid: messageUid, timestamp: timestamp))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failed(errorCode: Int32(errorCode)))
        }
    }

    private static func readBigEndianInt64(_ bytes: [UInt8], at offset: Int) -> Int64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return Int64(bitPattern: value)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MessageSendAckHandlerTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMMessaging/MessageSendAckHandler.swift Tests/IMMessagingTests/MessageSendAckHandlerTests.swift
git commit -m "feat(IMMessaging): add MessageSendAckHandler for binary PUB_ACK/MS parsing"
```

---

## Task 8: `ReceiveMessageHandler`

Parses a pulled message batch (`PUB_ACK`/`MP`), persists new messages, updates conversations, and advances the local sync state — with the race-safe own-message-already-echoed handling documented in this plan's "Reference facts".

**Files:**
- Create: `Sources/IMMessaging/ReceiveMessageHandler.swift`
- Test: `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMMessaging

final class ReceiveMessageHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: ReceiveMessageHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = ReceiveMessageHandler(storage: storage, myUserId: { "me" })
    }

    private func makeWireMessage(uid: Int64, from: String, target: String, localId: Int64 = 0, text: String = "hi", timestamp: Int64 = 1_000) -> Im_Message {
        var message = Im_Message()
        message.messageID = uid
        message.fromUser = from
        message.conversation.type = 0 // single
        message.conversation.target = target
        message.conversation.line = 0
        message.content = MessageContentCodec.encode(.text(text))
        message.serverTimestamp = timestamp
        message.localMessageID = localId
        return message
    }

    private func makePullResultFrame(messages: [Im_Message], head: Int64) throws -> Frame {
        var result = Im_PullMessageResult()
        result.message = messages
        result.head = head
        result.current = head
        let body = try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .mp, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndMP() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .mp))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .ms))
    }

    func test_handle_newReceivedMessage_persistsAndIncrementsConversationUnread() throws {
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 100, from: "them", target: "them", text: "hello")], head: 100)

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.messages.message(uid: 100)?.content, .text("hello"))
        let conversation = try storage.conversations.conversation(conversationType: .single, target: "them")
        XCTAssertEqual(conversation?.unreadCount, 1)
        XCTAssertEqual(try storage.syncState.get().msgHead, 100)
    }

    func test_handle_ownSentMessageInPull_doesNotIncrementUnread() throws {
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 101, from: "me", target: "them", text: "from me")], head: 101)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .single, target: "them")
        XCTAssertEqual(conversation?.unreadCount, 0)
        XCTAssertEqual(try storage.messages.message(uid: 101)?.direction, .send)
    }

    func test_handle_duplicateByUid_doesNotInsertTwiceOrDoubleCountUnread() throws {
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 102, from: "them", target: "them")], head: 102)
        handler.handle(frame: frame)
        handler.handle(frame: frame) // overlapping pull window redelivers the same uid

        let conversation = try storage.conversations.conversation(conversationType: .single, target: "them")
        XCTAssertEqual(conversation?.unreadCount, 1)
    }

    func test_handle_ownMessageAlreadyLocallyEchoed_updatesInPlaceRatherThanDuplicating() throws {
        // Simulate: I sent a message (local echo inserted, status .sending,
        // messageUid still 0), then a pull redelivers it before my own
        // send's ack arrived.
        try storage.messages.insert(StoredMessage(
            localMessageId: 555, conversationType: .single, target: "them", from: "me",
            content: .text("already echoed"), timestamp: 1_000, status: .sending, direction: .send
        ))

        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 200, from: "me", target: "them", localId: 555, text: "already echoed")], head: 200)
        handler.handle(frame: frame)

        let messages = try storage.messages.messages(conversationType: .single, target: "them")
        XCTAssertEqual(messages.count, 1) // not duplicated
        XCTAssertEqual(messages.first?.messageUid, 200)
        XCTAssertEqual(messages.first?.status, .sent)
    }

    func test_handle_syncHeadOnlyAdvancesForward() throws {
        try storage.syncState.set(StoredSyncState(msgHead: 500, friendHead: 1, friendRequestHead: 2, settingHead: 3))

        let frame = try makePullResultFrame(messages: [], head: 100) // a stale/out-of-order pull response
        handler.handle(frame: frame)

        let state = try storage.syncState.get()
        XCTAssertEqual(state.msgHead, 500) // unchanged, not regressed to 100
        XCTAssertEqual(state.friendHead, 1) // other fields preserved
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ReceiveMessageHandlerTests`
Expected: FAIL with `error: cannot find type 'ReceiveMessageHandler' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMMessaging/ReceiveMessageHandler.swift
import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses a `PUB_ACK`/`MP` pulled-message batch, persists new messages,
/// updates the affected conversations, and advances the local sync state.
/// See this plan's "Reference facts" for the own-message-race handling.
public final class ReceiveMessageHandler: MessageHandler {
    private let storage: IMStorage
    private let myUserId: () -> String

    public init(storage: IMStorage, myUserId: @escaping () -> String) {
        self.storage = storage
        self.myUserId = myUserId
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .mp
    }

    public func handle(frame: Frame) {
        guard let result = try? Im_PullMessageResult(serializedBytes: frame.body) else { return }
        for wireMessage in result.message {
            persist(wireMessage)
        }
        advanceSyncHead(to: result.head)
    }

    private func persist(_ wireMessage: Im_Message) {
        guard wireMessage.messageID != 0 else { return }
        if (try? storage.messages.message(uid: wireMessage.messageID)) != nil {
            return // already have it via server uid — pull windows can overlap
        }

        let direction: MessageDirection = wireMessage.fromUser == myUserId() ? .send : .receive

        if direction == .send, wireMessage.localMessageID != 0,
           (try? storage.messages.message(localMessageId: wireMessage.localMessageID)) != nil {
            // My own message, already locally echoed before its own ack
            // arrived (e.g. a reconnect race) — update in place rather than
            // risk a duplicate-row insert against the
            // (localMessageId, direction = .send) unique index.
            try? storage.messages.updateMessageUid(localMessageId: wireMessage.localMessageID, messageUid: wireMessage.messageID)
            try? storage.messages.updateStatus(localMessageId: wireMessage.localMessageID, status: .sent)
            return
        }

        guard let content = try? MessageContentCodec.decode(wireMessage.content) else { return }
        let conversationType = ConversationType(rawValue: Int(wireMessage.conversation.type)) ?? .single
        let target = wireMessage.conversation.target
        let line = Int(wireMessage.conversation.line)

        do {
            try storage.messages.insert(StoredMessage(
                localMessageId: wireMessage.localMessageID,
                messageUid: wireMessage.messageID,
                conversationType: conversationType,
                target: target,
                line: line,
                from: wireMessage.fromUser,
                content: content,
                timestamp: wireMessage.serverTimestamp,
                status: direction == .send ? .sent : .unread,
                direction: direction
            ))
            try storage.conversations.recordIncomingMessage(
                conversationType: conversationType,
                target: target,
                line: line,
                messageUid: wireMessage.messageID,
                timestamp: wireMessage.serverTimestamp,
                incrementUnread: direction == .receive
            )
        } catch {
            // Best-effort: one malformed/unexpected row shouldn't abort the rest of the batch.
        }
    }

    private func advanceSyncHead(to head: Int64) {
        guard let current = try? storage.syncState.get(), head > current.msgHead else { return }
        try? storage.syncState.set(StoredSyncState(
            msgHead: head,
            friendHead: current.friendHead,
            friendRequestHead: current.friendRequestHead,
            settingHead: current.settingHead
        ))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ReceiveMessageHandlerTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMMessaging/ReceiveMessageHandler.swift Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift
git commit -m "feat(IMMessaging): add ReceiveMessageHandler for pulled-message batches"
```

---

## Task 9: `NotifyMessageHandler`

**Files:**
- Create: `Sources/IMMessaging/NotifyMessageHandler.swift`
- Test: `Tests/IMMessagingTests/NotifyMessageHandlerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMMessagingTests/NotifyMessageHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
@testable import IMMessaging

final class NotifyMessageHandlerTests: XCTestCase {
    func test_canHandle_onlyMatchesPublishAndMN() {
        let handler = NotifyMessageHandler()
        XCTAssertTrue(handler.canHandle(signal: .publish, subSignal: .mn))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mp))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .mn))
    }

    func test_handle_invokesOnNotify_withHeadMinusOneAndType() throws {
        let handler = NotifyMessageHandler()
        var captured: (Int64, Int32)?
        handler.onNotify = { head, type in captured = (head, type) }

        var notify = Im_NotifyMessage()
        notify.head = 100
        notify.type = 1
        let body = try notify.serializedData()
        let frame = Frame(header: Header(signal: .publish, subSignal: .mn, bodyLength: UInt32(body.count), messageId: 1), body: body)

        handler.handle(frame: frame)

        XCTAssertEqual(captured?.0, 99)
        XCTAssertEqual(captured?.1, 1)
    }

    func test_handle_malformedBody_doesNotCrashAndDoesNotInvokeCallback() {
        let handler = NotifyMessageHandler()
        var invoked = false
        handler.onNotify = { _, _ in invoked = true }

        handler.handle(frame: Frame(header: Header(signal: .publish, subSignal: .mn, bodyLength: 2, messageId: 1), body: Data([0xFF, 0xFF])))

        XCTAssertFalse(invoked)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotifyMessageHandlerTests`
Expected: FAIL with `error: cannot find type 'NotifyMessageHandler' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMMessaging/NotifyMessageHandler.swift
import IMClient
import IMTransport
import IMProto

/// Parses a `PUBLISH`/`MN` "you have new messages" notification and invokes
/// `onNotify` with `(head - 1, type)` — the exact arguments
/// `ProtoService.pullMessage` is called with in the Android reference, so
/// whoever wires `onNotify` (see `MessagingService`, Task 10) can pass them
/// straight through to a pull request.
public final class NotifyMessageHandler: MessageHandler {
    public var onNotify: ((Int64, Int32) -> Void)?

    public init() {}

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .publish && subSignal == .mn
    }

    public func handle(frame: Frame) {
        guard let notify = try? Im_NotifyMessage(serializedBytes: frame.body) else { return }
        onNotify?(notify.head - 1, notify.type)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NotifyMessageHandlerTests`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMMessaging/NotifyMessageHandler.swift Tests/IMMessagingTests/NotifyMessageHandlerTests.swift
git commit -m "feat(IMMessaging): add NotifyMessageHandler"
```

---

## Task 10: `MessagingService` facade

Wires the three handlers into a given `IMClient`, owns the `OutgoingMessageTracker`, and exposes the public `sendText`/`sendImage`/`pullMessagesSinceLastSync` API. This is the only type Plan E/F's UI code needs to construct.

**Files:**
- Create: `Sources/IMMessaging/MessagingService.swift`
- Create: `Tests/IMMessagingTests/Support/FakeTransportConnection.swift` (a small local duplicate of the one in `IMClientTests` — `internal` types aren't visible across SPM test targets, so each test target that needs one keeps its own; this one only implements what Task 10's tests use)
- Test: `Tests/IMMessagingTests/MessagingServiceTests.swift`

- [ ] **Step 1: Add the local fake transport**

```swift
// Tests/IMMessagingTests/Support/FakeTransportConnection.swift
import Foundation
import IMClient

final class FakeTransportConnection: IMTransportConnection {
    var onEvent: ((IMTransportEvent) -> Void)?
    var onDataReceived: ((Data) -> Void)?

    private(set) var sentFrames: [Data] = []
    private var pendingCompletions: [(Result<Void, Error>) -> Void] = []

    func start() {}

    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        sentFrames.append(data)
        pendingCompletions.append(completion)
    }

    func cancel() {}

    func simulate(_ event: IMTransportEvent) {
        onEvent?(event)
    }

    func simulateReceivedData(_ data: Data) {
        onDataReceived?(data)
    }

    @discardableResult
    func completeOldestSend(_ result: Result<Void, Error> = .success(())) -> Bool {
        guard !pendingCompletions.isEmpty else { return false }
        pendingCompletions.removeFirst()(result)
        return true
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/IMMessagingTests/MessagingServiceTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMMessaging

final class MessagingServiceTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var scheduler: ManualScheduler!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var service: MessagingService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        scheduler = ManualScheduler()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, scheduler: scheduler, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        service = MessagingService(imClient: imClient, storage: storage, scheduler: scheduler)

        imClient.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend() // CONNECT message send completes; transport is now ready for business messages
    }

    private func decodeOnlySentFrame() throws -> Frame {
        let frame = try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
        return frame
    }

    func test_sendText_insertsLocalEchoAndSendsCorrectWireFrame() throws {
        try service.sendText(to: "them", text: "hello")

        let echo = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(echo?.content, .text("hello"))
        XCTAssertEqual(echo?.status, .sending)

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .ms)
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.fromUser, "me")
        XCTAssertEqual(wireMessage.conversation.target, "them")
        XCTAssertEqual(try MessageContentCodec.decode(wireMessage.content), .text("hello"))
        XCTAssertEqual(wireMessage.localMessageID, echo?.localMessageId)
    }

    func test_sendText_ackArrival_updatesStatusAndMessageUid() throws {
        try service.sendText(to: "them", text: "hello")
        let sentFrame = try decodeOnlySentFrame()

        var ackBody: [UInt8] = [0x00]
        let uidBytes = (0..<8).map { UInt8((UInt64(bitPattern: 999) >> (8 * (7 - $0))) & 0xFF) }
        let tsBytes = (0..<8).map { UInt8((UInt64(bitPattern: 1_234) >> (8 * (7 - $0))) & 0xFF) }
        ackBody += uidBytes + tsBytes
        let ackFrameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .ms, messageId: sentFrame.header.messageId, body: Data(ackBody))
        fakeTransport.simulateReceivedData(ackFrameBytes)

        let updated = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(updated?.status, .sent)
        XCTAssertEqual(updated?.messageUid, 999)
    }

    func test_sendText_timeout_marksSendFailure() throws {
        try service.sendText(to: "them", text: "hello")

        XCTAssertTrue(scheduler.scheduledDelays.contains(5))
        scheduler.fireNext() // fires the 5s ack timeout (the only thing scheduled at this point)

        let updated = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(updated?.status, .sendFailure)
    }

    func test_receivingPullResult_isHandledEndToEnd() throws {
        var pullResult = Im_PullMessageResult()
        var wireMessage = Im_Message()
        wireMessage.messageID = 100
        wireMessage.fromUser = "them"
        wireMessage.conversation.target = "them"
        wireMessage.content = MessageContentCodec.encode(.text("incoming"))
        wireMessage.serverTimestamp = 1_000
        pullResult.message = [wireMessage]
        pullResult.head = 100
        let body = try pullResult.serializedData()
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(try storage.messages.message(uid: 100)?.content, .text("incoming"))
        XCTAssertEqual(try storage.syncState.get().msgHead, 100)
    }

    func test_receivingNotify_sendsAPullRequest() throws {
        var notify = Im_NotifyMessage()
        notify.head = 50
        notify.type = 0
        let body = try notify.serializedData()
        let frameBytes = FrameEncoder.encode(signal: .publish, subSignal: .mn, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .mp)
        let request = try Im_PullMessageRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.id, 49) // head - 1
    }

    func test_pullMessagesSinceLastSync_sendsPullRequestSeededFromSyncState() throws {
        service.pullMessagesSinceLastSync(syncState: ConnectAckSyncState(messageHead: 77, friendHead: 0, friendRequestHead: 0, settingHead: 0, serverTime: 0))

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .mp)
        let request = try Im_PullMessageRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.id, 77)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter MessagingServiceTests`
Expected: FAIL with `error: cannot find type 'MessagingService' in scope`

- [ ] **Step 4: Implement**

```swift
// Sources/IMMessaging/MessagingService.swift
import Foundation
import IMClient
import IMTransport
import IMProto
import IMStorage

/// The single entry point Plan E/F's UI code constructs: wires
/// `MessageSendAckHandler`/`ReceiveMessageHandler`/`NotifyMessageHandler`
/// into the given `IMClient`, and exposes `sendText`/`sendImage`/
/// `pullMessagesSinceLastSync`.
public final class MessagingService {
    private let imClient: IMClient
    private let storage: IMStorage
    private let tracker: OutgoingMessageTracker
    private let idGenerator: LocalMessageIdGenerator
    private let nowMillis: () -> Int64

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
        imClient.register(ReceiveMessageHandler(storage: storage, myUserId: { [weak imClient] in imClient?.userId ?? "" }))
        let notifyHandler = NotifyMessageHandler()
        notifyHandler.onNotify = { [weak self] head, type in self?.pullMessages(from: head, type: type) }
        imClient.register(notifyHandler)
    }

    /// Call once after a successful login (wire this to
    /// `ConnectAckHandler.onSyncState`, Plan B Task 11) to catch up on
    /// anything missed while disconnected, seeded from the locally stored
    /// sync state rather than starting from zero.
    public func pullMessagesSinceLastSync(syncState: ConnectAckSyncState) {
        pullMessages(from: syncState.messageHead, type: 0)
    }

    public func sendText(to target: String, conversationType: ConversationType = .single, line: Int = 0, text: String) throws {
        try send(to: target, conversationType: conversationType, line: line, content: .text(text))
    }

    public func sendImage(to target: String, conversationType: ConversationType = .single, line: Int = 0, thumbnail: Data?, remoteURL: String) throws {
        try send(to: target, conversationType: conversationType, line: line, content: .image(thumbnail: thumbnail, remoteURL: remoteURL, localPath: nil))
    }

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

    private func pullMessages(from beforeHead: Int64, type: Int32) {
        var request = Im_PullMessageRequest()
        request.id = beforeHead
        request.type = type
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .mp, body: body)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MessagingServiceTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 6: Run the entire suite one final time**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/IMMessaging/MessagingService.swift Tests/IMMessagingTests/MessagingServiceTests.swift Tests/IMMessagingTests/Support/FakeTransportConnection.swift
git commit -m "feat(IMMessaging): add MessagingService facade tying send/receive together"
```

---

## Plan Self-Review Notes

- **Spec coverage:** This plan implements migration-design-doc §5.6 (handler architecture) for the two handlers Phase 1 actually needs end-to-end (send-ack, receive-pull) plus the notify trigger, and closes the gap Plan B's self-review explicitly left open ("Business-level message handling beyond CONNECT_ACK... those are Plan C/D's job"). Group/channel-specific notify types, recall, delivery/read reports, and other `SubSignal`s from the full Android handler set are explicitly out of scope (Phase 2+).
- **Scope discovery during planning:** the original assumption (made when scoping Plan D conversationally) was that "message send/receive bridging" was a small finishing task. Reading the actual Android source revealed it's a real protocol subsystem in its own right — a non-protobuf binary ack format correlated by wire-level `messageId` (not `local_message_id`), and a notify-then-pull cycle (not direct push) for receiving. This is why this plan exists as its own deliverable rather than being folded into the App-shell-and-Login plan (Plan E) as first assumed.
- **`MessagingService`'s constructor has a side effect** (registering three handlers with `imClient`) — this is intentional and mirrors `AbstractProtoService`'s handler list being fixed for the lifetime of the service, but it does mean constructing a second `MessagingService` against the same `IMClient` would register duplicate handlers. Not a concern for Phase 1 (the app constructs exactly one of each), but worth a one-line guard or doc-comment warning if a future refactor risks double-construction (e.g. a dependency-injection container that isn't careful about singletons).
- **Image messages don't include a real upload step in this plan.** `sendImage` takes an already-uploaded `remoteURL` as a parameter — the actual MinIO/七牛 upload call (flagged as an open risk in the original migration design doc, §11 item 4) is Plan E/F's job, immediately before calling `sendImage`. This plan only handles the wire/storage half of image messages, not the upload.
- **No placeholders:** every step above has complete, runnable code; nothing is left as "TODO" or "similar to above."

