# Phase 3 一对一音视频通话 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现一对一语音/视频通话:复用现有 IM 消息通道做信令(wire type 400-404),新增 `IMCall` 包承载状态机与 WebRTC/CallKit 集成,`IMKit`/`App` 新增拨号中/通话中界面。

**Architecture:** 信令层(`IMStorage`/`IMMessaging`)新增 5 个 `MessageContentType`,400(CallStart)走现有持久化路径产出会话气泡,401-404(Answer/Bye/Signal/Modify)绕开持久化直接转发给新建的 `IMCall` 包消费。`IMCall` 内部:`CallSignalCodec` 编解码,`CallSession`/`CallState` 纯数据,`CallManager` 是唯一的状态机+协调入口,通过 `MediaEngine` 协议与真实 WebRTC 实现解耦(测试用 fake,生产用 `WebRTCClient` 包真实的 `WebRTC.framework`),通过 `CallKitAdapting` 协议与 App target 的 `CXProvider` 解耦。`IMKit` 新增 ViewModel,`App` 新增 `OutgoingCallViewController`/`InCallViewController`。

**Tech Stack:** Swift 5.8 / SPM / GRDB / Combine / `stasel/WebRTC`(SPM XCFramework)/ CallKit / AVFoundation。

---

## 参考文档

- 设计文档:`docs/superpowers/specs/2026-06-23-phase3-av-call-design.md`
- 现有约定参考:`Sources/IMMessaging/MessageContentCodec.swift`、`Sources/IMMessaging/ReceiveMessageHandler.swift`、`Sources/IMMessaging/MessagingService.swift`、`Sources/IMStorage/StoredMessage.swift`、`Sources/IMStorage/MessageStore.swift`、`Sources/IMStorage/IMDatabase.swift`、`Sources/IMClient/Scheduler.swift`(`Scheduler`/`ManualScheduler`,本计划的 60s 超时定时器复用这个抽象)

## Task 1: `MessageContentType.callStart` + `MessageContent.callRecord` 存储表示

**Files:**
- Modify: `Sources/IMStorage/MessageEnums.swift`
- Modify: `Sources/IMStorage/StoredMessage.swift`
- Modify: `Sources/IMStorage/IMDatabase.swift`
- Test: `Tests/IMStorageTests/StoredMessageTests.swift`

- [ ] **Step 1: 写失败的测试(StoredMessage 新 case 的 init/content round-trip)**

在 `Tests/IMStorageTests/StoredMessageTests.swift` 末尾(`StoredMessageContentTests` 类内,`test_mentionFields_defaultToEmptyAndRoundTrip` 之后)追加:

```swift
    func test_callRecordContent_roundTripsThroughInit() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .callRecord(callId: "call-1", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0),
            timestamp: 1000, status: .sending, direction: .send
        )
        XCTAssertEqual(message.contentType, .callStart)
        XCTAssertEqual(message.searchableContent, "[视频通话]")
        XCTAssertEqual(message.content, .callRecord(callId: "call-1", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
    }

    func test_callRecordContent_audioOnlyUsesVoiceDigest() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .callRecord(callId: "call-1", targetId: "u2", audioOnly: true, status: 2, connectTime: 5_000, endTime: 65_000),
            timestamp: 1000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.searchableContent, "[语音通话]")
        XCTAssertEqual(message.content, .callRecord(callId: "call-1", targetId: "u2", audioOnly: true, status: 2, connectTime: 5_000, endTime: 65_000))
    }

    func test_textMessage_callFieldsStayAtDefaults() {
        // A non-call message must not leak stale values into the new
        // call-record columns — guards the `setContent` refactor in Task 1.
        let message = StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hi"), timestamp: 1000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.callId, nil)
        XCTAssertEqual(message.callTargetId, nil)
        XCTAssertEqual(message.callAudioOnly, false)
        XCTAssertEqual(message.callStatus, 0)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter StoredMessageTests`
Expected: FAIL — `MessageContent` 没有 `.callRecord` case,`MessageContentType` 没有 `.callStart`,`StoredMessage` 没有 `callId`/`callTargetId`/`callAudioOnly`/`callStatus` 属性,编译错误。

- [ ] **Step 3: `MessageEnums.swift` 新增 `callStart` case**

在 `Sources/IMStorage/MessageEnums.swift` 的 `MessageContentType` 里追加(紧跟 `changeGroupPortrait` 之后):

```swift
public enum MessageContentType: Int, Codable, Equatable {
    case text = 1
    case image = 3
    case createGroup = 104
    case addGroupMember = 105
    case kickoffGroupMember = 106
    case quitGroup = 107
    case dismissGroup = 108
    case changeGroupName = 110
    case changeGroupPortrait = 112
    /// Matches Android `cn.wildfirechat.message.CallStartMessageContent`'s
    /// `ContentType_Call_Start`(400) — the only one of the 6 call-signaling
    /// types (400-405) that persists/displays as a chat bubble; 401-404 are
    /// transient and never reach `IMStorage` (see `ReceiveMessageHandler`).
    case callStart = 400
}
```

- [ ] **Step 4: `StoredMessage.swift` 新增 `.callRecord` case + 列 + `setContent` 重构**

整个文件按以下内容替换(把现有的 inline 赋值逻辑搬进新的 `setContent(_:)`,`init` 改成"先填占位值再调用 `setContent`",这样 Task 2 的 `updateContent` 能复用同一份逻辑,不用抄第二份):

```swift
import GRDB
import Foundation

/// Mirrors the wire-field mapping documented at the top of this file: text →
/// `searchable_content`; image → `searchable_content` digest + `data`
/// thumbnail + `remoteMediaUrl`; group notifications → decoded purely for
/// display (never re-encoded — the client never constructs `notify_content`
/// itself; see `MessageContentCodec`'s doc comment). `IMStorage` itself never
/// touches the wire `Im_MessageContent` type — `IMMessaging`'s handlers are
/// responsible for that conversion.
public enum MessageContent: Equatable {
    case text(String)
    case image(thumbnail: Data?, remoteURL: String?, localPath: String?)
    /// `type` is always one of the 7 group-notification `MessageContentType`
    /// cases. `value` carries the new group name for `.changeGroupName`,
    /// `nil` otherwise. `memberUids` carries the affected member list for
    /// `.createGroup`/`.addGroupMember`/`.kickoffGroupMember`, empty
    /// otherwise.
    case groupNotification(type: MessageContentType, operatorUid: String, memberUids: [String], value: String?)
    /// Wire type 400 (`CallStart`, see Phase 3 design doc §2). `status`:
    /// 0=未接听/1=通话中/2=已结束, matching Android's `CallStartMessageContent`.
    /// `connectTime`/`endTime` are 0 until the call actually connects/ends —
    /// `IMCall.CallManager` updates this in place via `MessageStore.updateContent`
    /// as the call progresses, it is never re-sent over the wire after the
    /// initial invite.
    case callRecord(callId: String, targetId: String, audioOnly: Bool, status: Int, connectTime: Int64, endTime: Int64)
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
    public var mentionedType: Int
    public var mentionedTargetsRaw: String?
    public var groupNotificationOperator: String?
    public var groupNotificationMembersRaw: String?
    public var groupNotificationValue: String?
    public var callId: String?
    public var callTargetId: String?
    public var callAudioOnly: Bool
    public var callStatus: Int
    public var callConnectTime: Int64
    public var callEndTime: Int64

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
        case .createGroup, .addGroupMember, .kickoffGroupMember, .quitGroup, .dismissGroup, .changeGroupName, .changeGroupPortrait:
            return .groupNotification(
                type: contentType,
                operatorUid: groupNotificationOperator ?? "",
                memberUids: groupNotificationMembers,
                value: groupNotificationValue
            )
        case .callStart:
            return .callRecord(
                callId: callId ?? "",
                targetId: callTargetId ?? "",
                audioOnly: callAudioOnly,
                status: callStatus,
                connectTime: callConnectTime,
                endTime: callEndTime
            )
        }
    }

    /// Comma-joined storage for the `repeated string mentioned_target`
    /// wire field — this codebase has no precedent for a JSON-array column,
    /// and uids never contain commas, so a simple CSV column avoids adding
    /// one. Computed, not stored: Swift's synthesized `Codable` only
    /// persists *stored* properties, so this never becomes a duplicate
    /// GRDB column.
    public var mentionedTargets: [String] {
        guard let raw = mentionedTargetsRaw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map(String.init)
    }

    public var groupNotificationMembers: [String] {
        guard let raw = groupNotificationMembersRaw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map(String.init)
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
        direction: MessageDirection,
        mentionedType: Int = 0,
        mentionedTargets: [String] = []
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
        self.mentionedType = mentionedType
        self.mentionedTargetsRaw = mentionedTargets.isEmpty ? nil : mentionedTargets.joined(separator: ",")

        // Placeholder values so every stored property has *some* value
        // before `setContent` (below) assigns the real ones per-case — a
        // Swift struct init must finish assigning every stored property
        // before calling any method on `self`, including a mutating one.
        contentType = .text
        textContent = nil
        searchableContent = nil
        mediaRemoteURL = nil
        mediaLocalPath = nil
        mediaThumbnail = nil
        groupNotificationOperator = nil
        groupNotificationMembersRaw = nil
        groupNotificationValue = nil
        callId = nil
        callTargetId = nil
        callAudioOnly = false
        callStatus = 0
        callConnectTime = 0
        callEndTime = 0

        setContent(content)
    }

    /// Flattens `content` into this row's storage columns, clearing every
    /// column owned by a *different* content case along the way (so e.g.
    /// updating a row from `.callRecord` to anything else, or vice versa,
    /// never leaves a stale value behind from the previous case). Shared by
    /// `init` (placeholder-then-set, see above) and `MessageStore.updateContent`
    /// (Task 2), which is the only reason this exists as its own method
    /// rather than being inlined back into `init`.
    public mutating func setContent(_ content: MessageContent) {
        switch content {
        case .text(let text):
            contentType = .text
            textContent = text
            searchableContent = text
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
            callId = nil
            callTargetId = nil
            callAudioOnly = false
            callStatus = 0
            callConnectTime = 0
            callEndTime = 0
        case .image(let thumbnail, let remoteURL, let localPath):
            contentType = .image
            textContent = nil
            searchableContent = "[图片]"
            mediaRemoteURL = remoteURL
            mediaLocalPath = localPath
            mediaThumbnail = thumbnail
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
            callId = nil
            callTargetId = nil
            callAudioOnly = false
            callStatus = 0
            callConnectTime = 0
            callEndTime = 0
        case .groupNotification(let type, let operatorUid, let memberUids, let value):
            contentType = type
            textContent = nil
            searchableContent = "[群通知]"
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
            groupNotificationOperator = operatorUid
            groupNotificationMembersRaw = memberUids.isEmpty ? nil : memberUids.joined(separator: ",")
            groupNotificationValue = value
            callId = nil
            callTargetId = nil
            callAudioOnly = false
            callStatus = 0
            callConnectTime = 0
            callEndTime = 0
        case .callRecord(let callId, let targetId, let audioOnly, let status, let connectTime, let endTime):
            contentType = .callStart
            textContent = nil
            searchableContent = audioOnly ? "[语音通话]" : "[视频通话]"
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
            self.callId = callId
            self.callTargetId = targetId
            self.callAudioOnly = audioOnly
            self.callStatus = status
            self.callConnectTime = connectTime
            self.callEndTime = endTime
        }
    }
}
```

- [ ] **Step 5: 加 GRDB migration**

在 `Sources/IMStorage/IMDatabase.swift`,`migrator.registerMigration("v4_addGroupSupport")` 块之后追加:

```swift
        migrator.registerMigration("v5_addCallRecord") { db in
            try db.alter(table: "message") { t in
                t.add(column: "callId", .text)
                t.add(column: "callTargetId", .text)
                t.add(column: "callAudioOnly", .boolean).notNull().defaults(to: false)
                t.add(column: "callStatus", .integer).notNull().defaults(to: 0)
                t.add(column: "callConnectTime", .integer).notNull().defaults(to: 0)
                t.add(column: "callEndTime", .integer).notNull().defaults(to: 0)
            }
        }
```

- [ ] **Step 6: 运行测试确认通过**

Run: `swift test --filter StoredMessageTests`
Expected: PASS

- [ ] **Step 7: 跑一遍 IMStorage 全量测试,确认重构没改坏既有行为**

Run: `swift test --filter IMStorageTests\|MessageStoreTests\|IMDatabaseTests\|GroupStoreTests\|ConversationStoreTests`
Expected: PASS(`setContent` 重构后,text/image/groupNotification 的既有断言必须原样通过)

- [ ] **Step 8: Commit**

```bash
git add Sources/IMStorage/MessageEnums.swift Sources/IMStorage/StoredMessage.swift Sources/IMStorage/IMDatabase.swift Tests/IMStorageTests/StoredMessageTests.swift
git commit -m "feat(IMStorage): add callStart content type and callRecord storage mapping"
```

## Task 2: `MessageStore.updateContent(id:content:)`

**Files:**
- Modify: `Sources/IMStorage/MessageStore.swift`
- Test: `Tests/IMStorageTests/MessageStoreTests.swift`

- [ ] **Step 1: 写失败的测试**

在 `Tests/IMStorageTests/MessageStoreTests.swift` 的 `test_messageByUid_withUidZero_alwaysReturnsNil` 之后追加:

```swift
    func test_updateContent_rewritesCallRecordFieldsByRowId() throws {
        let inserted = try store.insert(StoredMessage(
            localMessageId: 9, conversationType: .single, target: "u2", from: "u1",
            content: .callRecord(callId: "call-9", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0),
            timestamp: 1_000, status: .sending, direction: .send
        ))

        try store.updateContent(id: inserted.id!, content: .callRecord(callId: "call-9", targetId: "u2", audioOnly: false, status: 2, connectTime: 5_000, endTime: 65_000))

        let updated = try store.message(localMessageId: 9)
        XCTAssertEqual(updated?.content, .callRecord(callId: "call-9", targetId: "u2", audioOnly: false, status: 2, connectTime: 5_000, endTime: 65_000))
    }

    func test_updateContent_worksOnReceivedRowsToo() throws {
        // The whole point of keying by `id` rather than `localMessageId`:
        // a received call-record row's `localMessageId` may collide with
        // one of my own sent rows (see `message(localMessageId:)`'s doc
        // comment), but `id` is always unambiguous.
        let inserted = try store.insert(StoredMessage(
            localMessageId: 555, conversationType: .single, target: "u1", from: "u2",
            content: .callRecord(callId: "call-10", targetId: "u1", audioOnly: true, status: 0, connectTime: 0, endTime: 0),
            timestamp: 1_000, status: .unread, direction: .receive
        ))

        try store.updateContent(id: inserted.id!, content: .callRecord(callId: "call-10", targetId: "u1", audioOnly: true, status: 1, connectTime: 2_000, endTime: 0))

        let messages = try store.messages(conversationType: .single, target: "u1")
        XCTAssertEqual(messages.first?.content, .callRecord(callId: "call-10", targetId: "u1", audioOnly: true, status: 1, connectTime: 2_000, endTime: 0))
    }

    func test_updateContent_unknownId_isANoOp() throws {
        // Must not throw — `IMCall.CallManager` calls this from timer/network
        // callbacks where there's no reasonable recovery if the row vanished.
        try store.updateContent(id: 999_999, content: .callRecord(callId: "x", targetId: "y", audioOnly: false, status: 2, connectTime: 0, endTime: 0))
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter MessageStoreTests`
Expected: FAIL — `MessageStore` 没有 `updateContent` 方法,编译错误。

- [ ] **Step 3: 实现**

