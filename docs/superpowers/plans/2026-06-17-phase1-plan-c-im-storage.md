# Phase 1 / Plan C: IMStorage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `IMStorage` — a GRDB-backed local persistence layer for messages, conversations, contacts, and sync state — that exposes Combine publishers for UI observation (Plan D) and is fully decoupled from `IMClient`/`IMTransport`/`IMProto` (testable in complete isolation).

**Architecture:** A new `IMStorage` SwiftPM target depending only on GRDB.swift (no protobuf, no networking). Flat, idiomatic GRDB `Codable` records map directly to SQLite columns — verified on this toolchain that `Int`-backed `Codable` enum properties round-trip through plain `INTEGER` columns with zero extra ceremony. `MessageContent` (text/image, the only two content types Phase 1 needs) is exposed as a Swift enum via a computed property layered over flat storage columns, not stored as a nested/blob structure. Each store (`MessageStore`, `ConversationStore`, `UserStore`, `SyncStateStore`) offers synchronous throwing CRUD plus a GRDB `ValueObservation` → Combine `publisher(in:)` for the lists Plan D's ViewModels will subscribe to.

**Tech Stack:** Swift 5.8+, GRDB.swift 6.x (SQLite wrapper + `Codable` records + `ValueObservation`), Combine (built into GRDB's `publisher(in:)` extension — no separate package needed).

**Scope boundary (read this before starting):** This plan builds the storage *layer* only. It does **not** build the `MessageHandler`s (`ReceiveMessageHandler`, `SendMessageHandler`, etc.) that parse incoming `Im_Message`/`Im_MessageContent` wire frames (from `IMProto`, Plan A) and call into these stores, nor the reverse (turning a composed `MessageContent` into an outgoing `Im_MessageContent` to send via `IMClient`, Plan B). That wire-format ↔ storage-format bridging is explicitly **Plan D's job** — see the "Reference facts" below for the exact wire-field mapping Plan D's handlers must replicate, recorded here because this plan's research is what uncovered it. Keeping that bridging out of `IMStorage` keeps this target dependency-free and independently testable, matching the precedent set by Plan A/B (small, decoupled, testable units).

**Reference facts this plan is built from** (verified by reading the actual Android source, the wire `.proto` definition, and by running real GRDB code on this toolchain — not assumed):
- **Android's actual on-disk schema is irrelevant to replicate byte-for-byte** (unlike Plan A/B's wire protocol work) — confirmed by reading `android-chat-pro/client/.../store/{ChatStoreHelper,SqliteDatabaseStore,ImMemoryStore}.java`: the real on-disk format is just two SQLite tables (`messages`, `conversations`) holding most data as Java-`ObjectOutputStream`-serialized BLOBs, with only a handful of indexed columns. This is a local-storage implementation detail with **no cross-platform compatibility requirement** (iOS's local DB never needs to interoperate with Android's local DB) — so this plan designs an idiomatic relational GRDB schema from the underlying *business model fields* instead (see below), not from Android's blob-serialization mechanism.
- **Business model fields**, read directly from `android-chat-pro/client/src/main/java/cn/wildfirechat/model/{ProtoMessage,ProtoConversationInfo,ProtoUserInfo,ProtoMessageContent,ProtoUnreadCount}.java`.
- **`ConversationType`** (`android-chat-pro/client/.../model/Conversation.java`): `Single=0, Group=1, ChatRoom=2, Channel=3`.
- **`MessageDirection`** (`.../message/core/MessageDirection.java`): `Send=0, Receive=1`.
- **`MessageStatus`** (`.../message/core/MessageStatus.java`): full enum is `Sending=0, Sent=1, Send_Failure=2, Mentioned=3, AllMentioned=4, Unread=5, Readed=6, Played=7`; this plan only needs `Sending=0, Sent=1, Send_Failure=2, Unread=5, Read=6` for Phase 1 (text/image, no mentions, no voice playback) — kept at the same raw values as Android for the subset that's in scope, the rest deliberately omitted (YAGNI, can be added in a later phase without a migration since it's purely additive).
- **`MessageContentType`** (`.../message/core/MessageContentType.java`): full enum has ~20 cases; this plan only needs `Text=1, Image=3`.
- **Wire-field mapping for text/image content** (`.../message/{TextMessageContent,ImageMessageContent,MediaMessageContent}.java`, cross-checked against the real wire definition `chat-proto/WFCMessage.proto`'s `MessageContent` message, which has 11 fields: `type, searchable_content, push_content, content, data, mediaType, remoteMediaUrl, persist_flag, expire_duration, mentioned_type, mentioned_target`):
  - Text messages: the body goes in `searchable_content` (not `content` — `TextMessageContent.encode()` sets `payload.searchableContent = content`).
  - Image messages: `searchable_content` holds a digest string (`"[图片]"`), `data` holds JPEG thumbnail bytes, `remoteMediaUrl` holds the uploaded image URL. `localMediaPath` is **not** a wire field at all — it's an Android-local-only concept (cached file path) carried in Android's local intermediate model, never sent over the wire. This plan's `mediaLocalPath` column mirrors that same local-only role.
  - This mapping is recorded for Plan D's wire-bridging handlers to replicate — `IMStorage` itself has zero `IMProto` dependency and never touches `Im_MessageContent` directly.
- **GRDB + Combine verified directly on this toolchain** (Xcode 15.2 / Swift 5.8): `import GRDB; import Combine` builds; `ValueObservation.tracking { ... }.publisher(in: dbQueue, scheduling: .immediate)` compiles and the initial value delivers correctly. An `Int`-backed `Codable` enum property on a `FetchableRecord`/`PersistableRecord` struct round-trips through a plain SQLite `INTEGER` column with **no** extra `DatabaseValueConvertible` conformance needed — verified empirically (`SELECT typeof(column)` returned `"integer"`, not `"text"`/`"blob"`, and the fetched value decoded back to the correct enum case).

---

## Task 1: Add the `IMStorage` SwiftPM target + GRDB dependency

**Files:**
- Modify: `Package.swift`
- Create: `Sources/IMStorage/_Scaffold.swift`
- Create: `Tests/IMStorageTests/_Scaffold.swift`

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
    ]
)
```

- [ ] **Step 2: Create placeholder source**

```bash
mkdir -p Sources/IMStorage Tests/IMStorageTests
echo "// IMStorage placeholder, removed in Task 2" > Sources/IMStorage/_Scaffold.swift
echo "// IMStorageTests placeholder, removed in Task 2" > Tests/IMStorageTests/_Scaffold.swift
```

- [ ] **Step 3: Build and test**

Run: `swift build`
Expected: resolves and builds GRDB (this is a sizeable dependency — first resolution can take a couple of minutes), ends with `Build complete!`

Run: `swift test`
Expected: all 71 previously-existing tests still pass (the two new targets have no real tests yet, count stays 71).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved Sources/IMStorage Tests/IMStorageTests
git commit -m "chore: scaffold IMStorage SwiftPM target with GRDB dependency"
```

---

## Task 2: `IMDatabase` — connection + schema migration

**Files:**
- Create: `Sources/IMStorage/IMDatabase.swift`
- Create: `Sources/IMStorage/MessageEnums.swift`
- Test: `Tests/IMStorageTests/IMDatabaseTests.swift`
- Modify: delete `Sources/IMStorage/_Scaffold.swift`, delete `Tests/IMStorageTests/_Scaffold.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMStorageTests/IMDatabaseTests.swift
import XCTest
import GRDB
@testable import IMStorage

final class IMDatabaseTests: XCTestCase {
    func test_openInMemory_createsAllFourTables() throws {
        let database = try IMDatabase.openInMemory()

        let tableNames: Set<String> = try database.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }

        XCTAssertTrue(tableNames.contains("message"))
        XCTAssertTrue(tableNames.contains("conversation"))
        XCTAssertTrue(tableNames.contains("user"))
        XCTAssertTrue(tableNames.contains("syncState"))
    }

    func test_openInMemory_runningMigrationTwiceIsHarmless() throws {
        // Simulates app relaunch: a fresh IMDatabase instance against the same
        // (here, file-backed) path must not fail because the schema already exists.
        let path = NSTemporaryDirectory() + "imdatabase-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try IMDatabase.open(atPath: path)
        let second = try IMDatabase.open(atPath: path) // must not throw

        let tableNames: Set<String> = try second.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        XCTAssertTrue(tableNames.contains("message"))
    }

    func test_messageIndexExists_forConversationPagination() throws {
        let database = try IMDatabase.openInMemory()

        let indexNames: [String] = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'message'")
        }

        XCTAssertTrue(indexNames.contains("message_on_conversation_timestamp"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter IMDatabaseTests`
Expected: FAIL with `error: cannot find type 'IMDatabase' in scope`

- [ ] **Step 3: Implement the domain enums**

```swift
// Sources/IMStorage/MessageEnums.swift

/// Matches `cn.wildfirechat.model.Conversation.ConversationType`'s raw values
/// (kept identical purely so anyone cross-referencing the Android source
/// isn't surprised — there is no wire/storage compatibility requirement
/// forcing this, local SQLite schemas don't need to match Android's).
public enum ConversationType: Int, Codable, Equatable {
    case single = 0
    case group = 1
    case chatRoom = 2
    case channel = 3
}

/// Matches `cn.wildfirechat.message.core.MessageDirection`.
public enum MessageDirection: Int, Codable, Equatable {
    case send = 0
    case receive = 1
}

/// Subset of `cn.wildfirechat.message.core.MessageStatus` needed for Phase 1
/// (text/image, no mentions, no voice playback). Raw values kept identical
/// to the Android subset in case a later phase needs the rest
/// (`Mentioned=3, AllMentioned=4, Played=7`) — adding them later is a
/// purely additive enum change, not a migration.
public enum MessageStatus: Int, Codable, Equatable {
    case sending = 0
    case sent = 1
    case sendFailure = 2
    case unread = 5
    case read = 6
}

/// Subset of `cn.wildfirechat.message.core.MessageContentType` needed for
/// Phase 1. The full Android enum has ~20 cases (voice, location, file,
/// video, group-management notifications, calls, etc.) — out of scope here.
public enum MessageContentType: Int, Codable, Equatable {
    case text = 1
    case image = 3
}
```

- [ ] **Step 4: Implement `IMDatabase`**