在 `Sources/IMStorage/MessageStore.swift`,`updateMessageUid` 方法之后追加:

```swift
    /// Updates a previously-inserted row's content in place, keyed by its
    /// GRDB autoincrement `id` — deliberately **not** `localMessageId`,
    /// which (per `message(localMessageId:)`'s doc comment above) is only
    /// guaranteed unique among my own sent messages; a received row's
    /// `localMessageId` can coincide with one of mine. `id` is the only
    /// column that unambiguously identifies "this exact row" regardless of
    /// `direction`, which matters here because a call-record bubble exists
    /// on both the caller's and callee's side and `IMCall.CallManager`
    /// updates whichever one is local to this device. A no-op (no error)
    /// if no row with this `id` exists.
    public func updateContent(id: Int64, content: MessageContent) throws {
        try dbQueue.write { db in
            guard var existing = try StoredMessage.fetchOne(db, key: id) else { return }
            existing.setContent(content)
            try existing.update(db)
        }
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter MessageStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/MessageStoreTests.swift
git commit -m "feat(IMStorage): add MessageStore.updateContent keyed by row id"
```

## Task 3: `MessageContentCodec` encode/decode for wire type 400 (CallStart)

**Files:**
- Modify: `Sources/IMMessaging/MessageContentCodec.swift`
- Test: `Tests/IMMessagingTests/MessageContentCodecTests.swift`

**Field mapping** (same convention as text/image — body goes in `searchableContent`, not `content`; see this file's existing top-of-file doc comment): `searchableContent`=callId, `data`=JSON `{"t":targetId,"a":0|1,"c"?:connectTime,"e"?:endTime,"s"?:status}` (optional keys omitted when 0, mirroring `CallStartMessageContent.encode()`'s `JSONObject.put` guards on Android). **Not yet byte-verified against a real Android-iOS exchange** — same caveat as the design doc's risk #4; Task 16 of this plan does that verification.

- [ ] **Step 1: 写失败的测试**

在 `Tests/IMMessagingTests/MessageContentCodecTests.swift` 末尾追加:

```swift
    func test_encodeCallRecord_setsTypeSearchableContentAndDataJSON() throws {
        let wire = MessageContentCodec.encode(.callRecord(callId: "call-1", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0))

        XCTAssertEqual(wire.type, 400)
        XCTAssertEqual(wire.searchableContent, "call-1")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire.data) as? [String: Any])
        XCTAssertEqual(json["t"] as? String, "u2")
        XCTAssertEqual(json["a"] as? Int, 0)
        XCTAssertNil(json["c"]) // omitted when 0, matching Android's encode() guard
        XCTAssertNil(json["e"])
        XCTAssertNil(json["s"])
    }

    func test_encodeCallRecord_includesNonZeroConnectEndStatus() throws {
        let wire = MessageContentCodec.encode(.callRecord(callId: "call-1", targetId: "u2", audioOnly: true, status: 2, connectTime: 5_000, endTime: 65_000))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire.data) as? [String: Any])
        XCTAssertEqual(json["a"] as? Int, 1)
        XCTAssertEqual(json["c"] as? Int, 5_000)
        XCTAssertEqual(json["e"] as? Int, 65_000)
        XCTAssertEqual(json["s"] as? Int, 2)
    }

    func test_decodeCallRecord_parsesAllFields() throws {
        var wire = Im_MessageContent()
        wire.type = 400
        wire.searchableContent = "call-1"
        wire.data = Data("""
        {"t":"u2","a":1,"c":5000,"e":65000,"s":2}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .callRecord(callId: "call-1", targetId: "u2", audioOnly: true, status: 2, connectTime: 5_000, endTime: 65_000))
    }

    func test_decodeCallRecord_missingOptionalFields_defaultToZero() throws {
        var wire = Im_MessageContent()
        wire.type = 400
        wire.searchableContent = "call-1"
        wire.data = Data("""
        {"t":"u2","a":0}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .callRecord(callId: "call-1", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
    }

    func test_encodeThenDecodeCallRecord_roundTrips() throws {
        let original = MessageContent.callRecord(callId: "call-2", targetId: "u3", audioOnly: true, status: 1, connectTime: 1_000, endTime: 0)
        XCTAssertEqual(try MessageContentCodec.decode(MessageContentCodec.encode(original)), original)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter MessageContentCodecTests`
Expected: FAIL — `encode`/`decode` 的 switch 没有 `.callRecord`/`400` 分支,编译错误或 `unsupportedContentType(400)`。

- [ ] **Step 3: 实现**

在 `Sources/IMMessaging/MessageContentCodec.swift`,`GroupNotificationWireContent` 结构体之后追加:

```swift
    /// Wire shape for type 400 (`CallStart`)'s `data` field — mirrors
    /// Android `CallStartMessageContent.encode()`'s `JSONObject` exactly
    /// (`t`=targetId, `a`=audioOnly as 0/1, `c`/`e`/`s` omitted when 0).
    private struct CallStartWireContent: Codable {
        let t: String
        let a: Int
        let c: Int64?
        let e: Int64?
        let s: Int?
    }
```

在 `encode(_:mentionedType:mentionedTargets:)` 的 `switch content` 里,`.groupNotification` 分支之后追加:

```swift
        case .callRecord(let callId, let targetId, let audioOnly, let status, let connectTime, let endTime):
            wire.type = 400
            wire.searchableContent = callId
            let payload = CallStartWireContent(
                t: targetId,
                a: audioOnly ? 1 : 0,
                c: connectTime > 0 ? connectTime : nil,
                e: endTime > 0 ? endTime : nil,
                s: status > 0 ? status : nil
            )
            if let data = try? JSONEncoder().encode(payload) {
                wire.data = data
            }
```

在 `decode(_:)` 的 `switch wire.type` 里,`case 112` 之后、`default` 之前追加:

```swift
        case 400:
            return decodeCallStart(wire: wire)
```

在 `decodeGroupNotification` 方法之后追加一个新的私有方法:

```swift
    private static func decodeCallStart(wire: Im_MessageContent) -> MessageContent {
        let callId = wire.hasSearchableContent ? wire.searchableContent : ""
        guard wire.hasData, let parsed = try? JSONDecoder().decode(CallStartWireContent.self, from: wire.data) else {
            return .callRecord(callId: callId, targetId: "", audioOnly: false, status: 0, connectTime: 0, endTime: 0)
        }
        return .callRecord(callId: callId, targetId: parsed.t, audioOnly: parsed.a > 0, status: parsed.s ?? 0, connectTime: parsed.c ?? 0, endTime: parsed.e ?? 0)
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter MessageContentCodecTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMMessaging/MessageContentCodec.swift Tests/IMMessagingTests/MessageContentCodecTests.swift
git commit -m "feat(IMMessaging): encode/decode wire type 400 CallStart"
```

## Task 4: `ReceiveMessageHandler` — persist 400, skip-and-forward 401-404

**Files:**
- Modify: `Sources/IMMessaging/ReceiveMessageHandler.swift`
- Test: `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift`