```swift
// Sources/IMStorage/IMDatabase.swift
import GRDB

/// Owns the SQLite connection and schema migration. Construct via
/// `open(atPath:)` (real file, for the app) or `openInMemory()` (tests).
public final class IMDatabase {
    public let dbQueue: DatabaseQueue

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    public static func open(atPath path: String) throws -> IMDatabase {
        try IMDatabase(dbQueue: DatabaseQueue(path: path))
    }

    public static func openInMemory() throws -> IMDatabase {
        try IMDatabase(dbQueue: DatabaseQueue())
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_createSchema") { db in
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("localMessageId", .integer).notNull()
                t.column("messageUid", .integer).notNull().defaults(to: 0)
                t.column("conversationType", .integer).notNull()
                t.column("target", .text).notNull()
                t.column("line", .integer).notNull().defaults(to: 0)
                t.column("from", .text).notNull()
                t.column("contentType", .integer).notNull()
                t.column("textContent", .text)
                t.column("searchableContent", .text)
                t.column("mediaRemoteURL", .text)
                t.column("mediaLocalPath", .text)
                t.column("mediaThumbnail", .blob)
                t.column("timestamp", .integer).notNull()
                t.column("status", .integer).notNull()
                t.column("direction", .integer).notNull()
            }
            try db.create(
                index: "message_on_conversation_timestamp",
                on: "message",
                columns: ["conversationType", "target", "line", "timestamp"]
            )
            try db.create(index: "message_on_local_message_id", on: "message", columns: ["localMessageId"])

            try db.create(table: "conversation") { t in
                t.column("conversationType", .integer).notNull()
                t.column("target", .text).notNull()
                t.column("line", .integer).notNull().defaults(to: 0)
                t.column("lastMessageUid", .integer)
                t.column("timestamp", .integer).notNull().defaults(to: 0)
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("isTop", .boolean).notNull().defaults(to: false)
                t.column("isMuted", .boolean).notNull().defaults(to: false)
                t.column("draft", .text)
                t.primaryKey(["conversationType", "target", "line"])
            }

            try db.create(table: "user") { t in
                t.column("uid", .text).notNull().primaryKey()
                t.column("name", .text)
                t.column("displayName", .text)
                t.column("portrait", .text)
                t.column("mobile", .text)
                t.column("gender", .integer).notNull().defaults(to: 0)
                t.column("updateDt", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "syncState") { t in
                t.column("id", .integer).notNull().primaryKey()
                t.column("msgHead", .integer).notNull().defaults(to: 0)
                t.column("friendHead", .integer).notNull().defaults(to: 0)
                t.column("friendRequestHead", .integer).notNull().defaults(to: 0)
                t.column("settingHead", .integer).notNull().defaults(to: 0)
            }
        }
        return migrator
    }
}
```

- [ ] **Step 5: Remove Task 1 scaffolding**

```bash
rm -f Sources/IMStorage/_Scaffold.swift Tests/IMStorageTests/_Scaffold.swift
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter IMDatabaseTests`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
git add Sources/IMStorage/IMDatabase.swift Sources/IMStorage/MessageEnums.swift Tests/IMStorageTests/IMDatabaseTests.swift
git add -u Sources/IMStorage Tests/IMStorageTests
git commit -m "feat(IMStorage): add IMDatabase connection + schema migration"
```

---

## Task 3: `MessageContent` + `StoredMessage` record

**Files:**
- Create: `Sources/IMStorage/StoredMessage.swift`
- Test: `Tests/IMStorageTests/StoredMessageTests.swift`

This task is pure in-memory struct logic — no database involved yet (that's Task 4).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMStorageTests/StoredMessageTests.swift
import XCTest
import Foundation
@testable import IMStorage

final class StoredMessageTests: XCTestCase {
    func test_textMessage_initFlattensContentAndSetsSearchableContent() {
        let message = StoredMessage(
            localMessageId: 1,
            conversationType: .single,
            target: "u2",
            from: "u1",
            content: .text("hello"),
            timestamp: 1_000,
            status: .sent,
            direction: .send
        )

        XCTAssertEqual(message.contentType, .text)
        XCTAssertEqual(message.textContent, "hello")
        XCTAssertEqual(message.searchableContent, "hello")
        XCTAssertNil(message.mediaRemoteURL)
        XCTAssertNil(message.mediaLocalPath)
        XCTAssertNil(message.mediaThumbnail)
    }

    func test_textMessage_contentComputedPropertyRoundTrips() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hello"), timestamp: 1_000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.content, .text("hello"))
    }

    func test_imageMessage_initFlattensContentAndSetsDigestSearchableContent() {
        let thumbnail = Data([0x01, 0x02, 0x03])
        let message = StoredMessage(
            localMessageId: 2,
            conversationType: .single,
            target: "u2",
            from: "u1",
            content: .image(thumbnail: thumbnail, remoteURL: "https://example.com/a.jpg", localPath: "/tmp/a.jpg"),
            timestamp: 1_000,
            status: .sent,
            direction: .send
        )

        XCTAssertEqual(message.contentType, .image)
        XCTAssertNil(message.textContent)
        XCTAssertEqual(message.searchableContent, "[图片]")
        XCTAssertEqual(message.mediaThumbnail, thumbnail)
        XCTAssertEqual(message.mediaRemoteURL, "https://example.com/a.jpg")
        XCTAssertEqual(message.mediaLocalPath, "/tmp/a.jpg")
    }

    func test_imageMessage_contentComputedPropertyRoundTrips() {
        let thumbnail = Data([0x01, 0x02, 0x03])
        let message = StoredMessage(
            localMessageId: 2, conversationType: .single, target: "u2", from: "u1",
            content: .image(thumbnail: thumbnail, remoteURL: "https://example.com/a.jpg", localPath: "/tmp/a.jpg"),
            timestamp: 1_000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.content, .image(thumbnail: thumbnail, remoteURL: "https://example.com/a.jpg", localPath: "/tmp/a.jpg"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StoredMessageTests`
Expected: FAIL with `error: cannot find type 'StoredMessage' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMStorage/StoredMessage.swift
import GRDB
import Foundation

/// The only two content types Phase 1 needs. Mirrors the wire-field mapping
/// documented at the top of this plan (text → `searchable_content`; image →
/// `searchable_content` digest + `data` thumbnail + `remoteMediaUrl`) —
/// `IMStorage` itself never touches the wire `Im_MessageContent` type;
/// Plan D's handlers are responsible for that conversion in both directions.
public enum MessageContent: Equatable {
    case text(String)
    case image(thumbnail: Data?, remoteURL: String?, localPath: String?)
}

public struct StoredMessage: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "message"

    public var id: Int64?
    public var localMessageId: Int64
    public var messageUid: Int64
    public var conversationType: ConversationType
    public var target: String
    public var line: Int
    public var from: String
    public var contentType: MessageContentType
    public var textContent: String?
    public var searchableContent: String?
    public var mediaRemoteURL: String?
    public var mediaLocalPath: String?
    public var mediaThumbnail: Data?
    public var timestamp: Int64
    public var status: MessageStatus
    public var direction: MessageDirection

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Reassembles `MessageContent` from the flat storage columns.
    public var content: MessageContent {
        switch contentType {
        case .text:
            return .text(textContent ?? "")
        case .image:
            return .image(thumbnail: mediaThumbnail, remoteURL: mediaRemoteURL, localPath: mediaLocalPath)
        }
    }

    public init(
        id: Int64? = nil,
        localMessageId: Int64,
        messageUid: Int64 = 0,
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        from: String,
        content: MessageContent,
        timestamp: Int64,
        status: MessageStatus,
        direction: MessageDirection
    ) {
        self.id = id
        self.localMessageId = localMessageId
        self.messageUid = messageUid
        self.conversationType = conversationType
        self.target = target
        self.line = line
        self.from = from
        self.timestamp = timestamp
        self.status = status
        self.direction = direction
        switch content {
        case .text(let text):
            contentType = .text
            textContent = text
            searchableContent = text
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
        case .image(let thumbnail, let remoteURL, let localPath):
            contentType = .image
            textContent = nil
            searchableContent = "[图片]"
            mediaRemoteURL = remoteURL
            mediaLocalPath = localPath
            mediaThumbnail = thumbnail
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StoredMessageTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/StoredMessage.swift Tests/IMStorageTests/StoredMessageTests.swift
git commit -m "feat(IMStorage): add MessageContent enum and StoredMessage record"
```

---

## Task 4: `MessageStore`

**Files:**
- Create: `Sources/IMStorage/MessageStore.swift`
- Test: `Tests/IMStorageTests/MessageStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMStorageTests/MessageStoreTests.swift
import XCTest
@testable import IMStorage

final class MessageStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: MessageStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = MessageStore(dbQueue: database.dbQueue)
    }

    private func makeMessage(localMessageId: Int64, target: String = "u2", timestamp: Int64 = 1_000, text: String = "hi") -> StoredMessage {
        StoredMessage(
            localMessageId: localMessageId, conversationType: .single, target: target, from: "u1",
            content: .text(text), timestamp: timestamp, status: .sending, direction: .send
        )
    }

    func test_insert_assignsAutoIncrementedId() throws {
        let inserted = try store.insert(makeMessage(localMessageId: 1))
        XCTAssertNotNil(inserted.id)
    }

    func test_messageByLocalId_findsInsertedMessage() throws {
        try store.insert(makeMessage(localMessageId: 42, text: "find me"))

        let found = try store.message(localMessageId: 42)

        XCTAssertEqual(found?.content, .text("find me"))
    }

    func test_messageByLocalId_returnsNilWhenNotFound() throws {
        XCTAssertNil(try store.message(localMessageId: 999))
    }

    func test_messagesForConversation_returnsNewestFirst() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "first"))
        try store.insert(makeMessage(localMessageId: 2, timestamp: 3_000, text: "third"))
        try store.insert(makeMessage(localMessageId: 3, timestamp: 2_000, text: "second"))

        let messages = try store.messages(conversationType: .single, target: "u2")

        XCTAssertEqual(messages.map { $0.content }, [.text("third"), .text("second"), .text("first")])
    }

    func test_messagesForConversation_onlyReturnsMatchingTarget() throws {
        try store.insert(makeMessage(localMessageId: 1, target: "u2", text: "for u2"))
        try store.insert(makeMessage(localMessageId: 2, target: "u3", text: "for u3"))

        let messages = try store.messages(conversationType: .single, target: "u2")

        XCTAssertEqual(messages.map { $0.content }, [.text("for u2")])
    }

    func test_messagesForConversation_respectsLimit() throws {
        for i in 0..<5 {
            try store.insert(makeMessage(localMessageId: Int64(i), timestamp: Int64(i), text: "msg\(i)"))
        }

        let messages = try store.messages(conversationType: .single, target: "u2", limit: 2)

        XCTAssertEqual(messages.count, 2)
    }

    func test_updateStatus_changesStatusOfMatchingLocalMessageId() throws {
        try store.insert(makeMessage(localMessageId: 7))

        try store.updateStatus(localMessageId: 7, status: .sendFailure)

        XCTAssertEqual(try store.message(localMessageId: 7)?.status, .sendFailure)
    }

    func test_updateMessageUid_setsServerAssignedUidWithoutChangingContent() throws {
        try store.insert(makeMessage(localMessageId: 7, text: "keep me"))

        try store.updateMessageUid(localMessageId: 7, messageUid: 123_456)

        let updated = try store.message(localMessageId: 7)
        XCTAssertEqual(updated?.messageUid, 123_456)
        XCTAssertEqual(updated?.content, .text("keep me"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MessageStoreTests`