400 already persists correctly once Task 3 lands (it's just another `MessageContentCodec`-decodable type, same path as text/groupNotification) — this task only adds (a) a callback fired after persisting a *received* 400 so `IMCall.CallManager` learns about incoming calls, and (b) the skip-and-forward branch for 401/402/403/404 so they never reach `storage.messages.insert`.

- [ ] **Step 1: 写失败的测试**

在 `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift` 末尾追加:

```swift
    func test_handle_receivedCallStart_persistsAndFiresOnCallStartMessage() throws {
        var capturedMessage: StoredMessage?
        handler.onCallStartMessage = { capturedMessage = $0 }

        var message = Im_Message()
        message.messageID = 500
        message.fromUser = "them"
        message.conversation.type = 0
        message.conversation.target = "them"
        message.conversation.line = 0
        message.content = MessageContentCodec.encode(.callRecord(callId: "call-1", targetId: "me", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 500)

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.messages.message(uid: 500)?.content, .callRecord(callId: "call-1", targetId: "me", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
        XCTAssertEqual(capturedMessage?.from, "them")
        XCTAssertEqual(capturedMessage?.content, .callRecord(callId: "call-1", targetId: "me", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
    }

    func test_handle_ownSentCallStartEchoedBack_doesNotFireOnCallStartMessage() throws {
        // Mirrors `test_handle_ownSentMessageInPull_doesNotIncrementUnread`:
        // my own CallStart coming back through a pull is just an ack, not a
        // notification that *someone else* is calling me.
        var fired = false
        handler.onCallStartMessage = { _ in fired = true }

        var message = Im_Message()
        message.messageID = 501
        message.fromUser = "me"
        message.conversation.type = 0
        message.conversation.target = "them"
        message.conversation.line = 0
        message.content = MessageContentCodec.encode(.callRecord(callId: "call-2", targetId: "them", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 501)

        handler.handle(frame: frame)

        XCTAssertFalse(fired)
    }

    func test_handle_answerSignal_doesNotPersistAndFiresOnCallSignal() throws {
        var capturedWireMessage: Im_Message?
        handler.onCallSignal = { capturedWireMessage = $0 }

        var message = Im_Message()
        message.messageID = 502
        message.fromUser = "them"
        message.conversation.type = 0
        message.conversation.target = "them"
        message.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 401 // Answer
        wireContent.searchableContent = "call-1"
        wireContent.data = Data("1".utf8)
        message.content = wireContent
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 502)

        handler.handle(frame: frame)

        XCTAssertNil(try storage.messages.message(uid: 502)) // never persisted
        XCTAssertEqual(capturedWireMessage?.content.type, 401)
        XCTAssertEqual(capturedWireMessage?.content.searchableContent, "call-1")
    }

    func test_handle_byeSignalMessageSignalModify_allSkipPersistence() throws {
        for wireType: Int32 in [401, 402, 403, 404] {
            var message = Im_Message()
            message.messageID = Int64(600 + wireType)
            message.fromUser = "them"
            message.conversation.type = 0
            message.conversation.target = "them"
            message.conversation.line = 0
            var wireContent = Im_MessageContent()
            wireContent.type = wireType
            wireContent.searchableContent = "call-1"
            message.content = wireContent
            message.serverTimestamp = 1_000
            let frame = try makePullResultFrame(messages: [message], head: Int64(600 + wireType))

            handler.handle(frame: frame)

            XCTAssertNil(try storage.messages.message(uid: Int64(600 + wireType)), "type \(wireType) must not persist")
        }
    }

    func test_handle_callSignal_stillAdvancesSyncHead() throws {
        var message = Im_Message()
        message.messageID = 503
        message.fromUser = "them"
        message.conversation.type = 0
        message.conversation.target = "them"
        message.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 402 // Bye
        wireContent.searchableContent = "call-1"
        message.content = wireContent
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 503)

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.syncState.get().msgHead, 503)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ReceiveMessageHandlerTests`
Expected: FAIL — `ReceiveMessageHandler` 没有 `onCallStartMessage`/`onCallSignal` 属性,编译错误。

- [ ] **Step 3: 实现**

在 `Sources/IMMessaging/ReceiveMessageHandler.swift`,`onGroupNotificationMessage` 属性之后追加:

```swift
    /// Fired after persisting a *received* (never my own echoed-back) 400
    /// CallStart message — `IMCall.CallManager` wires this to learn about
    /// an incoming call. Carries the full `StoredMessage` (not just the
    /// caller's uid) so the caller has the row's `id` on hand for later
    /// `MessageStore.updateContent` calls without a second lookup.
    public var onCallStartMessage: ((StoredMessage) -> Void)?

    /// Fired for every 401/402/403/404 (Answer/Bye/Signal/Modify) message —
    /// these are intentionally **never persisted** (see this type's
    /// `persist(_:)` doc comment below), so this is the only way `IMCall`
    /// ever sees them. Carries the raw wire `Im_Message` rather than a
    /// decoded type, because decoding these 4 signal shapes is `IMCall`'s
    /// job (`CallSignalCodec`) — `IMMessaging` only needs to know "this is
    /// call signaling, don't persist it."
    public var onCallSignal: ((Im_Message) -> Void)?
```

把 `persist(_:)` 方法替换成:

```swift
    /// Wire types 401/402/403/404 (Answer/Bye/Signal/Modify) are
    /// intentionally never persisted to `storage.messages` — on Android
    /// these are `PersistFlag.No_Persist`/`.Transparent`, and at the volume
    /// ICE candidates/SDP exchanges happen during call setup, writing each
    /// one as a chat message row would spam the conversation's last-message
    /// preview. They're forwarded via `onCallSignal` instead and returned
    /// from early, before this method's normal persist-and-update-
    /// conversation flow runs. Type 400 (CallStart) is the one call-related
    /// type that *does* persist — it's the call-record bubble — so it falls
    /// through to the same path as every other message type below.
    private func persist(_ wireMessage: Im_Message) {
        guard wireMessage.messageID != 0 else { return }
        if (try? storage.messages.message(uid: wireMessage.messageID)) != nil {
            return // already have it via server uid — pull windows can overlap
        }

        if [401, 402, 403, 404].contains(wireMessage.content.type) {
            onCallSignal?(wireMessage)
            return
        }

        let direction: MessageDirection = wireMessage.fromUser == myUserId() ? .send : .receive

        if direction == .send, wireMessage.localMessageID != 0,
           (try? storage.messages.message(localMessageId: wireMessage.localMessageID)) != nil {
            try? storage.messages.updateMessageUid(localMessageId: wireMessage.localMessageID, messageUid: wireMessage.messageID)
            try? storage.messages.updateStatus(localMessageId: wireMessage.localMessageID, status: .sent)
            return
        }

        guard var content = try? MessageContentCodec.decode(wireMessage.content) else { return }
        // The server's group-notification fallback payload sometimes omits
        // (or, for quitGroup, never reliably carries) the operator uid —
        // `fromUser` is always the true actor regardless, so it's used
        // whenever the decoded payload came back empty.
        if case .groupNotification(let type, let operatorUid, let memberUids, let value) = content, operatorUid.isEmpty {
            content = .groupNotification(type: type, operatorUid: wireMessage.fromUser, memberUids: memberUids, value: value)
        }

        let conversationType = ConversationType(rawValue: Int(wireMessage.conversation.type)) ?? .single
        let target = wireMessage.conversation.target
        let line = Int(wireMessage.conversation.line)
        let mentionedType = Int(wireMessage.content.mentionedType)
        let mentionedTargets = wireMessage.content.mentionedTarget
        let isMentioned = conversationType == .group && direction == .receive
            && (mentionedType == 2 || (mentionedType == 1 && mentionedTargets.contains(myUserId())))

        do {
            let inserted = try storage.messages.insert(StoredMessage(
                localMessageId: wireMessage.localMessageID,
                messageUid: wireMessage.messageID,
                conversationType: conversationType,
                target: target,
                line: line,
                from: wireMessage.fromUser,
                content: content,
                timestamp: wireMessage.serverTimestamp,
                status: direction == .send ? .sent : .unread,
                direction: direction,
                mentionedType: mentionedType,
                mentionedTargets: mentionedTargets
            ))
            try storage.conversations.recordIncomingMessage(
                conversationType: conversationType,
                target: target,
                line: line,
                messageUid: wireMessage.messageID,
                timestamp: wireMessage.serverTimestamp,
                incrementUnread: direction == .receive,
                incrementMention: isMentioned
            )
            if case .groupNotification = content {
                onGroupNotificationMessage?(target)
            }
            if case .callRecord = content, direction == .receive {
                onCallStartMessage?(inserted)
            }
        } catch {
            // Best-effort: one malformed/unexpected row shouldn't abort the rest of the batch.
        }
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ReceiveMessageHandlerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMMessaging/ReceiveMessageHandler.swift Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift
git commit -m "feat(IMMessaging): route call signaling through ReceiveMessageHandler without persisting 401-404"
```

## Task 5: `MessagingService.sendCallStart` + `sendCallControlMessage`

**Files:**
- Modify: `Sources/IMMessaging/MessagingService.swift`
- Test: `Tests/IMMessagingTests/MessagingServiceTests.swift`

`sendCallStart` reuses the existing persisted `send(...)` path (like `sendText`/`sendImage`) so the call-record bubble gets the same local-echo/ack-tracking behavior. `sendCallControlMessage` is new: a **non-persisting** direct wire send for 401/402/403/404 — it does not call `storage.messages.insert` or go through `OutgoingMessageTracker`, because there is no local row to update when an ack comes back.

- [ ] **Step 1: 写失败的测试**

在 `Tests/IMMessagingTests/MessagingServiceTests.swift` 末尾追加:

```swift
    func test_sendCallStart_insertsLocalEchoAndSendsWireFrame() throws {
        let echo = try service.sendCallStart(targetId: "them", callId: "call-1", audioOnly: false)

        XCTAssertEqual(echo.content, .callRecord(callId: "call-1", targetId: "them", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
        XCTAssertNotNil(echo.id)

        let frame = try decodeOnlySentFrame()
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.content.type, 400)
        XCTAssertEqual(try MessageContentCodec.decode(wireMessage.content), .callRecord(callId: "call-1", targetId: "them", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
    }

    func test_sendCallControlMessage_doesNotInsertAnyLocalRow() throws {
        let countBefore = try storage.messages.messages(conversationType: .single, target: "them").count

        try service.sendCallControlMessage(to: "them", wireType: 402, callId: "call-1", dataPayload: nil)

        XCTAssertEqual(try storage.messages.messages(conversationType: .single, target: "them").count, countBefore)
    }

    func test_sendCallControlMessage_sendsCorrectWireFrame() throws {
        try service.sendCallControlMessage(to: "them", wireType: 403, callId: "call-1", dataPayload: Data("""
        {"type":"offer","sdp":"v=0..."}
        """.utf8))

        let frame = try decodeOnlySentFrame()
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.fromUser, "me")
        XCTAssertEqual(wireMessage.conversation.target, "them")
        XCTAssertEqual(wireMessage.content.type, 403)
        XCTAssertEqual(wireMessage.content.searchableContent, "call-1")
        XCTAssertTrue(wireMessage.content.data.starts(with: Data("{\"type\":\"offer\"".utf8)))
    }

    func test_onCallStartMessage_forwardsToTheInternalReceiveMessageHandler() throws {
        var captured: StoredMessage?
        service.onCallStartMessage = { captured = $0 }

        var wireMessage = Im_Message()
        wireMessage.messageID = 700
        wireMessage.fromUser = "them"
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = "them"
        wireMessage.conversation.line = 0
        wireMessage.content = MessageContentCodec.encode(.callRecord(callId: "call-3", targetId: "me", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
        wireMessage.serverTimestamp = 1_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = 700
        result.head = 700
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(captured?.from, "them")
    }

    func test_onCallSignal_forwardsToTheInternalReceiveMessageHandler() throws {
        var captured: Im_Message?
        service.onCallSignal = { captured = $0 }

        var wireMessage = Im_Message()
        wireMessage.messageID = 701
        wireMessage.fromUser = "them"
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = "them"
        wireMessage.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 402
        wireContent.searchableContent = "call-3"
        wireMessage.content = wireContent
        wireMessage.serverTimestamp = 1_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = 701
        result.head = 701
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(captured?.content.type, 402)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter MessagingServiceTests`
Expected: FAIL — `MessagingService` 没有 `sendCallStart`/`sendCallControlMessage`/`onCallStartMessage`/`onCallSignal`,编译错误。

- [ ] **Step 3: 实现**

在 `Sources/IMMessaging/MessagingService.swift`,`onGroupNotificationMessage` 计算属性之后追加:

```swift
    /// Forwards to the internal `ReceiveMessageHandler`'s closure of the
    /// same name — see that type's doc comment. `IMCall.CallManager` wires
    /// this to learn about incoming calls.
    public var onCallStartMessage: ((StoredMessage) -> Void)? {
        get { receiveMessageHandler.onCallStartMessage }
        set { receiveMessageHandler.onCallStartMessage = newValue }
    }

    /// Forwards to the internal `ReceiveMessageHandler`'s closure of the
    /// same name — see that type's doc comment. `IMCall.CallManager` wires
    /// this to receive Answer/Bye/Signal/Modify.
    public var onCallSignal: ((Im_Message) -> Void)? {
        get { receiveMessageHandler.onCallSignal }
        set { receiveMessageHandler.onCallSignal = newValue }
    }
```

在 `sendImage` 方法之后追加:

```swift
    /// Sends a CallStart (wire type 400) and persists it as a local call-
    /// record bubble, exactly like `sendText`/`sendImage` persist their
    /// content — this is the one call-signaling type that's a real chat
    /// message, not transient signaling. Returns the inserted row so
    /// `IMCall.CallManager` can capture its `id` for later
    /// `IMStorage.MessageStore.updateContent` calls as the call progresses.
    @discardableResult
    public func sendCallStart(targetId: String, callId: String, audioOnly: Bool) throws -> StoredMessage {
        let content = MessageContent.callRecord(callId: callId, targetId: targetId, audioOnly: audioOnly, status: 0, connectTime: 0, endTime: 0)
        let localMessageId = idGenerator.next()
        let timestamp = nowMillis()

        let echo = try storage.messages.insert(StoredMessage(
            localMessageId: localMessageId,
            conversationType: .single,
            target: targetId,
            from: imClient.userId,
            content: content,
            timestamp: timestamp,
            status: .sending,
            direction: .send
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: .single, target: targetId, line: 0,
            messageUid: 0, timestamp: timestamp, incrementUnread: false
        )
        try sendWireMessage(localMessageId: echo.localMessageId, conversationType: .single, target: targetId, line: 0, content: content, mentionedType: 0, mentionedTargets: [])
        return echo
    }

    /// Sends one of 401/402/403/404 (Answer/Bye/Signal/Modify) directly on
    /// the wire — deliberately bypassing `send(...)`'s local-echo insert
    /// and `OutgoingMessageTracker` ack tracking, because these are
    /// transient signaling with no corresponding stored row to update (see
    /// the Phase 3 design doc §2's persist-flag table). `callId` goes in
    /// `searchableContent` and `dataPayload` in `data`, mirroring every
    /// other content type's wire-field mapping in this codebase.
    public func sendCallControlMessage(to target: String, wireType: Int32, callId: String, dataPayload: Data?) throws {
        var wireMessage = Im_Message()
        wireMessage.conversation.type = Int32(ConversationType.single.rawValue)
        wireMessage.conversation.target = target
        wireMessage.conversation.line = 0
        wireMessage.fromUser = imClient.userId
        var content = Im_MessageContent()
        content.type = wireType
        content.searchableContent = callId
        if let dataPayload {
            content.data = dataPayload
        }
        wireMessage.content = content

        let body = try wireMessage.serializedData()
        imClient.sendFrame(signal: .publish, subSignal: .ms, body: body)
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter MessagingServiceTests`
Expected: PASS

- [ ] **Step 5: 跑一遍 IMMessaging 全量测试**

Run: `swift test --filter IMMessagingTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMMessaging/MessagingService.swift Tests/IMMessagingTests/MessagingServiceTests.swift
git commit -m "feat(IMMessaging): add sendCallStart and sendCallControlMessage"
```

## Task 6: New `IMCall` package + `CallSignalCodec` (401-404 encode/decode)

**Files:**
- Modify: `Package.swift`
- Create: `Sources/IMCall/CallSignalCodec.swift`
- Test: `Tests/IMCallTests/CallSignalCodecTests.swift`

- [ ] **Step 1: 新建 `IMCall` 包 target**

在 `Package.swift` 的 `products` 数组里,`.library(name: "IMMedia", ...)` 之后追加:

```swift
        .library(name: "IMCall", targets: ["IMCall"]),
```

在 `targets` 数组里,`IMMedia` 的 target/testTarget 之后(`AppCore` 的 target 之前)追加:

```swift
        .target(name: "IMCall", dependencies: ["IMMessaging", "IMStorage", "IMProto", "IMClient"]),
        .testTarget(name: "IMCallTests", dependencies: ["IMCall", "IMMessaging", "IMStorage", "IMClient", "IMTransport", "IMProto"]),
```

(测试 target 比 `IMCall` 本身多列了 `IMMessaging`/`IMStorage`/`IMClient`/`IMTransport`/`IMProto` —— Task 8 的 `CallManagerTests` 要像 `MessagingServiceTests` 一样直接构造一个真实的 `MessagingService`(配 `FakeTransportConnection`/`ManualScheduler`),这些类型分别来自这几个模块,只依赖 `IMCall` 拿不到它们。)

- [ ] **Step 2: 写失败的测试**

创建 `Tests/IMCallTests/CallSignalCodecTests.swift`:

```swift
import XCTest
import Foundation
import IMProto
@testable import IMCall

final class CallSignalCodecTests: XCTestCase {
    private func makeWireMessage(type: Int32, callId: String, data: Data? = nil) -> Im_Message {
        var message = Im_Message()
        message.fromUser = "them"
        var content = Im_MessageContent()
        content.type = type
        content.searchableContent = callId
        if let data { content.data = data }
        message.content = content
        return message
    }

    func test_decodeAnswer_parsesCallIdAndAudioOnly() {
        let wire = makeWireMessage(type: 401, callId: "call-1", data: Data("1".utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .answer(callId: "call-1", audioOnly: true))
    }

    func test_decodeAnswer_audioOnlyFalseWhenDataIsZero() {
        let wire = makeWireMessage(type: 401, callId: "call-1", data: Data("0".utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .answer(callId: "call-1", audioOnly: false))
    }

    func test_decodeBye_parsesCallId() {
        let wire = makeWireMessage(type: 402, callId: "call-1")
        XCTAssertEqual(CallSignalCodec.decode(wire), .bye(callId: "call-1"))
    }

    func test_decodeModify_parsesCallIdAndAudioOnly() {
        let wire = makeWireMessage(type: 404, callId: "call-1", data: Data("1".utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .modify(callId: "call-1", audioOnly: true))
    }

    func test_decodeSignal_offer_parsesSDP() {
        let wire = makeWireMessage(type: 403, callId: "call-1", data: Data("""
        {"type":"offer","sdp":"v=0..."}
        """.utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .sdpOffer(callId: "call-1", sdp: "v=0..."))
    }

    func test_decodeSignal_answer_parsesSDP() {
        let wire = makeWireMessage(type: 403, callId: "call-1", data: Data("""
        {"type":"answer","sdp":"v=0...answer"}
        """.utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .sdpAnswer(callId: "call-1", sdp: "v=0...answer"))
    }

    func test_decodeSignal_candidate_parsesLabelIdAndCandidate() {
        let wire = makeWireMessage(type: 403, callId: "call-1", data: Data("""
        {"type":"candidate","label":0,"id":"audio","candidate":"candidate:1 1 UDP..."}
        """.utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .iceCandidate(callId: "call-1", sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1 1 UDP..."))
    }

    func test_decodeSignal_malformedData_returnsNil() {
        let wire = makeWireMessage(type: 403, callId: "call-1", data: Data("not json".utf8))
        XCTAssertNil(CallSignalCodec.decode(wire))
    }

    func test_decode_unsupportedType_returnsNil() {
        let wire = makeWireMessage(type: 1, callId: "call-1") // text — not a call signal
        XCTAssertNil(CallSignalCodec.decode(wire))
    }

    func test_encodeAnswer_returnsWireTypeCallIdAndAudioOnlyByte() {
        let encoded = CallSignalCodec.encode(.answer(callId: "call-1", audioOnly: true))
        XCTAssertEqual(encoded.wireType, 401)
        XCTAssertEqual(encoded.callId, "call-1")
        XCTAssertEqual(encoded.data, Data("1".utf8))
    }

    func test_encodeBye_returnsWireTypeAndCallIdNoData() {
        let encoded = CallSignalCodec.encode(.bye(callId: "call-1"))
        XCTAssertEqual(encoded.wireType, 402)
        XCTAssertNil(encoded.data)
    }

    func test_encodeSdpOffer_returnsWireType403WithJSON() throws {
        let encoded = CallSignalCodec.encode(.sdpOffer(callId: "call-1", sdp: "v=0..."))
        XCTAssertEqual(encoded.wireType, 403)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded.data!) as? [String: String])
        XCTAssertEqual(json["type"], "offer")
        XCTAssertEqual(json["sdp"], "v=0...")
    }

    func test_encodeIceCandidate_returnsWireType403WithLabelIdCandidate() throws {
        let encoded = CallSignalCodec.encode(.iceCandidate(callId: "call-1", sdpMLineIndex: 1, sdpMid: "video", candidate: "candidate:2..."))
        XCTAssertEqual(encoded.wireType, 403)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded.data!) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "candidate")
        XCTAssertEqual(json["label"] as? Int, 1)
        XCTAssertEqual(json["id"] as? String, "video")
        XCTAssertEqual(json["candidate"] as? String, "candidate:2...")
    }

    func test_encodeThenDecode_roundTripsForEverySignalShape() {
        let signals: [(OutgoingCallSignal, IncomingCallSignal)] = [
            (.answer(callId: "c1", audioOnly: false), .answer(callId: "c1", audioOnly: false)),
            (.bye(callId: "c1"), .bye(callId: "c1")),
            (.sdpOffer(callId: "c1", sdp: "sdp-1"), .sdpOffer(callId: "c1", sdp: "sdp-1")),
            (.sdpAnswer(callId: "c1", sdp: "sdp-2"), .sdpAnswer(callId: "c1", sdp: "sdp-2")),
            (.iceCandidate(callId: "c1", sdpMLineIndex: 0, sdpMid: "audio", candidate: "cand"), .iceCandidate(callId: "c1", sdpMLineIndex: 0, sdpMid: "audio", candidate: "cand")),
            (.modify(callId: "c1", audioOnly: true), .modify(callId: "c1", audioOnly: true)),
        ]
        for (outgoing, expectedIncoming) in signals {
            let encoded = CallSignalCodec.encode(outgoing)
            var wire = Im_Message()
            wire.fromUser = "them"
            var content = Im_MessageContent()
            content.type = encoded.wireType
            content.searchableContent = encoded.callId
            if let data = encoded.data { content.data = data }
            wire.content = content
            XCTAssertEqual(CallSignalCodec.decode(wire), expectedIncoming)
        }
    }
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `swift test --filter CallSignalCodecTests`
Expected: FAIL — `IMCall` target/`CallSignalCodec` 还不存在,编译错误。

- [ ] **Step 4: 实现**

创建 `Sources/IMCall/CallSignalCodec.swift`:

```swift
import IMProto
import Foundation

/// Decoded shape of an incoming 401/402/403/404 wire message — see the
/// Phase 3 design doc §2's field-mapping table. `searchableContent`=callId,
/// `data`=either an ASCII "0"/"1" (Answer/Modify's audioOnly flag) or a JSON
/// blob (Signal's SDP/ICE payload), mirroring every other content type's
/// wire-field convention in this codebase (`IMMessaging.MessageContentCodec`).
public enum IncomingCallSignal: Equatable {
    case answer(callId: String, audioOnly: Bool)
    case bye(callId: String)
    case sdpOffer(callId: String, sdp: String)
    case sdpAnswer(callId: String, sdp: String)
    case iceCandidate(callId: String, sdpMLineIndex: Int32, sdpMid: String, candidate: String)
    case modify(callId: String, audioOnly: Bool)
}

/// What `CallManager` wants to send — `CallSignalCodec.encode` turns this
/// into the three raw pieces `MessagingService.sendCallControlMessage`
/// needs, keeping `IMCall` itself ignorant of `Im_MessageContent`'s exact
/// field layout outside this one file.
public enum OutgoingCallSignal: Equatable {
    case answer(callId: String, audioOnly: Bool)
    case bye(callId: String)
    case sdpOffer(callId: String, sdp: String)
    case sdpAnswer(callId: String, sdp: String)
    case iceCandidate(callId: String, sdpMLineIndex: Int32, sdpMid: String, candidate: String)
    case modify(callId: String, audioOnly: Bool)
}

public enum CallSignalCodec {
    /// `nil` for any `wireMessage.content.type` outside 401-404 — callers
    /// (`CallManager`) only ever invoke this after `ReceiveMessageHandler`
    /// has already filtered to call-signal types, but this stays
    /// total/safe rather than assuming that filtering happened.
    public static func decode(_ wireMessage: Im_Message) -> IncomingCallSignal? {
        let callId = wireMessage.content.hasSearchableContent ? wireMessage.content.searchableContent : ""
        let data = wireMessage.content.hasData ? wireMessage.content.data : Data()
        switch wireMessage.content.type {
        case 401:
            return .answer(callId: callId, audioOnly: audioOnlyFlag(from: data))
        case 402:
            return .bye(callId: callId)
        case 403:
            return decodeSignal(callId: callId, data: data)
        case 404:
            return .modify(callId: callId, audioOnly: audioOnlyFlag(from: data))
        default:
            return nil
        }
    }

    public static func encode(_ signal: OutgoingCallSignal) -> (wireType: Int32, callId: String, data: Data?) {
        switch signal {
        case .answer(let callId, let audioOnly):
            return (401, callId, Data((audioOnly ? "1" : "0").utf8))
        case .bye(let callId):
            return (402, callId, nil)
        case .sdpOffer(let callId, let sdp):
            return (403, callId, try? JSONEncoder().encode(SDPWireSignal(type: "offer", sdp: sdp)))
        case .sdpAnswer(let callId, let sdp):
            return (403, callId, try? JSONEncoder().encode(SDPWireSignal(type: "answer", sdp: sdp)))
        case .iceCandidate(let callId, let sdpMLineIndex, let sdpMid, let candidate):
            return (403, callId, try? JSONEncoder().encode(CandidateWireSignal(type: "candidate", label: sdpMLineIndex, id: sdpMid, candidate: candidate)))
        case .modify(let callId, let audioOnly):
            return (404, callId, Data((audioOnly ? "1" : "0").utf8))
        }
    }

    private static func audioOnlyFlag(from data: Data) -> Bool {
        (Int(String(decoding: data, as: UTF8.self)) ?? 0) > 0
    }

    private struct SignalTypePeek: Codable { let type: String }
    private struct SDPWireSignal: Codable { let type: String; let sdp: String }
    private struct CandidateWireSignal: Codable { let type: String; let label: Int32; let id: String; let candidate: String }

    private static func decodeSignal(callId: String, data: Data) -> IncomingCallSignal? {
        guard let peek = try? JSONDecoder().decode(SignalTypePeek.self, from: data) else { return nil }
        switch peek.type {
        case "offer":
            guard let parsed = try? JSONDecoder().decode(SDPWireSignal.self, from: data) else { return nil }
            return .sdpOffer(callId: callId, sdp: parsed.sdp)
        case "answer":
            guard let parsed = try? JSONDecoder().decode(SDPWireSignal.self, from: data) else { return nil }
            return .sdpAnswer(callId: callId, sdp: parsed.sdp)
        case "candidate":
            guard let parsed = try? JSONDecoder().decode(CandidateWireSignal.self, from: data) else { return nil }
            return .iceCandidate(callId: callId, sdpMLineIndex: parsed.label, sdpMid: parsed.id, candidate: parsed.candidate)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test --filter CallSignalCodecTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/IMCall/CallSignalCodec.swift Tests/IMCallTests/CallSignalCodecTests.swift
git commit -m "feat(IMCall): add package skeleton and CallSignalCodec for 401-404"
```

## Task 7: `CallState`/`CallEndReason`/`CallSession` + `MediaEngine` protocol + `FakeMediaEngine`

**Files:**
- Create: `Sources/IMCall/CallSession.swift`
- Create: `Sources/IMCall/MediaEngine.swift`
- Create: `Tests/IMCallTests/Support/FakeMediaEngine.swift`

No test-first step here — these are plain data types and a protocol with no behavior of their own to assert against; they're exercised through `CallManagerTests` in Tasks 8-9. `FakeMediaEngine` is the test double those tasks need, so it's created now alongside the protocol it implements.

- [ ] **Step 1: 创建 `CallSession.swift`**

```swift
import Foundation

public enum CallState: Equatable {
    case idle
    case outgoing
    case incoming
    case connecting
    case connected
}

public enum CallEndReason: Equatable {
    case localHangup
    case remoteBye
    case timeout
    case busy
    case mediaFailure
}

/// Plain data for the call currently in progress — `CallManager` is the
/// only thing that mutates this, and only ever has at most one of these at
/// a time (Phase 3 is one-to-one calling only, see the design doc §1).
struct CallSession {
    let callId: String
    let peerUid: String
    var audioOnly: Bool
    /// The `id` (GRDB row id, not `localMessageId` — see
    /// `MessageStore.updateContent`'s doc comment) of this call's
    /// CallStart bubble, so `CallManager` can update it in place as the
    /// call progresses. `nil` only transiently between `sendCallStart`/
    /// `ReceiveMessageHandler` inserting the row and `CallManager`
    /// capturing the result — never observed `nil` by any of this plan's
    /// call sites.
    var localMessageRowId: Int64?
    /// Set once when the call reaches `.connected`; read back when the
    /// call ends so the final bubble update can report the same
    /// `connectTime` rather than losing it.
    var connectTime: Int64 = 0
}
```

- [ ] **Step 2: 创建 `MediaEngine.swift`**

```swift
import Foundation

/// Everything `CallManager` needs from a WebRTC implementation, kept
/// narrow and protocol-shaped so `CallManagerTests` can drive the state
/// machine against `FakeMediaEngine` without linking real WebRTC. The
/// production conformer is `WebRTCClient` (Task 12), built on top of
/// `stasel/WebRTC`.
public protocol MediaEngine: AnyObject {
    /// Fired whenever local ICE gathering produces a new candidate —
    /// `CallManager` wraps each one in `OutgoingCallSignal.iceCandidate`
    /// and sends it as a 403 Signal message.
    var onLocalCandidate: ((_ sdpMLineIndex: Int32, _ sdpMid: String, _ candidate: String) -> Void)? { get set }
    /// Fired once the underlying `RTCPeerConnection`'s ICE connection
    /// state first becomes connected — drives the `.connecting → .connected`
    /// transition.
    var onConnected: (() -> Void)? { get set }
    /// Fired if a connected call's ICE connection later fails/disconnects
    /// and doesn't recover — `CallManager` treats this as `.mediaFailure`
    /// (see the design doc §5's edge-case table; no ICE restart in Phase 3).
    var onDisconnected: (() -> Void)? { get set }

    func start(audioOnly: Bool)
    func createOffer(completion: @escaping (String) -> Void)
    func createAnswer(forRemoteOffer sdp: String, completion: @escaping (String) -> Void)
    func setRemoteAnswer(_ sdp: String)
    func addRemoteCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String)
    func setAudioOnly(_ audioOnly: Bool)
    func close()
}
```

- [ ] **Step 3: 创建测试用的 `FakeMediaEngine`**

创建 `Tests/IMCallTests/Support/FakeMediaEngine.swift`:

```swift
import Foundation
@testable import IMCall

final class FakeMediaEngine: MediaEngine {
    var onLocalCandidate: ((Int32, String, String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private(set) var startCalls: [Bool] = []
    private(set) var createOfferCallCount = 0
    private(set) var createAnswerCalls: [String] = []
    private(set) var remoteAnswers: [String] = []
    private(set) var remoteCandidates: [(Int32, String, String)] = []
    private(set) var audioOnlyCalls: [Bool] = []
    private(set) var closeCallCount = 0

    var offerSDPToReturn = "fake-offer-sdp"
    var answerSDPToReturn = "fake-answer-sdp"

    func start(audioOnly: Bool) {
        startCalls.append(audioOnly)
    }

    func createOffer(completion: @escaping (String) -> Void) {
        createOfferCallCount += 1
        completion(offerSDPToReturn)
    }

    func createAnswer(forRemoteOffer sdp: String, completion: @escaping (String) -> Void) {
        createAnswerCalls.append(sdp)
        completion(answerSDPToReturn)
    }

    func setRemoteAnswer(_ sdp: String) {
        remoteAnswers.append(sdp)
    }

    func addRemoteCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String) {
        remoteCandidates.append((sdpMLineIndex, sdpMid, candidate))
    }

    func setAudioOnly(_ audioOnly: Bool) {
        audioOnlyCalls.append(audioOnly)
    }

    func close() {
        closeCallCount += 1
    }

    func simulateConnected() {
        onConnected?()
    }

    func simulateDisconnected() {
        onDisconnected?()
    }

    func simulateLocalCandidate(sdpMLineIndex: Int32 = 0, sdpMid: String = "audio", candidate: String = "candidate:1...") {
        onLocalCandidate?(sdpMLineIndex, sdpMid, candidate)
    }
}
```

- [ ] **Step 4: 确认编译通过(没有断言要跑,只验证类型/协议拼得上)**

Run: `swift build`
Expected: 编译成功,无输出错误

- [ ] **Step 5: Commit**

```bash
git add Sources/IMCall/CallSession.swift Sources/IMCall/MediaEngine.swift Tests/IMCallTests/Support/FakeMediaEngine.swift
git commit -m "feat(IMCall): add CallSession/CallState/CallEndReason types and MediaEngine protocol"
```

## Task 8: `CallManager` — outgoing call, answer/hangup, timeouts, SDP/ICE signal plumbing

**Files:**
- Create: `Sources/IMCall/CallManager.swift`
- Create: `Tests/IMCallTests/Support/FakeTransportConnection.swift`
- Test: `Tests/IMCallTests/CallManagerTests.swift`

`CallManagerTests` constructs a real `MessagingService` backed by a fake transport — exactly like `MessagingServiceTests` does — because `IMClient`/`MessagingService` are concrete classes, not protocols; `CallManager` is meant to be tested against the real send/receive plumbing it'll run on in production, with only the WebRTC layer (`MediaEngine`) faked.

- [ ] **Step 1: 复制 `FakeTransportConnection`**

创建 `Tests/IMCallTests/Support/FakeTransportConnection.swift`,内容跟 `Tests/IMMessagingTests/Support/FakeTransportConnection.swift` 逐字一致(同样的"每个测试 target 各自留一份副本"约定,见该文件的文档注释):

```swift
import Foundation
import IMClient

/// Local duplicate of `IMClientTests`'s `FakeTransportConnection` —
/// `internal` types aren't visible across SPM test targets, so this test
/// target keeps its own minimal copy, implementing only what
/// `CallManagerTests` needs.
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

- [ ] **Step 2: 写失败的测试**

创建 `Tests/IMCallTests/CallManagerTests.swift`:

```swift
import XCTest
import Foundation
import IMClient
import IMTransport
import IMProto
import IMStorage
import IMMessaging
@testable import IMCall

final class CallManagerTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var scheduler: ManualScheduler!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var messagingService: MessagingService!
    private var mediaEngine: FakeMediaEngine!
    private var manager: CallManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        scheduler = ManualScheduler()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, scheduler: scheduler, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        messagingService = MessagingService(imClient: imClient, storage: storage, scheduler: scheduler)
        imClient.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()

        mediaEngine = FakeMediaEngine()
        manager = CallManager(messagingService: messagingService, storage: storage, mediaEngine: mediaEngine, scheduler: scheduler, myUserId: { "me" })
    }

    private func sentWireMessages() throws -> [Im_Message] {
        try fakeTransport.sentFrames.compactMap { data in
            try FrameDecoder().feed(data).first.map { try Im_Message(serializedBytes: $0.body) }
        }
    }

    private func deliverSignal(_ signal: OutgoingCallSignal, from: String) throws {
        let encoded = CallSignalCodec.encode(signal)
        var wireMessage = Im_Message()
        wireMessage.messageID = Int64.random(in: 1_000_000...9_999_999)
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = "me"
        wireMessage.conversation.line = 0
        var content = Im_MessageContent()
        content.type = encoded.wireType
        content.searchableContent = encoded.callId
        if let data = encoded.data { content.data = data }
        wireMessage.content = content
        wireMessage.serverTimestamp = 1_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = wireMessage.messageID
        result.head = wireMessage.messageID
        let body = Data([0x00]) + (try result.serializedData())
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body))
    }

    func test_startCall_transitionsToOutgoingAndSendsCallStart() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertEqual(manager.state, .outgoing)
        XCTAssertEqual(manager.peerUid, "them")
        let messages = try sentWireMessages()
        XCTAssertEqual(messages.first?.content.type, 400)
    }

    func test_startCall_startsMediaEngineAndSendsOfferAsSignal() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertEqual(mediaEngine.startCalls, [false])
        XCTAssertEqual(mediaEngine.createOfferCallCount, 1)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 403 })
    }

    func test_startCall_whenNotIdle_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let countBefore = try sentWireMessages().count

        try manager.startCall(to: "someone-else", audioOnly: false)

        XCTAssertEqual(manager.peerUid, "them") // unchanged
        XCTAssertEqual(try sentWireMessages().count, countBefore)
    }

    func test_receivingAnswer_transitionsToConnecting() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")

        XCTAssertEqual(manager.state, .connecting)
    }

    func test_mediaEngineConnected_transitionsToConnectedAndUpdatesBubble() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")

        mediaEngine.simulateConnected()

        XCTAssertEqual(manager.state, .connected)
        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, let connectTime, _) = bubble?.content {
            XCTAssertEqual(status, 1)
            XCTAssertGreaterThan(connectTime, 0)
        } else {
            XCTFail("expected a callRecord bubble")
        }
    }

    func test_hangUp_sendsByeAndReturnsToIdle() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try manager.hangUp()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.peerUid)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 402 })
    }

    func test_hangUp_updatesBubbleToEndedStatus() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        try manager.hangUp()

        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, let connectTime, let endTime) = bubble?.content {
            XCTAssertEqual(status, 2)
            XCTAssertGreaterThan(connectTime, 0) // preserved from the earlier .connected update
            XCTAssertGreaterThan(endTime, 0)
        } else {
            XCTFail("expected a callRecord bubble")
        }
    }

    func test_hangUp_whenIdle_isANoOp() throws {
        XCTAssertNoThrow(try manager.hangUp())
        XCTAssertEqual(manager.state, .idle)
    }

    func test_receivingBye_endsCallAndUpdatesBubble() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.bye(callId: callIdFromLastCallStart()), from: "them")

        XCTAssertEqual(manager.state, .idle)
        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, _, _) = bubble?.content {
            XCTAssertEqual(status, 2)
        } else {
            XCTFail("expected a callRecord bubble")
        }
    }

    func test_answerTimeout_60Seconds_endsCallAsTimeoutAndSendsBye() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertTrue(scheduler.scheduledDelays.contains(60))
        var endedReason: CallEndReason?
        manager.onCallEnded = { endedReason = $0 }
        scheduler.fireNext()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endedReason, .timeout)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 402 })
    }

    func test_connectingTimeout_60SecondsAfterAnswer_endsCallAsTimeout() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        scheduler.pendingCount > 0 ? () : XCTFail("expected the connecting timer to be scheduled")

        var endedReason: CallEndReason?
        manager.onCallEnded = { endedReason = $0 }
        scheduler.fireNext() // fires the connecting-timeout (the only thing pending after answer cancels the answer-timeout)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endedReason, .timeout)
    }

    func test_receivingSdpAnswer_forwardsToMediaEngine() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.sdpAnswer(callId: callIdFromLastCallStart(), sdp: "remote-answer-sdp"), from: "them")

        XCTAssertEqual(mediaEngine.remoteAnswers, ["remote-answer-sdp"])
    }

    func test_receivingIceCandidate_forwardsToMediaEngine() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.iceCandidate(callId: callIdFromLastCallStart(), sdpMLineIndex: 1, sdpMid: "video", candidate: "candidate:9..."), from: "them")

        XCTAssertEqual(mediaEngine.remoteCandidates.count, 1)
        XCTAssertEqual(mediaEngine.remoteCandidates.first?.0, 1)
        XCTAssertEqual(mediaEngine.remoteCandidates.first?.1, "video")
    }

    func test_mediaEngineLocalCandidate_sentAsSignal403() throws {
        try manager.startCall(to: "them", audioOnly: false)

        mediaEngine.simulateLocalCandidate(sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1...")

        let messages = try sentWireMessages()
        let signalMessages = messages.filter { $0.content.type == 403 }
        XCTAssertTrue(signalMessages.contains { CallSignalCodec.decode($0) == .iceCandidate(callId: callIdFromLastCallStart(), sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1...") })
    }

    func test_mediaEngineDisconnectedAfterConnected_endsCallAsMediaFailure() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        var endedReason: CallEndReason?
        manager.onCallEnded = { endedReason = $0 }
        mediaEngine.simulateDisconnected()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endedReason, .mediaFailure)
    }

    // MARK: - Helpers

    private func callIdFromLastCallStart() -> String {
        guard let message = try? sentWireMessages().first(where: { $0.content.type == 400 }),
              case .callRecord(let callId, _, _, _, _, _) = try! MessageContentCodec.decode(message.content) else {
            XCTFail("expected a sent CallStart")
            return ""
        }
        return callId
    }
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `swift test --filter CallManagerTests`
Expected: FAIL — `CallManager` 还不存在,编译错误。

- [ ] **Step 4: 实现 `CallManager`**

创建 `Sources/IMCall/CallManager.swift`:

```swift
import Foundation
import Combine
import IMProto
import IMStorage
import IMMessaging

/// The single state-machine + coordination entry point for one-to-one
/// calling — see the Phase 3 design doc §3. Owns at most one `CallSession`
/// at a time. UI (`IMKit`) drives it through `startCall`/`answer`/
/// `reject`/`hangUp`; `WebRTCClient` (Task 12) drives it through
/// `MediaEngine`'s callbacks; `ReceiveMessageHandler` (via
/// `MessagingService`'s forwarding properties) drives it through incoming
/// call signals.
///
/// **Threading contract:** like the rest of this codebase, no internal
/// locking — must be driven from a single consistent queue (by convention
/// main), matching `IMClient`'s own threading contract.
public final class CallManager {
    @Published public private(set) var state: CallState = .idle
    @Published public private(set) var audioOnly: Bool = false
    public private(set) var peerUid: String?

    /// Fired when an incoming CallStart arrives and is accepted into
    /// `.incoming` state (i.e. not auto-rejected as busy, see Task 9) — the
    /// App-target `CXProvider` adapter wires this to `reportNewIncomingCall`.
    public var onIncomingCall: ((_ peerUid: String, _ audioOnly: Bool) -> Void)?
    /// Fired every time a call ends, for any reason — UI dismisses the
    /// call screen, CallKit adapter reports the end.
    public var onCallEnded: ((CallEndReason) -> Void)?

    private static let answerTimeoutSeconds: TimeInterval = 60
    private static let connectingTimeoutSeconds: TimeInterval = 60

    private let messagingService: MessagingService
    private let storage: IMStorage
    private let mediaEngine: MediaEngine
    private let scheduler: Scheduler
    private let myUserId: () -> String
    private let nowMillis: () -> Int64

    private var session: CallSession?
    private var pendingRemoteOfferSDP: String?
    private var answerTimeoutToken: SchedulerToken?
    private var connectingTimeoutToken: SchedulerToken?

    public init(
        messagingService: MessagingService,
        storage: IMStorage,
        mediaEngine: MediaEngine,
        scheduler: Scheduler = DispatchQueueScheduler(),
        myUserId: @escaping () -> String,
        nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.messagingService = messagingService
        self.storage = storage
        self.mediaEngine = mediaEngine
        self.scheduler = scheduler
        self.myUserId = myUserId
        self.nowMillis = nowMillis

        mediaEngine.onConnected = { [weak self] in self?.handleMediaConnected() }
        mediaEngine.onDisconnected = { [weak self] in self?.handleMediaDisconnected() }
        mediaEngine.onLocalCandidate = { [weak self] index, mid, candidate in
            self?.handleLocalCandidate(sdpMLineIndex: index, sdpMid: mid, candidate: candidate)
        }
        messagingService.onCallSignal = { [weak self] wireMessage in self?.handleIncomingSignal(wireMessage) }
        // `messagingService.onCallStartMessage = ...` is wired in Task 9,
        // alongside the `handleIncomingCallStart` method it drives — there
        // is nothing in this task's scope for it to call yet.
    }

    // MARK: - Outgoing

    public func startCall(to peerUid: String, audioOnly: Bool) throws {
        guard state == .idle else { return }
        let callId = UUID().uuidString
        let stored = try messagingService.sendCallStart(targetId: peerUid, callId: callId, audioOnly: audioOnly)

        session = CallSession(callId: callId, peerUid: peerUid, audioOnly: audioOnly, localMessageRowId: stored.id)
        self.audioOnly = audioOnly
        self.peerUid = peerUid
        state = .outgoing

        mediaEngine.start(audioOnly: audioOnly)
        startAnswerTimeoutTimer()
        mediaEngine.createOffer { [weak self] sdp in
            guard let self, let session = self.session else { return }
            try? self.sendSignal(.sdpOffer(callId: session.callId, sdp: sdp), to: session.peerUid)
        }
    }

    // MARK: - Incoming

    public func answer() throws {
        guard state == .incoming, let session else { return }
        answerTimeoutToken?.cancel()
        try sendSignal(.answer(callId: session.callId, audioOnly: session.audioOnly), to: session.peerUid)
        mediaEngine.start(audioOnly: session.audioOnly)
        state = .connecting
        startConnectingTimeoutTimer()

        if let offerSDP = pendingRemoteOfferSDP {
            pendingRemoteOfferSDP = nil
            mediaEngine.createAnswer(forRemoteOffer: offerSDP) { [weak self] answerSDP in
                guard let self, let session = self.session else { return }
                try? self.sendSignal(.sdpAnswer(callId: session.callId, sdp: answerSDP), to: session.peerUid)
            }
        }
    }

    public func reject() throws { try hangUp(reason: .localHangup) }
    public func hangUp() throws { try hangUp(reason: .localHangup) }

    private func hangUp(reason: CallEndReason) throws {
        guard let session else { return }
        try sendSignal(.bye(callId: session.callId), to: session.peerUid)
        endSession(reason: reason)
    }

    // MARK: - Incoming signal dispatch (401-404 via `MessagingService.onCallSignal`)

    private func handleIncomingSignal(_ wireMessage: Im_Message) {
        guard let signal = CallSignalCodec.decode(wireMessage), matchesCurrentCall(signal) else { return }
        switch signal {
        case .answer:
            guard state == .outgoing else { return }
            state = .connecting
            startConnectingTimeoutTimer()
        case .bye:
            endSession(reason: .remoteBye)
        case .sdpOffer(_, let sdp):
            if state == .connecting {
                mediaEngine.createAnswer(forRemoteOffer: sdp) { [weak self] answerSDP in
                    guard let self, let session = self.session else { return }
                    try? self.sendSignal(.sdpAnswer(callId: session.callId, sdp: answerSDP), to: session.peerUid)
                }
            } else {
                pendingRemoteOfferSDP = sdp
            }
        case .sdpAnswer(_, let sdp):
            mediaEngine.setRemoteAnswer(sdp)
        case .iceCandidate(_, let index, let mid, let candidate):
            mediaEngine.addRemoteCandidate(sdpMLineIndex: index, sdpMid: mid, candidate: candidate)
        case .modify(_, let newAudioOnly):
            self.audioOnly = newAudioOnly
            mediaEngine.setAudioOnly(newAudioOnly)
        }
    }

    private func matchesCurrentCall(_ signal: IncomingCallSignal) -> Bool {
        guard let session else { return false }
        switch signal {
        case .answer(let callId, _), .bye(let callId), .sdpOffer(let callId, _), .sdpAnswer(let callId, _), .iceCandidate(let callId, _, _, _), .modify(let callId, _):
            return callId == session.callId
        }
    }

    // MARK: - MediaEngine callbacks

    private func handleMediaConnected() {
        guard state == .connecting else { return }
        connectingTimeoutToken?.cancel()
        state = .connected
        session?.connectTime = nowMillis()
        updateCallBubble(status: 1, endTime: 0)
    }

    private func handleMediaDisconnected() {
        guard state == .connected || state == .connecting else { return }
        try? hangUp(reason: .mediaFailure)
    }

    private func handleLocalCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String) {
        guard let session else { return }
        try? sendSignal(.iceCandidate(callId: session.callId, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid, candidate: candidate), to: session.peerUid)
    }

    // MARK: - Timers

    private func startAnswerTimeoutTimer() {
        answerTimeoutToken = scheduler.scheduleOnce(after: Self.answerTimeoutSeconds) { [weak self] in self?.timeoutFired() }
    }

    private func startConnectingTimeoutTimer() {
        connectingTimeoutToken = scheduler.scheduleOnce(after: Self.connectingTimeoutSeconds) { [weak self] in self?.timeoutFired() }
    }

    private func timeoutFired() {
        guard session != nil else { return }
        try? hangUp(reason: .timeout)
    }

    // MARK: - Ending a call

    private func endSession(reason: CallEndReason) {
        answerTimeoutToken?.cancel()
        connectingTimeoutToken?.cancel()
        updateCallBubble(status: 2, endTime: nowMillis())
        mediaEngine.close()
        session = nil
        pendingRemoteOfferSDP = nil
        state = .idle
        peerUid = nil
        onCallEnded?(reason)
    }

    private func updateCallBubble(status: Int, endTime: Int64) {
        guard let session, let rowId = session.localMessageRowId else { return }
        let content = MessageContent.callRecord(
            callId: session.callId,
            targetId: session.peerUid,
            audioOnly: session.audioOnly,
            status: status,
            connectTime: session.connectTime,
            endTime: endTime
        )
        try? storage.messages.updateContent(id: rowId, content: content)
    }

    private func sendSignal(_ signal: OutgoingCallSignal, to peerUid: String) throws {
        let encoded = CallSignalCodec.encode(signal)
        try messagingService.sendCallControlMessage(to: peerUid, wireType: encoded.wireType, callId: encoded.callId, dataPayload: encoded.data)
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test --filter CallManagerTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMCall/CallManager.swift Tests/IMCallTests/Support/FakeTransportConnection.swift Tests/IMCallTests/CallManagerTests.swift
git commit -m "feat(IMCall): add CallManager outgoing-call state machine and SDP/ICE signal plumbing"
```

## Task 9: `CallManager` — incoming call arrival, busy auto-reject, glare

**Files:**
- Modify: `Sources/IMCall/CallManager.swift`
- Modify: `Tests/IMCallTests/CallManagerTests.swift`

**Glare rule** (design doc §5): if both sides dial each other at the same moment, compare uids as strings — the smaller uid's call continues, the larger uid's side abandons its own outgoing call and accepts the other side's incoming call instead. Both sides run the identical comparison, so the outcomes are always complementary (never both-win or both-lose).

- [ ] **Step 1: 写失败的测试**

在 `Tests/IMCallTests/CallManagerTests.swift` 末尾(在 `// MARK: - Helpers` 块之前)追加:

```swift
    func test_receivingCallStartWhileIdle_transitionsToIncomingAndFiresCallback() throws {
        var capturedPeer: String?
        var capturedAudioOnly: Bool?
        manager.onIncomingCall = { peer, audioOnly in capturedPeer = peer; capturedAudioOnly = audioOnly }

        try deliverCallStart(callId: "call-incoming-1", audioOnly: true, from: "them")

        XCTAssertEqual(manager.state, .incoming)
        XCTAssertEqual(manager.peerUid, "them")
        XCTAssertEqual(capturedPeer, "them")
        XCTAssertEqual(capturedAudioOnly, true)
    }

    func test_receivingCallStartWhileIdle_startsAnswerTimeoutTimer() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")
        XCTAssertTrue(scheduler.scheduledDelays.contains(60))
    }

    func test_answer_onIncomingCall_sendsAnswerSignalAndTransitionsToConnecting() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")

        try manager.answer()

        XCTAssertEqual(manager.state, .connecting)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 401 })
    }

    func test_answer_withAlreadyBufferedOffer_createsAndSendsAnswerSDP() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")
        try deliverSignal(.sdpOffer(callId: "call-incoming-1", sdp: "remote-offer-sdp"), from: "them")

        try manager.answer()

        XCTAssertEqual(mediaEngine.createAnswerCalls, ["remote-offer-sdp"])
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .sdpAnswer(callId: "call-incoming-1", sdp: mediaEngine.answerSDPToReturn) })
    }

    func test_offerArrivingAfterAnswer_createsAndSendsAnswerSDPImmediately() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")
        try manager.answer() // no offer buffered yet

        try deliverSignal(.sdpOffer(callId: "call-incoming-1", sdp: "late-offer-sdp"), from: "them")

        XCTAssertEqual(mediaEngine.createAnswerCalls, ["late-offer-sdp"])
    }

    func test_secondCallStartWhileBusy_autoRejectsWithBye() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()

        try deliverCallStart(callId: "call-2", audioOnly: false, from: "someone-else", target: "me")

        XCTAssertEqual(manager.state, .connecting) // untouched — still the original call
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "call-2") })
    }

    func test_glare_myUidSmaller_myOutgoingCallContinues_rejectsTheirs() throws {
        // "me" < "them" lexicographically — I win.
        try manager.startCall(to: "them", audioOnly: false)
        let myCallId = callIdFromLastCallStart()

        try deliverCallStart(callId: "their-call-id", audioOnly: false, from: "them")

        XCTAssertEqual(manager.state, .outgoing) // my call is untouched
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "their-call-id") })
        _ = myCallId
    }

    func test_glare_myUidLarger_abandonsMyOutgoingAndAcceptsTheirs() throws {
        // "me" > "a" lexicographically — I lose, and accept their call instead.
        let losingManager = CallManager(messagingService: messagingService, storage: storage, mediaEngine: mediaEngine, scheduler: scheduler, myUserId: { "me" })
        try losingManager.startCall(to: "a", audioOnly: false)
        var capturedPeer: String?
        losingManager.onIncomingCall = { peer, _ in capturedPeer = peer }

        try deliverCallStart(callId: "their-call-id", audioOnly: true, from: "a", target: "me", manager: losingManager)

        XCTAssertEqual(losingManager.state, .incoming)
        XCTAssertEqual(capturedPeer, "a")
    }

    // MARK: - Helpers
```

并把 helper 区里的 `callIdFromLastCallStart()` 之后追加两个新 helper(`deliverCallStart`/给 `deliverSignal` 加可选 `target`/`manager` 参数,默认值保持其余测试不用改):

```swift
    private func deliverSignal(_ signal: OutgoingCallSignal, from: String, target: String = "me", manager: CallManager? = nil) throws {
        let encoded = CallSignalCodec.encode(signal)
        var wireMessage = Im_Message()
        wireMessage.messageID = Int64.random(in: 1_000_000...9_999_999)
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = target
        wireMessage.conversation.line = 0
        var content = Im_MessageContent()
        content.type = encoded.wireType
        content.searchableContent = encoded.callId
        if let data = encoded.data { content.data = data }
        wireMessage.content = content
        wireMessage.serverTimestamp = 1_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = wireMessage.messageID
        result.head = wireMessage.messageID
        let body = Data([0x00]) + (try result.serializedData())
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body))
    }

    private func deliverCallStart(callId: String, audioOnly: Bool, from: String, target: String = "me", manager: CallManager? = nil) throws {
        var wireMessage = Im_Message()
        wireMessage.messageID = Int64.random(in: 1_000_000...9_999_999)
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = target
        wireMessage.conversation.line = 0
        wireMessage.content = MessageContentCodec.encode(.callRecord(callId: callId, targetId: target, audioOnly: audioOnly, status: 0, connectTime: 0, endTime: 0))
        wireMessage.serverTimestamp = 1_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = wireMessage.messageID
        result.head = wireMessage.messageID
        let body = Data([0x00]) + (try result.serializedData())
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body))
    }
```

注意:Step 2 这里 `deliverSignal` 的签名比 Task 8 写的多了 `target`/`manager` 两个默认参数 —— 这是对 Task 8 已有同名方法的**替换**(整个方法体替换成上面这版,而不是新增一个重载),因为 Swift 不允许两个仅默认参数不同的重载共存导致的歧义;`manager` 参数本身在这两个新 helper 里实际没有被使用到(`fakeTransport.simulateReceivedData` 是全局共享的,不区分"哪个 manager 收到"),保留这个参数只是为了让 `test_glare_myUidLarger_...` 测试的调用点读起来更清楚是说给 `losingManager` 听的——如果觉得这个未使用参数没必要,实现时可以直接去掉,不影响其他测试(没有测试断言这个参数本身做了什么)。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter CallManagerTests`
Expected: FAIL — 新测试里用到的 `deliverCallStart` 还不存在(编译错误),且就算编译过,`handleIncomingCallStart` 当前是空函数体,所有新断言会失败。

- [ ] **Step 3: 实现**

在 `Sources/IMCall/CallManager.swift` 的 `init` 里,把 Task 8 留的注释行替换成真正的赋值:

```swift
        messagingService.onCallStartMessage = { [weak self] message in self?.handleIncomingCallStart(message) }
```

在 `// MARK: - MediaEngine callbacks` 这一行**之前**插入:

```swift
    // MARK: - Incoming CallStart

    private func handleIncomingCallStart(_ message: StoredMessage) {
        guard case .callRecord(let callId, _, let audioOnlyFlag, _, _, _) = message.content else { return }
        let callerUid = message.from

        if state == .outgoing, let session, session.peerUid == callerUid {
            // Glare: both sides dialed each other at the same moment — see
            // this task's doc comment for the resolution rule.
            if myUserId() < callerUid {
                try? sendSignal(.bye(callId: callId), to: callerUid)
                return
            } else {
                answerTimeoutToken?.cancel()
                acceptIncomingCall(callId: callId, callerUid: callerUid, audioOnly: audioOnlyFlag, localMessageRowId: message.id)
                return
            }
        }

        guard state == .idle else {
            try? sendSignal(.bye(callId: callId), to: callerUid) // busy — auto-reject
            return
        }

        acceptIncomingCall(callId: callId, callerUid: callerUid, audioOnly: audioOnlyFlag, localMessageRowId: message.id)
    }

    private func acceptIncomingCall(callId: String, callerUid: String, audioOnly: Bool, localMessageRowId: Int64?) {
        session = CallSession(callId: callId, peerUid: callerUid, audioOnly: audioOnly, localMessageRowId: localMessageRowId)
        self.audioOnly = audioOnly
        peerUid = callerUid
        state = .incoming
        startAnswerTimeoutTimer()
        onIncomingCall?(callerUid, audioOnly)
    }

```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter CallManagerTests`
Expected: PASS

- [ ] **Step 5: 跑一遍 IMCall 全量测试**

Run: `swift test --filter IMCallTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMCall/CallManager.swift Tests/IMCallTests/CallManagerTests.swift
git commit -m "feat(IMCall): handle incoming CallStart with busy auto-reject and glare resolution"
```

## Task 10: 会话气泡渲染 `.callRecord`(复用现有文本气泡,不新建 Cell 类型)

**Files:**
- Modify: `Sources/IMKit/ConversationViewModel.swift`
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift`

设计文档 §2 的"气泡文案规则"还没有落地——`ConversationViewModel.makeRow(_:)` 对 `message.content` 是穷举 `switch`,Task 1 给 `MessageContent` 加了 `.callRecord` case 之后,这个 `switch` 缺一个分支,**整个 `IMKit` target 编译不过**,不是这次新加的边界情况,是必须修的编译错误。

落地方式选最省事的一种:`.callRecord` 不需要居中的系统提示样式(那是 `groupNotification` 的展现方式),它是一条正常的、分左右的消息气泡(类似 Android 的 `"[网络电话]"` digest),所以直接复用现成的 `.message(StoredMessageRow(...))` 路径,把 `text` 字段换成算好的通话摘要文案就行,不用新建 Cell 类型。

- [ ] **Step 1: 写失败的测试**

`Tests/IMKitTests/ConversationViewModelTests.swift` 的 `setUpWithError` 已经构造好了 `viewModel`(`target: "them"`、`currentUserId: "me"`)——测试都是往 `storage.messages.insert(...)` 写真实数据,用文件里现成的 `waitForFirstNonEmptyRows()` helper 等响应式查询把新行推过来,再读 `viewModel.rows`。在文件末尾追加:

```swift
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
            content: .callRecord(callId: "call-1", targetId: "them", audioOnly: false, status: 2, connectTime: 0, endTime: 30_000),
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ConversationViewModelTests`
Expected: FAIL —`switch message.content`没有 `.callRecord` 分支,编译错误。

- [ ] **Step 3: 实现**

在 `Sources/IMKit/ConversationViewModel.swift` 的 `makeRow(_:)` 里,`case .groupNotification(...)` 分支之后追加:

```swift
        case .callRecord(_, _, let audioOnly, let status, let connectTime, let endTime):
            return .message(buildStoredMessageRow(message, text: renderCallRecordText(isOutgoing: message.direction == .send, audioOnly: audioOnly, status: status, connectTime: connectTime, endTime: endTime), imageThumbnail: nil, imageRemoteURL: nil))
```

在 `renderSystemTipText` 方法之后追加一个新方法:

```swift
    /// Bubble text for a `.callRecord` row — design doc §2's rule: status 2
    /// with a real `connectTime` shows duration; status 2 with no
    /// `connectTime` (call never connected) shows "已取消" from the caller's
    /// side, "未接听" from the callee's side. Status 0/1 rows are only ever
    /// momentarily on screen mid-call (this device's own `CallManager`
    /// updates them to status 2 the instant the call ends) and don't need
    /// distinct wording.
    private func renderCallRecordText(isOutgoing: Bool, audioOnly: Bool, status: Int, connectTime: Int64, endTime: Int64) -> String {
        let icon = audioOnly ? "📞" : "📹"
        let kind = audioOnly ? "语音通话" : "视频通话"
        guard status == 2 else { return "\(icon) \(kind)" }
        guard connectTime > 0 else { return isOutgoing ? "\(icon) 已取消" : "\(icon) 未接听" }
        let durationSeconds = Int(max(0, (endTime - connectTime) / 1000))
        return String(format: "\(icon) \(kind) %02d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ConversationViewModelTests`
Expected: PASS

- [ ] **Step 5: 跑一遍 IMKit 全量测试,确认穷举 switch 修复没漏改别的地方**

Run: `swift test --filter IMKitTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMKit/ConversationViewModel.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat(IMKit): render callRecord messages as chat bubbles with duration/outcome text"
```

---

**Everything from here down (Tasks 11-16) touches real WebRTC, CallKit, or UIKit** — none of it runs under `swift test` (no simulator microphone/camera, no `CXProvider` in a test host). Each task still gets exact, complete code (no placeholders), but verification is the manual walkthrough described in each task's last step, matching how this codebase already treats hardware-dependent code (see the design doc §6 and Phase 1's own testing-strategy section: "ViewController 层不强制覆盖,关键路径手工走查").

## Task 11: `AppConfig` TURN servers + `IMCall`'s WebRTC SPM dependency

**Files:**
- Modify: `Sources/AppCore/AppConfig.swift`
- Modify: `Package.swift`
- Modify: `project.yml`

- [ ] **Step 1: 加 TURN 配置**

把 `Sources/AppCore/AppConfig.swift` 整个内容替换成:

```swift
import Foundation

/// Server addresses. Defaults reuse the values already configured for the
/// existing Android client (`android-chat-pro`'s `Config.java`) — real,
/// currently-deployed addresses, not placeholders.
public struct AppConfig {
    public struct IceServer {
        public var urlString: String
        public var username: String
        public var credential: String

        public init(urlString: String, username: String, credential: String) {
            self.urlString = urlString
            self.username = username
            self.credential = credential
        }
    }

    public var apiBaseURL: URL
    public var imHosts: String
    public var imPort: UInt16
    public var iceServers: [IceServer]

    public init(apiBaseURL: URL, imHosts: String, imPort: UInt16, iceServers: [IceServer]) {
        self.apiBaseURL = apiBaseURL
        self.imHosts = imHosts
        self.imPort = imPort
        self.iceServers = iceServers
    }

    public static let production = AppConfig(
        apiBaseURL: URL(string: "https://backend-http.fsharechat.cn")!,
        imHosts: "backend-tcp.fsharechat.cn:backend-tcp-s2.fsharechat.cn",
        imPort: 6789,
        // Same TURN servers `android-chat-pro`'s `Config.java` already
        // points at in production — `chat-server-pro` plays no part in ICE
        // server distribution (see the Phase 3 design doc §3), so this is
        // the one place to change them later.
        iceServers: [
            IceServer(urlString: "turn:turn.fsharechat.cn:3478", username: "comsince", credential: "comsince"),
            IceServer(urlString: "turn:sh-turn.fsharechat.cn:3478", username: "comsince", credential: "comsince"),
        ]
    )
}
```

- [ ] **Step 2: 跑一遍 AppCore 测试,确认 `AppConfig.production` 的新增字段没改坏既有断言**

Run: `swift test --filter AppCoreTests`
Expected: PASS — `Sources/AppConfig.swift` 是唯一一处构造 `AppConfig(...)` 的地方(`.production`),`Tests/AppCoreTests` 里没有别的调用点要改。

- [ ] **Step 3: `IMCall` 接入 WebRTC SPM 包**

在 `Package.swift` 的 `dependencies` 数组里(`GRDB.swift` 之后)追加:

```swift
        .package(url: "https://github.com/stasel/WebRTC.git", from: "137.0.0"),
```

把 `IMCall` 的 target 声明改成:

```swift
        .target(name: "IMCall", dependencies: ["IMMessaging", "IMStorage", "IMProto", "IMClient", .product(name: "WebRTC", package: "WebRTC")]),
```

> 这里的版本号 `137.0.0` 是占位起点,不是确认过的真实版本——`stasel/WebRTC` 跟着 Chromium 的版本号走,实现这个任务时需要先看一下该仓库当前 release 列表选一个真实存在的最新版本号填进去,不能直接照抄这个数字上线。这是设计文档风险 #1 已经标注过的"社区维护版本节奏"问题,不是这个计划新引入的不确定性。

- [ ] **Step 4: `project.yml` 加摄像头/麦克风权限说明 + App target 依赖 `IMCall`**

在 `project.yml` 的 `App.info.properties` 里(`NSAppTransportSecurity` 之后)追加:

```yaml
        NSCameraUsageDescription: "视频通话需要使用摄像头"
        NSMicrophoneUsageDescription: "语音/视频通话需要使用麦克风"
```

在 `App.dependencies` 列表里(`IMKit` 之后)追加:

```yaml
      - package: IMCore
        product: IMCall
```

- [ ] **Step 5: 重新生成 xcodeproj**

Run: `Scripts/generate-xcodeproj.sh`
Expected: 成功重新生成 `ios-chat-pro.xcodeproj`,无报错

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/AppConfig.swift Package.swift project.yml ios-chat-pro.xcodeproj
git commit -m "feat: add ICE server config and wire IMCall's WebRTC SPM dependency"
```

## Task 12: `WebRTCClient` — real `MediaEngine` conformer

**Files:**
- Create: `Sources/IMCall/WebRTCClient.swift`

No unit tests — `RTCPeerConnection`/`RTCCameraVideoCapturer` need a real device or at minimum a simulator with camera/mic entitlements that XCTest's test host doesn't have. This is exercised by Task 16's manual two-device walkthrough instead. The code below uses `WebRTC.framework`'s standard Objective-C-bridged API (`RTCPeerConnectionFactory`/`RTCPeerConnection`/`RTCCameraVideoCapturer` etc.), which `stasel/WebRTC` repackages unchanged from Google's upstream — exact method signatures can shift a point release or two between WebRTC versions, so treat this step's code as "compile and fix the inevitable small signature mismatches against whatever version Task 11 actually pinned," not as guaranteed-correct-as-written.

- [ ] **Step 1: 实现**

创建 `Sources/IMCall/WebRTCClient.swift`:

```swift
import WebRTC
import AppCore

/// The production `MediaEngine` — wraps a single `RTCPeerConnection` at a
/// time (Phase 3 is one-to-one only, see the design doc §1; group calling's
/// mesh-of-peer-connections is explicitly out of scope). One long-lived
/// instance is reused across consecutive calls (constructed once in
/// `AppEnvironment`, alongside the equally long-lived `CallManager` that
/// owns it — Task 15's job): `close()` tears every property below back
/// down to `nil`, and the next call's `start(audioOnly:)` rebuilds them
/// from scratch, so there's no state to carry over between calls.
public final class WebRTCClient: NSObject, MediaEngine {
    public var onLocalCandidate: ((Int32, String, String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: (() -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let iceServers: [AppConfig.IceServer]
    private var peerConnection: RTCPeerConnection?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    /// Used by `CallManager.handleMediaConnected`/`handleMediaDisconnected`
    /// to fire `onConnected`/`onDisconnected` exactly once per transition,
    /// rather than on every ICE state change `RTCPeerConnectionDelegate`
    /// reports (it reports several, including transient ones).
    private var hasReportedConnected = false

    public init(iceServers: [AppConfig.IceServer]) {
        self.iceServers = iceServers
        super.init()
    }

    public func attachLocalRenderer(_ renderer: RTCVideoRenderer) {
        localVideoTrack?.add(renderer)
    }

    public func attachRemoteRenderer(_ renderer: RTCVideoRenderer) {
        peerConnection?.transceivers
            .compactMap { $0.receiver.track as? RTCVideoTrack }
            .first?
            .add(renderer)
    }

    public func start(audioOnly: Bool) {
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: [$0.urlString], username: $0.username, credential: $0.credential)
        }
        configuration.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: nil)
        connection.delegate = self
        peerConnection = connection

        let audioTrack = Self.factory.audioTrack(withTrackId: "audio0")
        localAudioTrack = audioTrack
        connection.add(audioTrack, streamIds: ["stream0"])

        if !audioOnly {
            let videoSource = Self.factory.videoSource()
            let capturer = RTCCameraVideoCapturer(delegate: videoSource)
            videoCapturer = capturer
            let videoTrack = Self.factory.videoTrack(with: videoSource, trackId: "video0")
            localVideoTrack = videoTrack
            connection.add(videoTrack, streamIds: ["stream0"])
            startCapture(front: true)
        }
    }

    /// Front camera by default — matches the chosen in-call UI (design doc
    /// §4): the small local-preview window starts on the selfie camera.
    private func startCapture(front: Bool) {
        guard let capturer = videoCapturer else { return }
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }),
              let format = RTCCameraVideoCapturer.supportedFormats(for: device).first,
              let fpsRange = format.videoSupportedFrameRateRanges.first
        else { return }
        capturer.startCapture(with: device, format: format, fps: Int(fpsRange.maxFrameRate))
    }

    public func createOffer(completion: @escaping (String) -> Void) {
        guard let connection = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection.offer(for: constraints) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            connection.setLocalDescription(sdp) { _ in
                completion(sdp.sdp)
            }
        }
    }

    public func createAnswer(forRemoteOffer sdp: String, completion: @escaping (String) -> Void) {
        guard let connection = peerConnection else { return }
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        connection.setRemoteDescription(remoteDescription) { [weak self] _ in
            guard let self else { return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            connection.answer(for: constraints) { answerSDP, _ in
                guard let answerSDP else { return }
                connection.setLocalDescription(answerSDP) { _ in
                    completion(answerSDP.sdp)
                }
            }
        }
    }

    public func setRemoteAnswer(_ sdp: String) {
        let remoteDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        peerConnection?.setRemoteDescription(remoteDescription) { _ in }
    }

    public func addRemoteCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String) {
        let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        peerConnection?.add(iceCandidate)
    }

    public func setAudioOnly(_ audioOnly: Bool) {
        localVideoTrack?.isEnabled = !audioOnly
    }

    public func setMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    private var isUsingFrontCamera = true

    public func switchCamera() {
        isUsingFrontCamera.toggle()
        videoCapturer?.stopCapture()
        startCapture(front: isUsingFrontCamera)
    }

    public func close() {
        videoCapturer?.stopCapture()
        peerConnection?.close()
        peerConnection = nil
        videoCapturer = nil
        localVideoTrack = nil
        localAudioTrack = nil
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed:
            guard !hasReportedConnected else { return }
            hasReportedConnected = true
            onConnected?()
        case .failed, .disconnected, .closed:
            guard hasReportedConnected else { return } // never reached .connected — CallManager's own 60s connecting-timeout handles that path
            onDisconnected?()
        default:
            break
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalCandidate?(candidate.sdpMLineIndex, candidate.sdpMid ?? "", candidate.sdp)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
```

- [ ] **Step 2: 编译确认**

Run: `swift build`
Expected: 编译成功。如果 `stasel/WebRTC` 当前版本的某个 API 签名跟上面写的不完全一致(常见的会变的点:`RTCPeerConnectionFactory.peerConnection(with:constraints:delegate:)` 的参数顺序/可选性,`offer(for:)`/`answer(for:)` 回调的 error 类型),照编译器报错逐一修正方法签名,不要改动整体结构(职责分配、`MediaEngine` 协议的调用时机)。

- [ ] **Step 3: Commit**

```bash
git add Sources/IMCall/WebRTCClient.swift
git commit -m "feat(IMCall): add WebRTCClient, the production MediaEngine conformer"
```

## Task 13: `CallKitAdapting` protocol + `CallManager` wiring + App target `CXProvider`

**Files:**
- Create: `Sources/IMCall/CallKitAdapting.swift`
- Modify: `Sources/IMCall/CallManager.swift`
- Modify: `Tests/IMCallTests/CallManagerTests.swift`
- Create: `App/CallKitProvider.swift`

`CallKitAdapting` keeps `IMCall` itself free of a CallKit import (so `CallManagerTests` stays a plain XCTest target, no `CXProvider` involved) — `CallManager` only calls through the protocol; the real `CXProvider`/`CXProviderDelegate` work lives in `App/CallKitProvider.swift`, which is **not** unit-tested (same reasoning as `WebRTCClient`: needs a real device's telephony stack).

- [ ] **Step 1: 写失败的测试(`CallManager` 调用 `callKitAdapter` 的时机)**

创建一个 fake 放进 `Tests/IMCallTests/Support/FakeCallKitAdapter.swift`:

```swift
import Foundation
@testable import IMCall

final class FakeCallKitAdapter: CallKitAdapting {
    private(set) var reportedIncomingCalls: [(callId: String, callerName: String, audioOnly: Bool)] = []
    private(set) var reportedOutgoingStarted: [String] = []
    private(set) var reportedConnected: [String] = []
    private(set) var reportedEnded: [(callId: String, reason: CallEndReason)] = []

    func reportIncomingCall(callId: String, callerName: String, audioOnly: Bool, completion: @escaping (Error?) -> Void) {
        reportedIncomingCalls.append((callId, callerName, audioOnly))
        completion(nil)
    }

    func reportOutgoingCallStarted(callId: String) {
        reportedOutgoingStarted.append(callId)
    }

    func reportConnected(callId: String) {
        reportedConnected.append(callId)
    }

    func reportCallEnded(callId: String, reason: CallEndReason) {
        reportedEnded.append((callId, reason))
    }
}
```

在 `Tests/IMCallTests/CallManagerTests.swift` 的 `setUpWithError` 里,`manager = CallManager(...)` 这一行之后追加:

```swift
        callKitAdapter = FakeCallKitAdapter()
        manager.callKitAdapter = callKitAdapter
```

并在类的属性声明区(`private var manager: CallManager!` 之后)加一行:

```swift
    private var callKitAdapter: FakeCallKitAdapter!
```

在文件末尾(`// MARK: - Helpers` 之前)追加:

```swift
    func test_startCall_reportsOutgoingCallStartedToCallKit() throws {
        try manager.startCall(to: "them", audioOnly: false)
        XCTAssertEqual(callKitAdapter.reportedOutgoingStarted, [callIdFromLastCallStart()])
    }

    func test_incomingCallStart_reportsIncomingCallToCallKit() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: true, from: "them")
        XCTAssertEqual(callKitAdapter.reportedIncomingCalls.first?.callId, "call-incoming-1")
        XCTAssertEqual(callKitAdapter.reportedIncomingCalls.first?.callerName, "them")
        XCTAssertEqual(callKitAdapter.reportedIncomingCalls.first?.audioOnly, true)
    }

    func test_mediaEngineConnected_reportsConnectedToCallKit() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")

        mediaEngine.simulateConnected()

        XCTAssertEqual(callKitAdapter.reportedConnected, [callId])
    }

    func test_hangUp_reportsCallEndedToCallKit() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()

        try manager.hangUp()

        XCTAssertEqual(callKitAdapter.reportedEnded.first?.callId, callId)
        XCTAssertEqual(callKitAdapter.reportedEnded.first?.reason, .localHangup)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter CallManagerTests`
Expected: FAIL — `CallManager` 没有 `callKitAdapter` 属性,`CallKitAdapting` 协议不存在,编译错误。

- [ ] **Step 3: 创建协议**

创建 `Sources/IMCall/CallKitAdapting.swift`:

```swift
import Foundation

/// `CallManager`'s view of CallKit — kept as a protocol so `IMCall` itself
/// never imports CallKit (see the Phase 3 design doc §3: CallKit
/// integration lives in the App target, behind this protocol). The App
/// target's `CallKitProvider` (`App/CallKitProvider.swift`) is the real
/// conformer; `Tests/IMCallTests/Support/FakeCallKitAdapter.swift` is the
/// test double.
public protocol CallKitAdapting: AnyObject {
    /// `completion` carries whatever `CXProvider.reportNewIncomingCall`'s
    /// own completion handler reported (e.g. the system refusing the call
    /// because Do Not Disturb / call blocking is active) — `CallManager`
    /// doesn't currently act on a non-nil error (Phase 3 has no UX for
    /// "the system itself refused this call"), but the signature carries
    /// it through rather than silently swallowing it.
    func reportIncomingCall(callId: String, callerName: String, audioOnly: Bool, completion: @escaping (Error?) -> Void)
    func reportOutgoingCallStarted(callId: String)
    func reportConnected(callId: String)
    func reportCallEnded(callId: String, reason: CallEndReason)
}
```

- [ ] **Step 4: `CallManager` 接入 `callKitAdapter`**

在 `Sources/IMCall/CallManager.swift` 里,`public var onCallEnded: ((CallEndReason) -> Void)?` 之后追加:

```swift
    /// Set by the App target after constructing both this `CallManager`
    /// and its `CallKitProvider` — `nil` is a valid state (e.g. in every
    /// `CallManagerTests` test that doesn't explicitly set
    /// `FakeCallKitAdapter`), every call site below uses optional chaining.
    public var callKitAdapter: CallKitAdapting?
```

在 `startCall(to:audioOnly:)` 里,`state = .outgoing` 这一行之后追加:

```swift
        callKitAdapter?.reportOutgoingCallStarted(callId: callId)
```

在 `acceptIncomingCall(callId:callerUid:audioOnly:localMessageRowId:)` 里,`onIncomingCall?(callerUid, audioOnly)` 这一行之前追加:

```swift
        callKitAdapter?.reportIncomingCall(callId: callId, callerName: callerUid, audioOnly: audioOnly, completion: { _ in })
```

在 `handleMediaConnected()` 里,`updateCallBubble(status: 1, endTime: 0)` 这一行之后追加:

```swift
        if let session { callKitAdapter?.reportConnected(callId: session.callId) }
```

在 `endSession(reason:)` 里,在 `updateCallBubble(status: 2, endTime: nowMillis())` 这一行**之前**插入(必须在 `session = nil` 之前读取 `callId`):

```swift
        if let session { callKitAdapter?.reportCallEnded(callId: session.callId, reason: reason) }
```

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test --filter CallManagerTests`
Expected: PASS

- [ ] **Step 6: 创建 App target 的真实 `CXProvider` 适配器**

创建 `App/CallKitProvider.swift`:

```swift
// App/CallKitProvider.swift
import Foundation
import CallKit
import IMCall

/// Bridges `CallManager` to the system telephony UI. Constructed once in
/// `AppEnvironment` alongside `CallManager` (Task 15), assigned to
/// `callManager.callKitAdapter`, and given a back-reference to the same
/// `CallManager` so its `CXProviderDelegate` callbacks (user tapped
/// answer/decline on the system call screen) can drive it back.
final class CallKitProvider: NSObject, CallKitAdapting {
    private let provider: CXProvider
    private let callController = CXCallController()
    private weak var callManager: CallManager?
    /// CallKit identifies calls by `UUID`, call signaling identifies them
    /// by the `String` `callId` used on the wire — this is the mapping
    /// between the two for the one call in progress (Phase 3 is
    /// one-to-one only, see the design doc §1).
    private var currentCallUUID: UUID?
    private var currentCallId: String?

    init(callManager: CallManager) {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        provider = CXProvider(configuration: configuration)
        self.callManager = callManager
        super.init()
        provider.setDelegate(self, queue: nil) // nil = main queue, matching this codebase's single-queue threading contract
    }

    // MARK: - CallKitAdapting (CallManager → CallKit)

    func reportIncomingCall(callId: String, callerName: String, audioOnly: Bool, completion: @escaping (Error?) -> Void) {
        let callUUID = UUID()
        currentCallUUID = callUUID
        currentCallId = callId

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = !audioOnly
        update.localizedCallerName = callerName

        provider.reportNewIncomingCall(with: callUUID, update: update, completion: completion)
    }

    func reportOutgoingCallStarted(callId: String) {
        currentCallId = callId
        // No system UI to report for an outgoing call until it connects —
        // `CXProvider` only needs `reportOutgoingCall(with:startedConnectingAt:)`
        // once the far end actually answers, which `reportConnected` covers.
    }

    func reportConnected(callId: String) {
        guard let callUUID = currentCallUUID else { return }
        provider.reportOutgoingCall(with: callUUID, connectedAt: Date())
    }

    func reportCallEnded(callId: String, reason: CallEndReason) {
        guard let callUUID = currentCallUUID else { return }
        let cxReason: CXCallEndedReason
        switch reason {
        case .remoteBye, .localHangup: cxReason = .remoteEnded
        case .timeout: cxReason = .unanswered
        case .busy: cxReason = .declinedElsewhere
        case .mediaFailure: cxReason = .failed
        }
        provider.reportCall(with: callUUID, endedAt: Date(), reason: cxReason)
        currentCallUUID = nil
        currentCallId = nil
    }
}

extension CallKitProvider: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        try? callManager?.hangUp()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        try? callManager?.answer()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        try? callManager?.hangUp()
        action.fulfill()
    }
}
```

- [ ] **Step 7: Commit**

```bash
git add Sources/IMCall/CallKitAdapting.swift Sources/IMCall/CallManager.swift Tests/IMCallTests/Support/FakeCallKitAdapter.swift Tests/IMCallTests/CallManagerTests.swift App/CallKitProvider.swift
git commit -m "feat: add CallKit integration via CallKitAdapting protocol"
```

## Task 14: `App/CallViewController.swift` — 拨号中/通话中界面(布局 A)

**Files:**
- Create: `App/CallViewController.swift`
- Modify: `project.yml`

**Design decision beyond what the spec fixed:** the design doc (§4) describes "拨号中"/"通话中" as two UI *states*, not necessarily two separate `UIViewController` classes. Implementing them as one `CallViewController` that re-lays-out itself as `CallManager.state` changes avoids a push/dismiss hand-off in the middle of a live call (the screen morphs in place, the way FaceTime/WeChat do it) — simpler than juggling two VC instances for what's really one continuous screen. CallKit owns the system incoming-call UI (design doc §4); once answered, this is the only screen the user sees from `.outgoing`/`.incoming` all the way through `.connected`.

- [ ] **Step 1: App target 直接依赖 WebRTC SPM 产物**

`RTCMTLVideoView`(渲染本端/远端画面用的视图)来自 `WebRTC.framework`,`App` target 要直接 `import WebRTC`,不能只靠 `IMCall` 间接拿到。在 `project.yml` 的 `App.dependencies` 列表里(`IMCall` 之后)追加:

```yaml
      - package: WebRTC
        product: WebRTC
```

- [ ] **Step 2: 实现**

创建 `App/CallViewController.swift`:

```swift
// App/CallViewController.swift
import UIKit
import Combine
import AVFoundation
import WebRTC
import IMCall

/// One continuous screen covering `.outgoing`/`.incoming`/`.connecting`/
/// `.connected` — see this task's header for why this isn't split into two
/// VC classes. Presented/dismissed by `SceneDelegate` (Task 15) whenever
/// `CallManager.state` leaves/returns to `.idle`.
final class CallViewController: UIViewController {
    private let callManager: CallManager
    private let webRTCClient: WebRTCClient
    private let peerDisplayName: String
    private var cancellables = Set<AnyCancellable>()
    private var callConnectedAt: Date?
    private var durationTimer: Timer?

    private let remoteVideoView = RTCMTLVideoView()
    private let localVideoView = RTCMTLVideoView()
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let muteButton = CallControlButton(systemImageName: "mic.slash.fill")
    private let speakerButton = CallControlButton(systemImageName: "speaker.wave.2.fill")
    private let switchCameraButton = CallControlButton(systemImageName: "camera.rotate.fill")
    private let hangUpButton = CallControlButton(systemImageName: "phone.down.fill", backgroundColor: .systemRed)
    private var isMuted = false
    private var isSpeakerOn = false

    init(callManager: CallManager, webRTCClient: WebRTCClient, peerDisplayName: String) {
        self.callManager = callManager
        self.webRTCClient = webRTCClient
        self.peerDisplayName = peerDisplayName
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutViews()
        bindCallManager()
        webRTCClient.attachRemoteRenderer(remoteVideoView)
        webRTCClient.attachLocalRenderer(localVideoView)
        addLocalPreviewDragGesture()
    }

    private func layoutViews() {
        nameLabel.text = peerDisplayName
        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statusLabel.font = .systemFont(ofSize: 14)
        avatarView.backgroundColor = Theme.backgroundTertiary
        avatarView.layer.cornerRadius = 48
        avatarView.clipsToBounds = true

        localVideoView.layer.cornerRadius = 8
        localVideoView.clipsToBounds = true
        localVideoView.layer.borderWidth = 1
        localVideoView.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor

        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        speakerButton.addTarget(self, action: #selector(speakerTapped), for: .touchUpInside)
        switchCameraButton.addTarget(self, action: #selector(switchCameraTapped), for: .touchUpInside)
        hangUpButton.addTarget(self, action: #selector(hangUpTapped), for: .touchUpInside)

        let controlBar = UIStackView(arrangedSubviews: [muteButton, switchCameraButton, hangUpButton, speakerButton])
        controlBar.axis = .horizontal
        controlBar.distribution = .equalSpacing
        controlBar.alignment = .center

        let centerStack = UIStackView(arrangedSubviews: [avatarView, nameLabel, statusLabel])
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 12

        [remoteVideoView, centerStack, localVideoView, controlBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        let controlBarBackground = UIView()
        controlBarBackground.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        controlBarBackground.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(controlBarBackground, belowSubview: controlBar)

        NSLayoutConstraint.activate([
            remoteVideoView.topAnchor.constraint(equalTo: view.topAnchor),
            remoteVideoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remoteVideoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remoteVideoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 96),
            avatarView.heightAnchor.constraint(equalToConstant: 96),

            localVideoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            localVideoView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            localVideoView.widthAnchor.constraint(equalToConstant: 90),
            localVideoView.heightAnchor.constraint(equalToConstant: 135),

            controlBarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlBarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlBarBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controlBarBackground.topAnchor.constraint(equalTo: controlBar.topAnchor, constant: -16),

            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            controlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            controlBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    private func bindCallManager() {
        callManager.$state
            .sink { [weak self] state in self?.applyState(state) }
            .store(in: &cancellables)
        callManager.$audioOnly
            .sink { [weak self] audioOnly in
                self?.remoteVideoView.isHidden = audioOnly
                self?.localVideoView.isHidden = audioOnly
                self?.avatarView.isHidden = !audioOnly
                self?.switchCameraButton.isHidden = audioOnly
            }
            .store(in: &cancellables)
    }

    private func applyState(_ state: CallState) {
        switch state {
        case .idle:
            durationTimer?.invalidate()
        case .outgoing:
            statusLabel.text = "正在呼叫…"
        case .incoming:
            statusLabel.text = "邀请你通话"
        case .connecting:
            statusLabel.text = "连接中…"
        case .connected:
            callConnectedAt = Date()
            startDurationTimer()
        }
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let connectedAt = self.callConnectedAt else { return }
            let elapsed = Int(Date().timeIntervalSince(connectedAt))
            self.statusLabel.text = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    private func addLocalPreviewDragGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleLocalPreviewPan))
        localVideoView.isUserInteractionEnabled = true
        localVideoView.addGestureRecognizer(pan)
    }

    @objc private func handleLocalPreviewPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        localVideoView.center = CGPoint(x: localVideoView.center.x + translation.x, y: localVideoView.center.y + translation.y)
        gesture.setTranslation(.zero, in: view)
    }

    @objc private func muteTapped() {
        isMuted.toggle()
        muteButton.setActive(isMuted)
        webRTCClient.setMuted(isMuted)
    }

    @objc private func speakerTapped() {
        isSpeakerOn.toggle()
        speakerButton.setActive(isSpeakerOn)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
    }

    @objc private func switchCameraTapped() {
        webRTCClient.switchCamera()
    }

    @objc private func hangUpTapped() {
        try? callManager.hangUp()
    }
}

/// Round, semi-transparent control bar button — `systemImageName`-driven so
/// the same type covers mute/speaker/switch-camera/hang-up without four
/// near-duplicate subclasses.
private final class CallControlButton: UIButton {
    init(systemImageName: String, backgroundColor: UIColor = UIColor.white.withAlphaComponent(0.25)) {
        super.init(frame: .zero)
        self.backgroundColor = backgroundColor
        tintColor = .white
        setImage(UIImage(systemName: systemImageName), for: .normal)
        layer.cornerRadius = 28
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 56).isActive = true
        heightAnchor.constraint(equalToConstant: 56).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setActive(_ active: Bool) {
        backgroundColor = active ? Theme.accent : UIColor.white.withAlphaComponent(0.25)
    }
}
```

- [ ] **Step 3: 重新生成 xcodeproj**

Run: `Scripts/generate-xcodeproj.sh`
Expected: 成功

- [ ] **Step 4: Commit**

```bash
git add App/CallViewController.swift project.yml ios-chat-pro.xcodeproj
git commit -m "feat: add CallViewController covering dialing/incoming/connecting/connected"
```

## Task 15: Wire it all up — `AppEnvironment`, `SceneDelegate`, call entry point

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/AppCore/AppEnvironment.swift`
- Modify: `App/SceneDelegate.swift`
- Modify: `App/ConversationViewController.swift`

`CallKitProvider` (App target) can't be constructed inside `AppEnvironment` (an `AppCore` package target — App depends on AppCore, never the reverse), so construction splits: `AppEnvironment.connectIfPossible()` builds `CallManager`+`WebRTCClient` (both from `IMCall`, which `AppCore` can depend on); `SceneDelegate` then builds the `CallKitProvider` and assigns it to `callManager.callKitAdapter`, the one cross-layer wiring step that has to happen in the App target.

- [ ] **Step 1: `AppCore` 依赖 `IMCall`**

在 `Package.swift` 里,把 `AppCore` 的 target 声明改成:

```swift
        .target(name: "AppCore", dependencies: ["IMClient", "IMStorage", "IMMessaging", "IMContacts", "IMMedia", "IMGroups", "IMCall"]),
```

- [ ] **Step 2: `AppEnvironment` 构造 `CallManager` + `WebRTCClient`**

在 `Sources/AppCore/AppEnvironment.swift` 顶部的 import 列表里追加:

```swift
import IMCall
```

在 `public private(set) var mediaUploadService: MediaUploadService?` 之后追加:

```swift
    public private(set) var callManager: CallManager?
    /// Exposed separately from `callManager` because `CallViewController`
    /// (Task 14) needs the concrete `WebRTCClient` for its video renderers
    /// (`attachLocalRenderer`/`attachRemoteRenderer`) and mute/camera-switch
    /// controls — `CallManager` only sees it through the narrower
    /// `MediaEngine` protocol.
    public private(set) var webRTCClient: WebRTCClient?
```

在 `connectIfPossible()` 里,`mediaUploadService = MediaUploadService(imClient: client)` 这一行之后追加:

```swift
        let webRTC = WebRTCClient(iceServers: config.iceServers)
        webRTCClient = webRTC
        callManager = CallManager(messagingService: service, storage: storage, mediaEngine: webRTC, myUserId: { client.userId })
```

在 `logOut()` 里,`mediaUploadService = nil` 这一行之后追加:

```swift
        callManager = nil
        webRTCClient = nil
```

- [ ] **Step 3: `SceneDelegate` 接 `CallKitProvider` + 监听呼叫状态展示/收起 `CallViewController`**

在 `App/SceneDelegate.swift` 顶部 import 列表里追加:

```swift
import IMCall
```

在 `private var cancellables = Set<AnyCancellable>()` 之后追加:

```swift
    private var callKitProvider: CallKitProvider?
    private var presentedCallViewController: CallViewController?
```

在 `scene(_:willConnectTo:options:)` 里,`window.makeKeyAndVisible()` 这一行**之前**插入:

```swift
        wireCallManagerIfReady()
```

在 `makeLoginViewController()` 里,`self.environment.connectIfPossible()` 这一行之后追加:

```swift
            self.wireCallManagerIfReady()
```

在文件末尾(最后一个 `}` 之前)追加两个新方法:

```swift
    /// No-ops if `environment.callManager` is still `nil` (no stored
    /// credentials yet, login screen showing) — called again from
    /// `makeLoginViewController`'s `onLoginSucceeded` once it exists.
    /// Idempotent: a second call after `callKitProvider` already exists
    /// just re-runs harmlessly (re-creating a fresh `CallKitProvider` would
    /// be wrong — `CXProvider` is meant to be a singleton-ish per-app
    /// object — so this guards against that).
    private func wireCallManagerIfReady() {
        guard let callManager = environment.callManager, callKitProvider == nil else { return }
        let provider = CallKitProvider(callManager: callManager)
        callKitProvider = provider
        callManager.callKitAdapter = provider

        callManager.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.handleCallStateChange(state) }
            .store(in: &cancellables)
    }

    /// Presents `CallViewController` full-screen the moment a call starts
    /// (either `.outgoing` from tapping the call button below, or
    /// `.incoming` from `CallKitProvider.reportIncomingCall`'s completion
    /// firing `CallManager.onIncomingCall`), and dismisses it once the call
    /// returns to `.idle`. One screen for the whole call lifecycle — see
    /// `CallViewController`'s own header comment for why.
    private func handleCallStateChange(_ state: IMCall.CallState) {
        guard let callManager = environment.callManager else { return }
        if state == .idle {
            presentedCallViewController?.dismiss(animated: true)
            presentedCallViewController = nil
            return
        }
        guard presentedCallViewController == nil, let webRTCClient = environment.webRTCClient, let peerUid = callManager.peerUid else { return }
        let displayName = (try? environment.storage.users.user(uid: peerUid))?.displayName ?? peerUid
        let callViewController = CallViewController(callManager: callManager, webRTCClient: webRTCClient, peerDisplayName: displayName)
        presentedCallViewController = callViewController
        window?.rootViewController?.present(callViewController, animated: true)
    }
```

> 这里假定 `IMStorage.UserStore` 有一个 `user(uid:) throws -> StoredUser?` 方法、`StoredUser` 有 `displayName` 字段——这两个在 Phase 1 的 `IMStorage` 设计里已经存在(联系人列表功能依赖它),实现这一步时如果实际方法名有出入(比如是 `displayName` 还是 `name` 字段),照 `Sources/IMStorage/UserStore.swift` 的真实签名改,不要凭这里的推测硬套。

- [ ] **Step 4: 会话页加拨打入口**

在 `App/ConversationViewController.swift` 里,`var onGroupInfoTapped: (() -> Void)?` 之后追加:

```swift
    var onCallTapped: ((_ audioOnly: Bool) -> Void)?
```

在 `viewDidLoad()` 里,`if row.conversationType == .group { ... }` 这个块之后追加:

```swift
        if row.conversationType == .single {
            let videoCallItem = UIBarButtonItem(image: UIImage(systemName: "video.fill"), style: .plain, target: self, action: #selector(videoCallTapped))
            let audioCallItem = UIBarButtonItem(image: UIImage(systemName: "phone.fill"), style: .plain, target: self, action: #selector(audioCallTapped))
            navigationItem.rightBarButtonItems = [videoCallItem, audioCallItem]
        }
```

在 `@objc private func groupTitleTapped()` 之后追加:

```swift
    @objc private func videoCallTapped() { onCallTapped?(false) }
    @objc private func audioCallTapped() { onCallTapped?(true) }
```

在 `App/SceneDelegate.swift` 的 `makeConversationListNavigationController()` 里,`self.wireGroupInfoNavigation(on: conversationViewController, groupId: row.target)` 这一行之后追加:

```swift
            conversationViewController.onCallTapped = { [weak self] audioOnly in
                try? self?.environment.callManager?.startCall(to: row.target, audioOnly: audioOnly)
            }
```

(`makeContactListNavigationController` 里从联系人直接进入的 `ConversationViewController` 同理追加一份一样的闭包赋值——两处入口共享同一个 `environment.callManager`,不需要额外状态。)

- [ ] **Step 5: 重新生成 xcodeproj,跑一遍全量测试**

Run: `Scripts/generate-xcodeproj.sh && swift test`
Expected: 全部 PASS(这一步只接线,没有新增可单测的逻辑)

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AppCore/AppEnvironment.swift App/SceneDelegate.swift App/ConversationViewController.swift ios-chat-pro.xcodeproj
git commit -m "feat: wire CallManager/CallKitProvider/CallViewController end to end"
```

## Task 16: 两台真机手工验收

**Files:** 不改代码,只验证。

按设计文档 §6 的验收标准,分两步走,**不要跳过第二步**——第一步只能证明 iOS 自己的状态机/UI 没问题,完全不能证明跟 Android 解析同一套 wire bytes 不会出错(Task 3/6 的字段映射是读 Android 源码推出来的,从未真正抓包验证过,见设计文档风险 #4)。

- [ ] **Step 1: 双 iOS 真机互通**

用 Phase 1 的两个测试账号(`13800000000`/`13800000001`,验证码 `556677`)分别登录两台真机,依次过一遍:
  - A 拨语音给 B,B 接听,双方能互相听到声音,挂断后双方会话里都出现"语音通话 00:0x"气泡且时长一致(±1秒,允许两端时钟误差)
  - A 拨视频给 B,B 接听,双方能看到对方画面,本端小窗能拖动,挂断/切换前后摄像头/静音/扬声器按钮都生效
  - A 拨给 B,B 拒接,A 端气泡显示"对方已取消"或等价文案,B 端无遗留来电状态
  - A 拨给 B,B 60 秒不接听,双方自动挂断,气泡显示未接听
  - A、B 同时互拨对方(约定一个时刻一起点拨打),验证 glare 规则生效:只有一路接通,不是两路都响铃也不是两路都失败
  - 通话中把其中一台切到后台几秒再切回前台,确认通话没有被系统杀掉控制(在"仅前台接通"范围内的合理时长)

- [ ] **Step 2: 与 Android (`android-chat-pro`) 互通**

用同一个测试账号体系,iOS 主叫 Android、Android 主叫 iOS 各跑一遍语音+视频。重点核对 Task 3/6 推断的字段映射(设计文档风险 #4):
  - 用 Charles/mitmproxy 或者在 `WebRTCClient`/`MessagingService` 里临时加日志,对比两端实际收发的 `Im_MessageContent.data` 原始字节
  - 确认 400(CallStart)的 `searchableContent`/`data` JSON 字段名(`t`/`a`/`c`/`e`/`s`)跟 Android `CallStartMessageContent.encode()` 写出来的字节完全一致
  - 确认 403(Signal)的 SDP/ICE candidate JSON 字段名(`type`/`sdp`/`label`/`id`/`candidate`)跟 Android `SignalMessage` 实际发出的字节完全一致
  - 如果发现任何字段名/类型不匹配,回到 Task 3/6 改 `MessageContentCodec`/`CallSignalCodec` 的 JSON 结构,不是改 Android 端

- [ ] **Step 3: 记录结果**

如果 Step 2 发现字段映射跟 Android 不一致,在 `docs/superpowers/specs/2026-06-23-phase3-av-call-design.md` 的"已知风险与待实现阶段核实事项"第 4 条后面补一行实测结论(对上还是改了什么),把这个风险从"待核实"标记为"已核实"或写明实际差异——不要让这份验收结果只停留在某次手工测试的记忆里。