Expected: FAIL with `error: cannot find type 'MessageStore' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMStorage/MessageStore.swift
import GRDB

/// CRUD for `StoredMessage`. `message(localMessageId:)` is the dedup lookup
/// a future `SendMessageHandler` (Plan D) needs after reconnecting, per the
/// migration design doc's `local_message_id` flow.
public final class MessageStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    @discardableResult
    public func insert(_ message: StoredMessage) throws -> StoredMessage {
        var message = message
        try dbQueue.write { db in try message.insert(db) }
        return message
    }

    public func message(localMessageId: Int64) throws -> StoredMessage? {
        try dbQueue.read { db in
            try StoredMessage.filter(Column("localMessageId") == localMessageId).fetchOne(db)
        }
    }

    public func messages(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        limit: Int = 50
    ) throws -> [StoredMessage] {
        try dbQueue.read { db in
            try StoredMessage
                .filter(Column("conversationType") == conversationType.rawValue)
                .filter(Column("target") == target)
                .filter(Column("line") == line)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func updateStatus(localMessageId: Int64, status: MessageStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE message SET status = ? WHERE localMessageId = ?",
                arguments: [status.rawValue, localMessageId]
            )
        }
    }

    public func updateMessageUid(localMessageId: Int64, messageUid: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE message SET messageUid = ? WHERE localMessageId = ?",
                arguments: [messageUid, localMessageId]
            )
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MessageStoreTests`
Expected: `Executed 8 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/MessageStoreTests.swift
git commit -m "feat(IMStorage): add MessageStore CRUD"
```

---

## Task 5: `StoredConversation` + `ConversationStore` (with Combine observation)

**Files:**
- Create: `Sources/IMStorage/StoredConversation.swift`
- Create: `Sources/IMStorage/ConversationStore.swift`
- Test: `Tests/IMStorageTests/ConversationStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMStorageTests/ConversationStoreTests.swift
import XCTest
import Combine
@testable import IMStorage

final class ConversationStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: ConversationStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = ConversationStore(dbQueue: database.dbQueue)
        cancellables = []
    }

    func test_recordIncomingMessage_createsConversationIfMissing() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true)

        let conversation = try store.conversation(conversationType: .single, target: "u2")
        XCTAssertEqual(conversation?.lastMessageUid, 10)
        XCTAssertEqual(conversation?.timestamp, 1_000)
        XCTAssertEqual(conversation?.unreadCount, 1)
    }

    func test_recordIncomingMessage_updatesExistingConversationAndAccumulatesUnread() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true)
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 11, timestamp: 2_000, incrementUnread: true)

        let conversation = try store.conversation(conversationType: .single, target: "u2")
        XCTAssertEqual(conversation?.lastMessageUid, 11)
        XCTAssertEqual(conversation?.timestamp, 2_000)
        XCTAssertEqual(conversation?.unreadCount, 2)
    }

    func test_recordIncomingMessage_withIncrementUnreadFalse_doesNotChangeUnreadCount() throws {
        // e.g. recording my own sent message — shouldn't mark my own conversation unread
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: false)

        XCTAssertEqual(try store.conversation(conversationType: .single, target: "u2")?.unreadCount, 0)
    }

    func test_clearUnread_resetsCountToZero() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true)

        try store.clearUnread(conversationType: .single, target: "u2", line: 0)

        XCTAssertEqual(try store.conversation(conversationType: .single, target: "u2")?.unreadCount, 0)
    }

    func test_setDraft_storesDraftText() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: false)

        try store.setDraft("unsent text", conversationType: .single, target: "u2", line: 0)

        XCTAssertEqual(try store.conversation(conversationType: .single, target: "u2")?.draft, "unsent text")
    }

    func test_conversations_ordersByTimestampDescending() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "older", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
        try store.recordIncomingMessage(conversationType: .single, target: "newer", line: 0, messageUid: 2, timestamp: 2_000, incrementUnread: false)

        let conversations = try store.conversations()

        XCTAssertEqual(conversations.map { $0.target }, ["newer", "older"])
    }

    func test_conversationsPublisher_emitsOnInsertAndOnUpdate() throws {
        var receivedCounts: [Int] = []
        let expectation = expectation(description: "received at least 2 updates")
        expectation.expectedFulfillmentCount = 2

        store.conversationsPublisher()
            .sink(receiveCompletion: { _ in }, receiveValue: { conversations in
                receivedCounts.append(conversations.count)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(receivedCounts, [0, 1]) // initial empty list, then one conversation
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConversationStoreTests`
Expected: FAIL with `error: cannot find type 'ConversationStore' in scope`

- [ ] **Step 3: Implement the record**

```swift
// Sources/IMStorage/StoredConversation.swift
import GRDB

public struct StoredConversation: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversation"

    public var conversationType: ConversationType
    public var target: String
    public var line: Int
    public var lastMessageUid: Int64?
    public var timestamp: Int64
    public var unreadCount: Int
    public var isTop: Bool
    public var isMuted: Bool
    public var draft: String?

    public init(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        lastMessageUid: Int64? = nil,
        timestamp: Int64 = 0,
        unreadCount: Int = 0,
        isTop: Bool = false,
        isMuted: Bool = false,
        draft: String? = nil
    ) {
        self.conversationType = conversationType
        self.target = target
        self.line = line
        self.lastMessageUid = lastMessageUid
        self.timestamp = timestamp
        self.unreadCount = unreadCount
        self.isTop = isTop
        self.isMuted = isMuted
        self.draft = draft
    }
}
```

- [ ] **Step 4: Implement the store**

```swift
// Sources/IMStorage/ConversationStore.swift
import GRDB
import Combine

/// CRUD + Combine observation for `StoredConversation`. The "conversation
/// list" screen (Plan D) subscribes to `conversationsPublisher()`.
public final class ConversationStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func conversation(conversationType: ConversationType, target: String, line: Int = 0) throws -> StoredConversation? {
        try dbQueue.read { db in
            try StoredConversation
                .filter(Column("conversationType") == conversationType.rawValue)
                .filter(Column("target") == target)
                .filter(Column("line") == line)
                .fetchOne(db)
        }
    }

    public func conversations() throws -> [StoredConversation] {
        try dbQueue.read { db in
            try StoredConversation.order(Column("timestamp").desc).fetchAll(db)
        }
    }

    public func conversationsPublisher() -> AnyPublisher<[StoredConversation], Error> {
        ValueObservation
            .tracking { db in try StoredConversation.order(Column("timestamp").desc).fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    /// Upserts the conversation row for an incoming or outgoing message:
    /// updates `lastMessageUid`/`timestamp`, and optionally bumps
    /// `unreadCount` (callers pass `incrementUnread: false` when recording
    /// their own sent message — it shouldn't mark their own conversation
    /// unread).
    public func recordIncomingMessage(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        messageUid: Int64,
        timestamp: Int64,
        incrementUnread: Bool
    ) throws {
        try dbQueue.write { db in
            let existing = try StoredConversation
                .filter(Column("conversationType") == conversationType.rawValue)
                .filter(Column("target") == target)
                .filter(Column("line") == line)
                .fetchOne(db)

            var conversation = existing ?? StoredConversation(conversationType: conversationType, target: target, line: line)
            conversation.lastMessageUid = messageUid
            conversation.timestamp = timestamp
            if incrementUnread {
                conversation.unreadCount += 1
            }
            try conversation.save(db)
        }
    }

    public func clearUnread(conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET unreadCount = 0 WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [conversationType.rawValue, target, line]
            )
        }
    }

    public func setDraft(_ draft: String?, conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET draft = ? WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [draft, conversationType.rawValue, target, line]
            )
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ConversationStoreTests`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMStorage/StoredConversation.swift Sources/IMStorage/ConversationStore.swift Tests/IMStorageTests/ConversationStoreTests.swift
git commit -m "feat(IMStorage): add StoredConversation record and ConversationStore with Combine observation"
```

---

## Task 6: `StoredUser` + `UserStore`

**Files:**
- Create: `Sources/IMStorage/StoredUser.swift`
- Create: `Sources/IMStorage/UserStore.swift`
- Test: `Tests/IMStorageTests/UserStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMStorageTests/UserStoreTests.swift
import XCTest
import Combine
@testable import IMStorage

final class UserStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: UserStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = UserStore(dbQueue: database.dbQueue)
        cancellables = []
    }

    func test_upsert_thenFetchByUid_returnsStoredUser() throws {
        try store.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice", portrait: nil, mobile: "13800000000", gender: 0, updateDt: 1))

        let fetched = try store.user(uid: "u1")

        XCTAssertEqual(fetched?.displayName, "Alice")
    }

    func test_upsert_sameUidTwice_updatesRatherThanDuplicates() throws {
        try store.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 1))
        try store.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice Updated", portrait: nil, mobile: nil, gender: 0, updateDt: 2))

        XCTAssertEqual(try store.allUsers().count, 1)
        XCTAssertEqual(try store.user(uid: "u1")?.displayName, "Alice Updated")
    }

    func test_allUsers_sortedByDisplayName() throws {
        try store.upsert(StoredUser(uid: "u1", name: "bob", displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 1))
        try store.upsert(StoredUser(uid: "u2", name: "alice", displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 1))

        let users = try store.allUsers()

        XCTAssertEqual(users.map { $0.displayName }, ["Alice", "Bob"])
    }

    func test_usersPublisher_emitsOnUpsert() throws {
        var receivedCounts: [Int] = []
        let expectation = expectation(description: "received at least 2 updates")
        expectation.expectedFulfillmentCount = 2

        store.usersPublisher()
            .sink(receiveCompletion: { _ in }, receiveValue: { users in
                receivedCounts.append(users.count)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 1))

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(receivedCounts, [0, 1])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UserStoreTests`
Expected: FAIL with `error: cannot find type 'UserStore' in scope`

- [ ] **Step 3: Implement the record**

```swift
// Sources/IMStorage/StoredUser.swift
import GRDB

/// Static contact-list cache. Only the fields Phase 1's contact list and
/// message sender display actually need (`name`, `displayName`, `portrait`,
/// `mobile`, `gender`, `updateDt`) — `ProtoUserInfo`'s richer profile fields
/// (`email`, `address`, `company`, `social`, `extra`, `friendAlias`,
/// `groupAlias`) are deliberately omitted (YAGNI); add them later if a
/// future phase's profile screen needs them — purely additive, no migration
/// of existing columns required.
public struct StoredUser: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "user"

    public var uid: String
    public var name: String?
    public var displayName: String?
    public var portrait: String?
    public var mobile: String?
    public var gender: Int
    public var updateDt: Int64

    public init(uid: String, name: String?, displayName: String?, portrait: String?, mobile: String?, gender: Int, updateDt: Int64) {
        self.uid = uid
        self.name = name
        self.displayName = displayName
        self.portrait = portrait
        self.mobile = mobile
        self.gender = gender
        self.updateDt = updateDt
    }
}
```

- [ ] **Step 4: Implement the store**

```swift
// Sources/IMStorage/UserStore.swift
import GRDB
import Combine

public final class UserStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ user: StoredUser) throws {
        try dbQueue.write { db in try user.save(db) }
    }

    public func user(uid: String) throws -> StoredUser? {
        try dbQueue.read { db in try StoredUser.fetchOne(db, key: uid) }
    }

    public func allUsers() throws -> [StoredUser] {
        try dbQueue.read { db in
            try StoredUser.order(Column("displayName")).fetchAll(db)
        }
    }

    public func usersPublisher() -> AnyPublisher<[StoredUser], Error> {
        ValueObservation
            .tracking { db in try StoredUser.order(Column("displayName")).fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter UserStoreTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMStorage/StoredUser.swift Sources/IMStorage/UserStore.swift Tests/IMStorageTests/UserStoreTests.swift
git commit -m "feat(IMStorage): add StoredUser record and UserStore"
```

---

## Task 7: `StoredSyncState` + `SyncStateStore`

**Files:**
- Create: `Sources/IMStorage/SyncStateStore.swift`
- Test: `Tests/IMStorageTests/SyncStateStoreTests.swift`

Single-row table — keyed by a fixed `id = 1`, since this app supports one logged-in account per device at a time (no multi-account switching observed anywhere in the Android reference).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMStorageTests/SyncStateStoreTests.swift
import XCTest
@testable import IMStorage

final class SyncStateStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: SyncStateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = SyncStateStore(dbQueue: database.dbQueue)
    }

    func test_get_beforeAnySet_returnsAllZeros() throws {
        let state = try store.get()
        XCTAssertEqual(state, StoredSyncState(msgHead: 0, friendHead: 0, friendRequestHead: 0, settingHead: 0))
    }

    func test_set_thenGet_returnsWhatWasSet() throws {
        try store.set(StoredSyncState(msgHead: 100, friendHead: 5, friendRequestHead: 2, settingHead: 3))

        XCTAssertEqual(try store.get(), StoredSyncState(msgHead: 100, friendHead: 5, friendRequestHead: 2, settingHead: 3))
    }

    func test_set_calledTwice_overwritesRatherThanDuplicating() throws {
        try store.set(StoredSyncState(msgHead: 100, friendHead: 5, friendRequestHead: 2, settingHead: 3))
        try store.set(StoredSyncState(msgHead: 200, friendHead: 6, friendRequestHead: 3, settingHead: 4))

        XCTAssertEqual(try store.get(), StoredSyncState(msgHead: 200, friendHead: 6, friendRequestHead: 3, settingHead: 4))

        let rowCount = try database.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState") }
        XCTAssertEqual(rowCount, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SyncStateStoreTests`
Expected: FAIL with `error: cannot find type 'SyncStateStore' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMStorage/SyncStateStore.swift
import GRDB

/// Mirrors `ConnectAckPayload`'s sync-head fields (`msg_head`, `friend_head`,
/// `friend_rq_head`, `setting_head`) — see `ConnectAckHandler` (Plan B). A
/// future Plan D handler reads/writes this to drive incremental sync after
/// reconnecting.
public struct StoredSyncState: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "syncState"

    public var id: Int = 1
    public var msgHead: Int64
    public var friendHead: Int64
    public var friendRequestHead: Int64
    public var settingHead: Int64

    public init(msgHead: Int64, friendHead: Int64, friendRequestHead: Int64, settingHead: Int64) {
        self.msgHead = msgHead
        self.friendHead = friendHead
        self.friendRequestHead = friendRequestHead
        self.settingHead = settingHead
    }
}

public final class SyncStateStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func get() throws -> StoredSyncState {
        try dbQueue.read { db in
            try StoredSyncState.fetchOne(db, key: 1) ?? StoredSyncState(msgHead: 0, friendHead: 0, friendRequestHead: 0, settingHead: 0)
        }
    }

    public func set(_ state: StoredSyncState) throws {
        var state = state
        state.id = 1
        try dbQueue.write { db in try state.save(db) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SyncStateStoreTests`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/SyncStateStore.swift Tests/IMStorageTests/SyncStateStoreTests.swift
git commit -m "feat(IMStorage): add StoredSyncState record and SyncStateStore"
```

---

## Task 8: `IMStorage` facade

**Files:**
- Create: `Sources/IMStorage/IMStorage.swift`
- Test: `Tests/IMStorageTests/IMStorageTests.swift`

Ties the database + four stores together behind one entry point, so Plan D only needs to construct one object.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMStorageTests/IMStorageTests.swift
import XCTest
@testable import IMStorage

final class IMStorageTests: XCTestCase {
    func test_openInMemory_exposesAllFourStoresSharingTheSameDatabase() throws {
        let storage = try IMStorage.openInMemory()

        // Round-trip through each store to prove they all see the same
        // underlying connection (not four independent, disconnected databases).
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send
        ))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)
        try storage.users.upsert(StoredUser(uid: "u2", name: "bob", displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 1))
        try storage.syncState.set(StoredSyncState(msgHead: 1, friendHead: 0, friendRequestHead: 0, settingHead: 0))

        XCTAssertEqual(try storage.messages.message(localMessageId: 1)?.content, .text("hi"))
        XCTAssertEqual(try storage.conversations.conversation(conversationType: .single, target: "u2")?.unreadCount, 1)
        XCTAssertEqual(try storage.users.user(uid: "u2")?.displayName, "Bob")
        XCTAssertEqual(try storage.syncState.get().msgHead, 1)
    }

    func test_openAtPath_persistsAcrossInstances() throws {
        let path = NSTemporaryDirectory() + "imstorage-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try IMStorage.open(atPath: path)
        try first.users.upsert(StoredUser(uid: "u1", name: "alice", displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 1))

        let second = try IMStorage.open(atPath: path)
        XCTAssertEqual(try second.users.user(uid: "u1")?.displayName, "Alice")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter IMStorageTests`
Expected: FAIL with `error: cannot find type 'IMStorage' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMStorage/IMStorage.swift

/// Single entry point: construct one `IMStorage`, get all four stores
/// sharing the same underlying SQLite connection.
public final class IMStorage {
    public let messages: MessageStore
    public let conversations: ConversationStore
    public let users: UserStore
    public let syncState: SyncStateStore

    private init(database: IMDatabase) {
        messages = MessageStore(dbQueue: database.dbQueue)
        conversations = ConversationStore(dbQueue: database.dbQueue)
        users = UserStore(dbQueue: database.dbQueue)
        syncState = SyncStateStore(dbQueue: database.dbQueue)
    }

    public static func open(atPath path: String) throws -> IMStorage {
        IMStorage(database: try IMDatabase.open(atPath: path))
    }

    public static func openInMemory() throws -> IMStorage {
        IMStorage(database: try IMDatabase.openInMemory())
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter IMStorageTests`
Expected: `Executed 2 tests, with 0 failures`

- [ ] **Step 5: Run the entire suite one final time**

Run: `swift test`
Expected: all tests pass (Plan A's 23 + Plan B's 48 + Plan C's new tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/IMStorage/IMStorage.swift Tests/IMStorageTests/IMStorageTests.swift
git commit -m "feat(IMStorage): add IMStorage facade tying database and stores together"
```

---

## Plan Self-Review Notes

- **Spec coverage:** This plan implements migration-design-doc §6 (`IMStorage` data layer architecture: messages/conversations/users/sync_state tables, GRDB `ValueObservation` for Combine-driven UI updates) for the Phase 1 scope (text + image messages, single-chat, static contact list). Groups/channels/friend-requests are explicitly out of scope (Phase 2+), reflected in the trimmed `MessageStatus`/`MessageContentType` enums and the absence of a `groups`/`group_members` table — adding those later is additive (new tables, new enum cases), not a breaking migration.
- **Who builds the wire ↔ storage bridge:** This plan's "Scope boundary" section (top of file) is the single source of truth: `IMStorage` has zero `IMProto`/`IMClient` dependency by design, so it's independently testable. The `ReceiveMessageHandler`/`SendMessageHandler` that actually call into these stores from real wire frames are Plan D's responsibility. The exact wire-field mapping Plan D needs (text → `searchable_content`; image → `searchable_content` digest + `data` thumbnail + `remoteMediaUrl`, `localMediaPath` is local-only) is recorded in this plan's "Reference facts" section specifically so that research doesn't need to be redone.
- **Local SQLite schema deliberately does NOT mirror Android's on-disk format.** Investigated and confirmed via `ChatStoreHelper.java`: Android stores `messages`/`conversations` as two tables with most data as Java-serialized BLOBs. There is no cross-platform local-storage compatibility requirement (unlike the wire protocol in Plan A/B, which two different OSes' clients must literally interoperate over), so this plan designs a normal relational schema from the business model fields instead. This is a deliberate, justified deviation from the "byte-for-byte port" philosophy that governed Plan A/B — flagged explicitly here so it doesn't read as an oversight.
- **`ValueObservation.publisher(in:scheduling:)` uses `.immediate`, not the default `.async(onQueue: .main)`.** Verified directly on this toolchain: in a plain command-line harness (no run loop being pumped), `.async(onQueue: .main)` never delivered any value because nothing pumps the main `DispatchQueue` outside a real app's run loop — `.immediate` delivers the initial value synchronously on subscribe and subsequent values synchronously from the writer, which is what this plan's tests rely on (see `wait(for:timeout:)` usage in `ConversationStoreTests`/`UserStoreTests`, which still needs the expectation pattern because the *write* that triggers the second emission happens after subscribing, not because delivery is `.async` to a different queue). Plan D, building real UI on top of this, should keep using `.immediate` for the same reason: a UIKit app's main run loop is pumped, but `.immediate` is simpler to reason about and avoids a round-trip through the run loop for what's already a same-thread write-then-notify in GRDB's default `DatabaseQueue` setup. If a future profiling pass finds this blocks the main thread under heavy write load, that's the seam to revisit (switch to `.async` + a real run loop, or move writes to a background `DatabaseQueue`).
- **No placeholders:** every step above has complete, runnable code; nothing is left as "TODO" or "similar to above."
