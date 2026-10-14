# 语音转文字：ios-chat-pro Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iOS 客户端实现语音消息转文字：补齐「未播放」红点，红点右侧「转文字」按钮，长按菜单「转文字 / 隐藏文字」，气泡下方文字块，设置页「自动转文字」开关。

**Architecture:** 协议层：`SubSignal.asr = 44`，proto 追加 `SpeechToTextRequest/Result`，`IMMessaging` 新增 `SpeechToTextAckHandler` 与 `MessagingService.speechToText(messageUid:completion:)`（按 wireId 匹配回包，写法同 `recall`）。存储层：`MessageStatus.played = 7`、`MessageStore.markPlayed(id:)`、v10 迁移把已有他人语音置为已播放。`IMKit` 新增 `TranscriptEngine`（状态机 + 超时 + 自动队列，Foundation/Combine，可单测）、`VoiceTranscriptRules`、`UserDefaultsTranscriptPersistence`。App 层由 `SceneDelegate` 持有引擎（`AppCore` 不依赖 `IMKit`），`AppEnvironment` 只转发「收到新语音」事件，与 `onIncomingMessageAlert` 同一模式。

**Tech Stack:** Swift 5、SPM（`swift test`）、GRDB、SwiftProtobuf（`Scripts/generate-proto.sh`）、UIKit + Combine，部署目标 iOS 15

**Spec:** `chat-server-pro/docs/superpowers/specs/2026-10-13-voice-to-text-design.md`（§1 交互约定、§3、§6.5）

**前置依赖:** 服务端计划 Task 1（proto 定义）。Task 8 手动验证依赖服务端已部署。

## Global Constraints

- 所有调用在主队列（项目线程约定，无内部锁）。
- 依赖方向单向：`IMStorage` → `IMMessaging` → `IMKit` → `App`；`AppCore` 不能 import `IMKit`。
- proto 用 `bash Scripts/generate-proto.sh` 生成，**不要**用系统 protoc 2.5。
- `SubSignal` 只允许末尾追加，`asr` rawValue 必须为 **44**。
- 所有失败一律显示「转文字失败，点击重试」；空文本显示「未识别到文字」。
- 点击「转文字」（按钮或长按菜单）把消息置为已播放；自动转文字不置已播放。
- 自动转文字只处理「实时」他人语音：`now - (serverTimestamp - serverDelta) <= 120 秒`，且不在首次登录全量拉取（`suppressUnreadIncrement`）期间；并发 2；按 messageUid 去重。
- 客户端单次请求超时 15 秒，超时后迟到的结果丢弃。
- 开关与结果存 UserDefaults，不做多端同步。
- 编译验证用 `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 15'`（本机最高 iPhone 15，写错机型会静默回退真机 SDK）。

## Review Focus

1. **升级后历史语音不应全部冒红点**：新增 `played` 之前收到的语音 status 都是 `unread` —— Task 2 `test_v10_marksExistingIncomingVoiceAsPlayed`。
2. **请求无回包时不能永远停在「转文字中…」** —— Task 4 `test_timeoutTurnsLoadingIntoError` / `test_lateResultAfterTimeoutIsIgnored`；断线时 `MessagingService` 也会立即失败挂起请求 —— Task 3 `test_speechToText_disconnectFailsPending`。
3. **识别进行中点「隐藏文字」后结果回来保持隐藏** —— Task 4 `test_hideWhileLoadingStaysHidden`。
4. **重复点击不重复请求** —— Task 4 `test_requestWhileLoadingIsNoop`。
5. **首次登录 / 长时间离线后的积压语音不自动识别** —— Task 3 `test_receive_firesIncomingVoiceOnlyWhenNotSuppressed` + Task 4 `test_isRealtimeRejectsOldMessages`。

---

### Task 1: proto 与 SubSignal

**Files:**
- Modify: `Proto/WFCMessage.proto`（末尾追加）
- Regenerate: `Sources/IMProto/Generated/WFCMessage.pb.swift`
- Modify: `Sources/IMTransport/SubSignal.swift`（`un = 43` 之后）
- Test: `Tests/IMTransportTests/SubSignalOrdinalTest.swift`

**Interfaces:**
- Produces: `Im_SpeechToTextRequest`（`messageUid: Int64`）、`Im_SpeechToTextResult`（`text: String`）、`SubSignal.asr`

- [ ] **Step 1: 写失败测试**

`Tests/IMTransportTests/SubSignalOrdinalTest.swift` 类末尾追加：

```swift
    func testSpeechToTextSignalIsAppendedAfterUserSetting() {
        XCTAssertEqual(SubSignal.asr.rawValue, 44)
        XCTAssertEqual(SubSignal(rawValue: 44), .asr)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter IMTransportTests/SubSignalOrdinalTest`
Expected: 编译失败 `type 'SubSignal' has no member 'asr'`。

- [ ] **Step 3: SubSignal**

`Sources/IMTransport/SubSignal.swift` 中 `case un = 43` 之后加：

```swift
    // 语音转文字：带 messageUid 请求，PUB_ACK 返回 SpeechToTextResult。只允许在末尾追加
    case asr = 44
```

- [ ] **Step 4: proto 追加并生成**

`Proto/WFCMessage.proto` 文件末尾追加（与 `chat-proto/WFCMessage.proto` 中新增内容一致）：

```proto

message SpeechToTextRequest
{
	required int64 message_uid = 1;
}

message SpeechToTextResult
{
	required string text = 1;
}
```

Run: `bash Scripts/generate-proto.sh && grep -c "struct Im_SpeechToTextRequest\|struct Im_SpeechToTextResult" Sources/IMProto/Generated/WFCMessage.pb.swift`
Expected: `2`

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test --filter IMTransportTests && swift test --filter IMProtoTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Proto/WFCMessage.proto Sources/IMProto/Generated/WFCMessage.pb.swift Sources/IMTransport/SubSignal.swift Tests/IMTransportTests/SubSignalOrdinalTest.swift
git commit -m "feat(proto): 新增 ASR 语音转文字信令（SubSignal 44）"
```

---

### Task 2: 存储层「已播放」状态

**Files:**
- Modify: `Sources/IMStorage/MessageEnums.swift`（`MessageStatus`）
- Modify: `Sources/IMStorage/IMDatabase.swift`（`migrator` 可见性 + v10 迁移）
- Modify: `Sources/IMStorage/MessageStore.swift`（`updateStatus` 之后新增 `markPlayed`）
- Test: `Tests/IMStorageTests/MessagePlayedStatusTests.swift`

**Interfaces:**
- Produces: `MessageStatus.played`（rawValue 7）；`MessageStore.markPlayed(id: Int64) throws`、`markPlayed(id: Int64, db: Database) throws`（只改 `direction == .receive` 的行）

- [ ] **Step 1: 写失败测试**

创建 `Tests/IMStorageTests/MessagePlayedStatusTests.swift`：

```swift
import XCTest
import GRDB
@testable import IMStorage

final class MessagePlayedStatusTests: XCTestCase {

    private func voice(_ localId: Int64, direction: MessageDirection, status: MessageStatus) -> StoredMessage {
        StoredMessage(
            localMessageId: localId, messageUid: 1000 + localId,
            conversationType: .single, target: "them", from: direction == .receive ? "them" : "me",
            content: .voice(remoteURL: "http://x/\(localId).amr", localPath: nil, duration: 3),
            timestamp: 1_000, status: status, direction: direction
        )
    }

    private func status(_ storage: IMStorage, id: Int64) throws -> Int? {
        try storage.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT status FROM message WHERE id = ?", arguments: [id])
        }
    }

    func test_playedRawValueMatchesAndroid() {
        XCTAssertEqual(MessageStatus.played.rawValue, 7)
    }

    func test_markPlayed_updatesIncomingOnly() throws {
        let storage = try IMStorage.openInMemory()
        let incoming = try storage.messages.insert(voice(1, direction: .receive, status: .unread))
        let outgoing = try storage.messages.insert(voice(2, direction: .send, status: .sent))

        try storage.messages.markPlayed(id: incoming.id!)
        try storage.messages.markPlayed(id: outgoing.id!)

        XCTAssertEqual(try status(storage, id: incoming.id!), 7)
        XCTAssertEqual(try status(storage, id: outgoing.id!), MessageStatus.sent.rawValue)
    }

    func test_v10_marksExistingIncomingVoiceAsPlayed() throws {
        let queue = try DatabaseQueue()
        try IMDatabase.migrator.migrate(queue, upTo: "v9_addUserSettingTable")
        try queue.write { db in
            for (localId, contentType, direction) in [(1, 2, 1), (2, 1, 1), (3, 2, 0)] {
                try db.execute(sql: """
                    INSERT INTO message (localMessageId, messageUid, conversationType, target, line, "from", contentType, timestamp, status, direction)
                    VALUES (?, ?, 0, 'them', 0, 'them', ?, 1000, ?, ?)
                    """, arguments: [localId, 100 + localId, contentType, direction == 1 ? 5 : 1, direction])
            }
        }

        try IMDatabase.migrator.migrate(queue)

        let statuses = try queue.read { db in
            try Int.fetchAll(db, sql: "SELECT status FROM message ORDER BY localMessageId")
        }
        XCTAssertEqual(statuses, [7, 5, 1])
    }
}
```

（`IMStorage.openInMemory()` 为现有测试入口；若名称不同，以 `Tests/IMStorageTests/MessageStoreTests.swift` 中的构造方式为准。`message` 表在 v1 之后的迁移若新增了 NOT NULL 且无默认值的列，按 `IMDatabase.swift` 实际 schema 在 INSERT 中补齐。）

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter IMStorageTests/MessagePlayedStatusTests`
Expected: 编译失败（`played` 不存在、`migrator` 不可访问、`markPlayed` 不存在）。

- [ ] **Step 3: MessageStatus**

`MessageEnums.swift` 的 `MessageStatus` 中 `case read = 6` 之后加：

```swift
    /// 他人语音已播放（或用户点了「转文字」）。值与 Android `MessageStatus.Played` 一致
    case played = 7
```

并把该枚举上方注释中 `no voice playback` 与 `Played=7` 的说明更新为「`played` 已在语音转文字需求中加入」。

- [ ] **Step 4: 迁移**

`IMDatabase.swift`：

1. `private static var migrator: DatabaseMigrator {` 改为 `static var migrator: DatabaseMigrator {`（internal，供 `@testable` 测试分段迁移）。
2. `v9_addUserSettingTable` 迁移块之后、`return migrator` 之前加：

```swift
        migrator.registerMigration("v10_markExistingVoiceAsPlayed") { db in
            // 「已播放」上线前收到的他人语音都是 unread，升级后会全部显示红点和「转文字」按钮。
            // 与 v8 同理，一次性置为已播放，只有迁移之后新收到的语音才显示红点。
            try db.execute(sql: "UPDATE message SET status = 7 WHERE direction = 1 AND contentType = 2")
        }
```

- [ ] **Step 5: markPlayed**

`MessageStore.swift` 中 `updateStatus(localMessageId:status:db:)` 方法之后加：

```swift
    /// 他人语音置为已播放（播放或点「转文字」时调用）。自己发的消息不受影响。
    public func markPlayed(id: Int64) throws {
        try dbQueue.write { db in try self.markPlayed(id: id, db: db) }
    }

    public func markPlayed(id: Int64, db: Database) throws {
        try db.execute(
            sql: "UPDATE message SET status = ? WHERE id = ? AND direction = ?",
            arguments: [MessageStatus.played.rawValue, id, MessageDirection.receive.rawValue]
        )
    }
```

- [ ] **Step 6: 运行测试确认通过**

Run: `swift test --filter IMStorageTests`
Expected: PASS（含新增 3 个）

- [ ] **Step 7: Commit**

```bash
git add Sources/IMStorage/MessageEnums.swift Sources/IMStorage/IMDatabase.swift Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/MessagePlayedStatusTests.swift
git commit -m "feat(storage): 语音已播放状态与 v10 迁移"
```

---

### Task 3: IMMessaging 转文字请求与新语音事件

**Files:**
- Create: `Sources/IMMessaging/SpeechToTextAckHandler.swift`
- Modify: `Sources/IMMessaging/MessagingService.swift`（属性、init 注册、新增 `speechToText`、`onDisconnected`、`onIncomingVoiceMessage` 转发）
- Modify: `Sources/IMMessaging/ReceiveMessageHandler.swift`（收集并派发新语音事件）
- Test: `Tests/IMMessagingTests/SpeechToTextAckHandlerTests.swift`
- Test: `Tests/IMMessagingTests/MessagingServiceTests.swift`（追加用例）
- Test: `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift`（追加用例）

**Interfaces:**
- Produces:
  - `MessagingService.speechToText(messageUid: Int64, completion: @escaping (String?) -> Void)`：成功传文本（可为空串），失败传 `nil`；断线时立即以 `nil` 回调所有挂起请求
  - `MessagingService.onIncomingVoiceMessage: ((_ messageUid: Int64, _ serverTimestamp: Int64) -> Void)?`：写库事务结束后、按条派发；首次登录全量拉取（`suppressUnreadIncrement`）期间不派发

- [ ] **Step 1: 写 ack handler 失败测试**

创建 `Tests/IMMessagingTests/SpeechToTextAckHandlerTests.swift`：

```swift
import XCTest
import IMClient
import IMProto
import IMTransport
@testable import IMMessaging

final class SpeechToTextAckHandlerTests: XCTestCase {
    private var handler: SpeechToTextAckHandler!
    private var captured: (UInt16, String?)?

    override func setUp() {
        super.setUp()
        handler = SpeechToTextAckHandler()
        captured = nil
        handler.onResult = { [weak self] id, text in self?.captured = (id, text) }
    }

    private func frame(_ body: Data) -> Frame {
        Frame(header: Header(signal: .pubAck, subSignal: .asr, bodyLength: UInt32(body.count), messageId: 9), body: body)
    }

    func test_canHandle_onlyPubAckAsr() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .asr))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .asr))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .mr))
    }

    func test_success_parsesText() throws {
        var result = Im_SpeechToTextResult()
        result.text = "你好"
        handler.handle(frame: frame(Data([0x00]) + (try result.serializedData())))

        XCTAssertEqual(captured?.0, 9)
        XCTAssertEqual(captured?.1, "你好")
    }

    func test_success_emptyText() throws {
        var result = Im_SpeechToTextResult()
        result.text = ""
        handler.handle(frame: frame(Data([0x00]) + (try result.serializedData())))

        XCTAssertEqual(captured?.1, "")
    }

    func test_errorCode_yieldsNil() {
        handler.handle(frame: frame(Data([0xF8])))

        XCTAssertEqual(captured?.0, 9)
        XCTAssertNil(captured?.1 ?? nil)
    }

    func test_emptyBody_doesNotCrash() {
        handler.handle(frame: frame(Data()))
        XCTAssertNil(captured)
    }
}
```

（`Header` 构造参数类型以 `RecallAckHandlerTests` 中的写法为准；若 `bodyLength` 不是 `UInt32`，按实际类型转换。）

- [ ] **Step 2: 写 MessagingService 失败测试**

在 `Tests/IMMessagingTests/MessagingServiceTests.swift` 类中追加：

```swift
    func test_speechToText_sendsPublishAsrWithUid() throws {
        service.speechToText(messageUid: 777) { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .asr)
        XCTAssertEqual(try Im_SpeechToTextRequest(serializedBytes: frame.body).messageUid, 777)
    }

    func test_speechToText_ackDeliversText() throws {
        var captured: String??
        service.speechToText(messageUid: 777) { captured = .some($0) }
        let sent = try decodeOnlySentFrame()
        var result = Im_SpeechToTextResult()
        result.text = "hi"
        let ack = FrameEncoder.encode(signal: .pubAck, subSignal: .asr, messageId: sent.header.messageId, body: Data([0x00]) + (try result.serializedData()))

        fakeTransport.simulateReceivedData(ack)

        XCTAssertEqual(captured, .some("hi"))
    }

    func test_speechToText_errorAckDeliversNil() throws {
        var captured: String??
        service.speechToText(messageUid: 777) { captured = .some($0) }
        let sent = try decodeOnlySentFrame()

        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .asr, messageId: sent.header.messageId, body: Data([0xF8])))

        XCTAssertEqual(captured, .some(nil))
    }

    func test_speechToText_disconnectFailsPending() throws {
        var captured: String??
        service.speechToText(messageUid: 777) { captured = .some($0) }

        imClient.onDisconnected?()

        XCTAssertEqual(captured, .some(nil))
    }
```

（`imClient.onDisconnected` 由 `MessagingService.init` 赋值；若测试中无法直接调用，改用该文件中 `failAllPendingRemoteLoads` 相关用例触发断线的同一方式。）

- [ ] **Step 3: 写 ReceiveMessageHandler 失败测试**

在 `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift` 类中追加（复用文件内已有的 `makeWireMessage` / `makePullResultFrame`）：

```swift
    private func makeVoiceWireMessage(uid: Int64, from: String) -> Im_Message {
        var message = makeWireMessage(uid: uid, from: from, target: from == "me" ? "them" : "me")
        message.content = MessageContentCodec.encode(.voice(remoteURL: "http://x/\(uid).amr", localPath: nil, duration: 3))
        return message
    }

    func test_receive_firesIncomingVoiceOnlyWhenNotSuppressed() throws {
        var fired: [Int64] = []
        handler.onIncomingVoiceMessage = { uid, _ in fired.append(uid) }

        handler.suppressUnreadIncrement = true
        handler.handle(frame: try makePullResultFrame(messages: [makeVoiceWireMessage(uid: 1, from: "them")], head: 1))
        XCTAssertEqual(fired, [])

        handler.handle(frame: try makePullResultFrame(messages: [makeVoiceWireMessage(uid: 2, from: "them")], head: 2))
        XCTAssertEqual(fired, [2])
    }

    func test_receive_doesNotFireForTextOrOwnVoice() throws {
        var fired: [Int64] = []
        handler.onIncomingVoiceMessage = { uid, _ in fired.append(uid) }

        handler.handle(frame: try makePullResultFrame(messages: [
            makeWireMessage(uid: 3, from: "them", target: "me"),
            makeVoiceWireMessage(uid: 4, from: "me"),
        ], head: 4))

        XCTAssertEqual(fired, [])
    }
```

（`MessageContentCodec.encode` 若要求 `mentionedType:mentionedTargets:` 参数，按 `makeWireMessage` 中 `.text` 的同一调用形式书写。）

- [ ] **Step 4: 运行确认失败**

Run: `swift test --filter IMMessagingTests`
Expected: 编译失败（`SpeechToTextAckHandler`、`speechToText`、`onIncomingVoiceMessage` 不存在）。

- [ ] **Step 5: SpeechToTextAckHandler**

```swift
import Foundation
import IMClient
import IMProto
import IMTransport

/// Handles `PUB_ACK`/`ASR`(subSignal 44)：1 字节错误码 + 成功时 `SpeechToTextResult`。
/// 与 `RecallAckHandler` 同构，按 wireMessageId 回给 `MessagingService`。
public final class SpeechToTextAckHandler: MessageHandler {
    /// 参数：wireMessageId、识别文本（失败为 nil）
    var onResult: ((UInt16, String?) -> Void)?

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .asr
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        guard errorCode == 0 else {
            onResult?(frame.header.messageId, nil)
            return
        }
        let text = try? Im_SpeechToTextResult(serializedBytes: frame.body.dropFirst()).text
        onResult?(frame.header.messageId, text)
    }
}
```

（`Im_SpeechToTextResult(serializedBytes:)` 若在本项目 SwiftProtobuf 版本中不可用，改用 `serializedData:`，与现有代码保持一致。）

- [ ] **Step 6: MessagingService**

1. 属性区 `private var pendingRecalls: [UInt16: (Bool) -> Void] = [:]` 之后加：

```swift
    private let speechToTextAckHandler: SpeechToTextAckHandler
    private var pendingSpeechToText: [UInt16: (String?) -> Void] = [:]
```

2. `init` 中 `let recallAckHandlerInstance = RecallAckHandler()` 之前（所有 `[weak self]` 闭包之前）加：

```swift
        let speechHandler = SpeechToTextAckHandler()
        speechToTextAckHandler = speechHandler
```

在 `imClient.register(recallAckHandlerInstance)` 之后加：

```swift
        speechHandler.onResult = { [weak self] wireId, text in
            self?.pendingSpeechToText.removeValue(forKey: wireId)?(text)
        }
        imClient.register(speechHandler)
```

把

```swift
        imClient.onDisconnected = { [weak self] in
            self?.failAllPendingRemoteLoads()
        }
```

改为

```swift
        imClient.onDisconnected = { [weak self] in
            self?.failAllPendingRemoteLoads()
            self?.failAllPendingSpeechToText()
        }
```

3. `recall(...)` 方法之后加：

```swift
    /// 语音转文字。completion 成功为文本（可能为空串），失败为 nil。
    public func speechToText(messageUid: Int64, completion: @escaping (String?) -> Void) {
        var request = Im_SpeechToTextRequest()
        request.messageUid = messageUid
        guard let body = try? request.serializedData() else { completion(nil); return }
        let wireId = imClient.sendFrame(signal: .publish, subSignal: .asr, body: body)
        pendingSpeechToText[wireId] = completion
    }

    private func failAllPendingSpeechToText() {
        let pending = pendingSpeechToText
        pendingSpeechToText.removeAll()
        for completion in pending.values { completion(nil) }
    }

    /// 转发 `ReceiveMessageHandler.onIncomingVoiceMessage`，供自动转文字使用。
    public var onIncomingVoiceMessage: ((_ messageUid: Int64, _ serverTimestamp: Int64) -> Void)? {
        get { receiveMessageHandler.onIncomingVoiceMessage }
        set { receiveMessageHandler.onIncomingVoiceMessage = newValue }
    }
```

- [ ] **Step 7: ReceiveMessageHandler**

1. 在 `public var onIncomingMessageAlert` 声明之后加：

```swift
    /// 新收到的他人语音（不含首次登录全量拉取），写库事务结束后按条派发。
    public var onIncomingVoiceMessage: ((_ messageUid: Int64, _ serverTimestamp: Int64) -> Void)?
```

2. 处理 MP 回包的方法中，`var alertCandidates: ...` 之后加 `var incomingVoices: [(uid: Int64, timestamp: Int64)] = []`；把 `persist(...)` 调用和定义都加上 `incomingVoices: &incomingVoices` 这个 `inout` 参数。

3. `persist` 中 `if direction == .receive, !suppressUnread, !isRecalledContent(content) {` 这一段之后加：

```swift
            if direction == .receive, !suppressUnread, case .voice = content {
                incomingVoices.append((uid: wireMessage.messageID, timestamp: wireMessage.serverTimestamp))
            }
```

4. 事务之后、`for candidate in alertCandidates {` 循环之后加：

```swift
        for voice in incomingVoices {
            onIncomingVoiceMessage?(voice.uid, voice.timestamp)
        }
```

- [ ] **Step 8: 运行测试确认通过**

Run: `swift test --filter IMMessagingTests`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Sources/IMMessaging Tests/IMMessagingTests
git commit -m "feat(messaging): 语音转文字请求与新语音事件"
```

---

### Task 4: IMKit TranscriptEngine、规则与持久化

**Files:**
- Create: `Sources/IMKit/SpeechToTextFetching.swift`
- Create: `Sources/IMKit/TranscriptEngine.swift`
- Create: `Sources/IMKit/VoiceTranscriptRules.swift`
- Create: `Sources/IMKit/UserDefaultsTranscriptPersistence.swift`
- Test: `Tests/IMKitTests/TranscriptEngineTests.swift`
- Test: `Tests/IMKitTests/VoiceTranscriptRulesTests.swift`

**Interfaces:**
- Consumes: Task 3 `MessagingService.speechToText`
- Produces:
  - `protocol SpeechToTextFetching: AnyObject { func speechToText(messageUid: Int64, completion: @escaping (String?) -> Void) }`，`extension MessagingService: SpeechToTextFetching {}`
  - `protocol TranscriptPersistence: AnyObject { func loadDone() -> [Int64: TranscriptEngine.Saved]; func saveDone(_ done: [Int64: TranscriptEngine.Saved]); func loadAuto() -> Bool; func saveAuto(_ on: Bool) }`
  - `final class TranscriptEngine`：`init(fetcher: @escaping () -> SpeechToTextFetching?, persistence: TranscriptPersistence, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void)`；`entry(for:) -> Entry?`、`request(_:)`、`hide(_:)`、`var isAutoTranscribe: Bool { get set }`、`enqueueAuto(_:)`、`let changes: PassthroughSubject<Int64, Never>`；`struct Entry { status; text; hidden }`、`enum Status { loading, done, error }`、`struct Saved: Codable { text; hidden }`；`static let timeout: TimeInterval = 15`、`static let autoConcurrency = 2`
  - `enum VoiceTranscriptRules`：`enum Block { none, loading, text, empty, error }`、`showPill(isIncoming:isPlayed:messageUid:entry:auto:) -> Bool`、`block(_:) -> Block`、`showTranscribeMenu(messageUid:entry:)`、`showHideMenu(messageUid:entry:)`、`isRealtime(serverTimestamp:serverDelta:now:) -> Bool`、`static let realtimeWindowMillis: Int64 = 120_000`
  - `final class UserDefaultsTranscriptPersistence: TranscriptPersistence`：`init(defaults: UserDefaults = .standard)`

- [ ] **Step 1: 写规则失败测试**

创建 `Tests/IMKitTests/VoiceTranscriptRulesTests.swift`：

```swift
import XCTest
@testable import IMKit

final class VoiceTranscriptRulesTests: XCTestCase {
    private let loading = TranscriptEngine.Entry(status: .loading, text: "", hidden: false)
    private let done = TranscriptEngine.Entry(status: .done, text: "hi", hidden: false)
    private let empty = TranscriptEngine.Entry(status: .done, text: "", hidden: false)
    private let hidden = TranscriptEngine.Entry(status: .done, text: "hi", hidden: true)
    private let error = TranscriptEngine.Entry(status: .error, text: "", hidden: false)

    func test_pill() {
        XCTAssertTrue(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: false, messageUid: 1, entry: nil, auto: false))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: false, messageUid: 1, entry: nil, auto: true))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: true, messageUid: 1, entry: nil, auto: false))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: false, isPlayed: false, messageUid: 1, entry: nil, auto: false))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: false, messageUid: 1, entry: loading, auto: false))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: false, messageUid: 0, entry: nil, auto: false))
    }

    func test_block() {
        XCTAssertEqual(VoiceTranscriptRules.block(nil), .none)
        XCTAssertEqual(VoiceTranscriptRules.block(loading), .loading)
        XCTAssertEqual(VoiceTranscriptRules.block(done), .text)
        XCTAssertEqual(VoiceTranscriptRules.block(empty), .empty)
        XCTAssertEqual(VoiceTranscriptRules.block(error), .error)
        XCTAssertEqual(VoiceTranscriptRules.block(hidden), .none)
    }

    func test_menusAreMutuallyExclusive() {
        XCTAssertTrue(VoiceTranscriptRules.showTranscribeMenu(messageUid: 1, entry: nil))
        XCTAssertTrue(VoiceTranscriptRules.showTranscribeMenu(messageUid: 1, entry: error))
        XCTAssertTrue(VoiceTranscriptRules.showTranscribeMenu(messageUid: 1, entry: hidden))
        XCTAssertFalse(VoiceTranscriptRules.showTranscribeMenu(messageUid: 1, entry: done))
        XCTAssertTrue(VoiceTranscriptRules.showHideMenu(messageUid: 1, entry: done))
        XCTAssertTrue(VoiceTranscriptRules.showHideMenu(messageUid: 1, entry: loading))
        XCTAssertFalse(VoiceTranscriptRules.showHideMenu(messageUid: 1, entry: hidden))
        XCTAssertFalse(VoiceTranscriptRules.showTranscribeMenu(messageUid: 0, entry: nil))
    }

    func test_isRealtimeRejectsOldMessages() {
        let now: Int64 = 1_000_000_000
        let delta: Int64 = 500
        XCTAssertTrue(VoiceTranscriptRules.isRealtime(serverTimestamp: now + delta - 1_000, serverDelta: delta, now: now))
        XCTAssertTrue(VoiceTranscriptRules.isRealtime(serverTimestamp: now + delta - VoiceTranscriptRules.realtimeWindowMillis, serverDelta: delta, now: now))
        XCTAssertFalse(VoiceTranscriptRules.isRealtime(serverTimestamp: now + delta - VoiceTranscriptRules.realtimeWindowMillis - 1, serverDelta: delta, now: now))
    }
}
```

- [ ] **Step 2: 写引擎失败测试**

创建 `Tests/IMKitTests/TranscriptEngineTests.swift`：

```swift
import XCTest
import Combine
@testable import IMKit

private final class FakeFetcher: SpeechToTextFetching {
    var calls: [(uid: Int64, completion: (String?) -> Void)] = []
    func speechToText(messageUid: Int64, completion: @escaping (String?) -> Void) {
        calls.append((messageUid, completion))
    }
}

private final class MemoryPersistence: TranscriptPersistence {
    var done: [Int64: TranscriptEngine.Saved] = [:]
    var auto = false
    func loadDone() -> [Int64: TranscriptEngine.Saved] { done }
    func saveDone(_ done: [Int64: TranscriptEngine.Saved]) { self.done = done }
    func loadAuto() -> Bool { auto }
    func saveAuto(_ on: Bool) { auto = on }
}

final class TranscriptEngineTests: XCTestCase {
    private var fetcher: FakeFetcher!
    private var persistence: MemoryPersistence!
    private var timers: [() -> Void] = []
    private var engine: TranscriptEngine!
    private var changed: [Int64] = []
    private var bag: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        fetcher = FakeFetcher()
        persistence = MemoryPersistence()
        timers = []
        changed = []
        engine = makeEngine()
    }

    private func makeEngine() -> TranscriptEngine {
        let e = TranscriptEngine(fetcher: { [unowned self] in self.fetcher }, persistence: persistence) { [unowned self] delay, block in
            XCTAssertEqual(delay, TranscriptEngine.timeout)
            self.timers.append(block)
        }
        e.changes.sink { [unowned self] in self.changed.append($0) }.store(in: &bag)
        return e
    }

    func test_successGoesLoadingThenDoneAndPersists() {
        engine.request(7)
        XCTAssertEqual(engine.entry(for: 7)?.status, .loading)

        fetcher.calls[0].completion("你好")

        XCTAssertEqual(engine.entry(for: 7), TranscriptEngine.Entry(status: .done, text: "你好", hidden: false))
        XCTAssertEqual(persistence.done[7]?.text, "你好")
        XCTAssertTrue(changed.count >= 2)
    }

    func test_failureIsErrorAndRetryable() {
        engine.request(7)
        fetcher.calls[0].completion(nil)
        XCTAssertEqual(engine.entry(for: 7)?.status, .error)
        XCTAssertNil(persistence.done[7])

        engine.request(7)
        XCTAssertEqual(fetcher.calls.count, 2)
    }

    func test_noFetcherIsError() {
        let e = TranscriptEngine(fetcher: { nil }, persistence: persistence) { _, _ in }
        e.request(7)
        XCTAssertEqual(e.entry(for: 7)?.status, .error)
    }

    func test_requestWhileLoadingIsNoop() {
        engine.request(7)
        engine.request(7)
        XCTAssertEqual(fetcher.calls.count, 1)
    }

    func test_timeoutTurnsLoadingIntoError() {
        engine.request(7)
        timers[0]()
        XCTAssertEqual(engine.entry(for: 7)?.status, .error)
    }

    func test_lateResultAfterTimeoutIsIgnored() {
        engine.request(7)
        timers[0]()
        fetcher.calls[0].completion("late")
        XCTAssertEqual(engine.entry(for: 7)?.status, .error)
    }

    func test_hideThenRequestUnhidesWithoutNetwork() {
        engine.request(7)
        fetcher.calls[0].completion("a")
        engine.hide(7)
        XCTAssertEqual(persistence.done[7]?.hidden, true)

        engine.request(7)

        XCTAssertEqual(engine.entry(for: 7)?.hidden, false)
        XCTAssertEqual(fetcher.calls.count, 1)
    }

    func test_hideWhileLoadingStaysHidden() {
        engine.request(7)
        engine.hide(7)
        fetcher.calls[0].completion("a")
        XCTAssertEqual(engine.entry(for: 7), TranscriptEngine.Entry(status: .done, text: "a", hidden: true))
    }

    func test_restoresDoneEntriesAndAutoFlag() {
        persistence.done = [9: .init(text: "旧", hidden: false)]
        persistence.auto = true

        let restored = makeEngine()

        XCTAssertEqual(restored.entry(for: 9)?.text, "旧")
        XCTAssertTrue(restored.isAutoTranscribe)
    }

    func test_enqueueAutoIgnoredWhenOff() {
        engine.enqueueAuto(1)
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    func test_enqueueAutoRunsTwoAtATimeAndDedupes() {
        engine.isAutoTranscribe = true
        XCTAssertTrue(persistence.auto)

        engine.enqueueAuto(1)
        engine.enqueueAuto(2)
        engine.enqueueAuto(3)
        engine.enqueueAuto(1)
        XCTAssertEqual(fetcher.calls.count, 2)

        fetcher.calls[0].completion("1")
        XCTAssertEqual(fetcher.calls.count, 3)
        XCTAssertEqual(fetcher.calls[2].uid, 3)
    }

    func test_autoSlotIsFreedOnTimeout() {
        engine.isAutoTranscribe = true
        engine.enqueueAuto(1)
        engine.enqueueAuto(2)
        engine.enqueueAuto(3)

        timers[0]()

        XCTAssertEqual(fetcher.calls.count, 3)
    }

    func test_userDefaultsPersistenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "TranscriptEngineTests-\(UUID().uuidString)")!
        let p = UserDefaultsTranscriptPersistence(defaults: defaults)
        p.saveDone([5: .init(text: "x", hidden: true)])
        p.saveAuto(true)

        XCTAssertEqual(p.loadDone()[5]?.text, "x")
        XCTAssertEqual(p.loadDone()[5]?.hidden, true)
        XCTAssertTrue(p.loadAuto())
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift test --filter IMKitTests/TranscriptEngineTests && swift test --filter IMKitTests/VoiceTranscriptRulesTests`
Expected: 编译失败（类型不存在）。

- [ ] **Step 4: SpeechToTextFetching**

`Sources/IMKit/SpeechToTextFetching.swift`：

```swift
import Foundation
import IMMessaging

/// 语音转文字能力。completion 在主队列回调：成功为文本（可能为空串），失败为 nil。
public protocol SpeechToTextFetching: AnyObject {
    func speechToText(messageUid: Int64, completion: @escaping (String?) -> Void)
}

extension MessagingService: SpeechToTextFetching {}
```

- [ ] **Step 5: TranscriptEngine**

`Sources/IMKit/TranscriptEngine.swift`：

```swift
import Foundation
import Combine

public protocol TranscriptPersistence: AnyObject {
    func loadDone() -> [Int64: TranscriptEngine.Saved]
    func saveDone(_ done: [Int64: TranscriptEngine.Saved])
    func loadAuto() -> Bool
    func saveAuto(_ on: Bool)
}

/// 语音转文字状态机。与 Android `TranscriptEngine` 行为一致：
/// 15 秒超时兜底（迟到结果丢弃）、识别中隐藏会保留、自动队列并发 2。
/// 线程约定：全部在主队列调用。
public final class TranscriptEngine {
    public static let timeout: TimeInterval = 15
    public static let autoConcurrency = 2

    public enum Status: Equatable { case loading, done, error }

    public struct Entry: Equatable {
        public let status: Status
        public let text: String
        public let hidden: Bool
        public init(status: Status, text: String, hidden: Bool) {
            self.status = status
            self.text = text
            self.hidden = hidden
        }
    }

    public struct Saved: Codable, Equatable {
        public let text: String
        public let hidden: Bool
        public init(text: String, hidden: Bool) {
            self.text = text
            self.hidden = hidden
        }
    }

    /// 变化的 messageUid，会话页据此刷新对应气泡
    public let changes = PassthroughSubject<Int64, Never>()

    private let fetcher: () -> SpeechToTextFetching?
    private let persistence: TranscriptPersistence
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    private var entries: [Int64: Entry] = [:]
    private var inflight: [Int64: Int] = [:]
    private var autoQueue: [Int64] = []
    private var autoRunning: Set<Int64> = []
    private var seq = 0

    public var isAutoTranscribe: Bool {
        didSet { persistence.saveAuto(isAutoTranscribe) }
    }

    /// - Parameter fetcher: 每次请求时取当前的 `MessagingService`（登出 / 重登会替换实例）
    public init(fetcher: @escaping () -> SpeechToTextFetching?,
                persistence: TranscriptPersistence,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.fetcher = fetcher
        self.persistence = persistence
        self.schedule = schedule
        self.isAutoTranscribe = persistence.loadAuto()
        for (uid, saved) in persistence.loadDone() {
            entries[uid] = Entry(status: .done, text: saved.text, hidden: saved.hidden)
        }
    }

    public func entry(for uid: Int64) -> Entry? { entries[uid] }

    public func request(_ uid: Int64) {
        if let cur = entries[uid] {
            if cur.status == .loading { return }
            if cur.status == .done {
                if cur.hidden {
                    put(uid, Entry(status: .done, text: cur.text, hidden: false))
                    persist()
                }
                return
            }
        }
        seq += 1
        let gen = seq
        inflight[uid] = gen
        put(uid, Entry(status: .loading, text: "", hidden: false))
        guard let fetcher = fetcher() else {
            finish(uid, gen: gen, text: nil)
            return
        }
        schedule(Self.timeout) { [weak self] in self?.finish(uid, gen: gen, text: nil) }
        fetcher.speechToText(messageUid: uid) { [weak self] text in
            self?.finish(uid, gen: gen, text: text)
        }
    }

    public func hide(_ uid: Int64) {
        guard let cur = entries[uid] else { return }
        put(uid, Entry(status: cur.status, text: cur.text, hidden: true))
        persist()
    }

    /// 实时收到的他人语音：开关打开时排队自动识别，已有结果或已在队列中的跳过
    public func enqueueAuto(_ uid: Int64) {
        guard isAutoTranscribe, entries[uid] == nil, !autoQueue.contains(uid), !autoRunning.contains(uid) else { return }
        autoQueue.append(uid)
        drain()
    }

    private func drain() {
        while autoRunning.count < Self.autoConcurrency, !autoQueue.isEmpty {
            let uid = autoQueue.removeFirst()
            autoRunning.insert(uid)
            request(uid)
        }
    }

    private func finish(_ uid: Int64, gen: Int, text: String?) {
        guard inflight[uid] == gen else { return }
        inflight[uid] = nil
        let hidden = entries[uid]?.hidden ?? false
        if let text {
            put(uid, Entry(status: .done, text: text, hidden: hidden))
        } else {
            put(uid, Entry(status: .error, text: "", hidden: hidden))
        }
        persist()
        if autoRunning.remove(uid) != nil { drain() }
    }

    private func put(_ uid: Int64, _ entry: Entry) {
        entries[uid] = entry
        changes.send(uid)
    }

    private func persist() {
        var done: [Int64: Saved] = [:]
        for (uid, e) in entries where e.status == .done {
            done[uid] = Saved(text: e.text, hidden: e.hidden)
        }
        persistence.saveDone(done)
    }
}
```

- [ ] **Step 6: VoiceTranscriptRules**

`Sources/IMKit/VoiceTranscriptRules.swift`：

```swift
import Foundation

/// 语音气泡上转文字相关控件的显示规则，与 electron / web / android 一致
public enum VoiceTranscriptRules {
    public static let realtimeWindowMillis: Int64 = 120_000

    public enum Block: Equatable { case none, loading, text, empty, error }

    public static func showPill(isIncoming: Bool, isPlayed: Bool, messageUid: Int64, entry: TranscriptEngine.Entry?, auto: Bool) -> Bool {
        isIncoming && !isPlayed && messageUid > 0 && entry == nil && !auto
    }

    public static func block(_ entry: TranscriptEngine.Entry?) -> Block {
        guard let entry, !entry.hidden else { return .none }
        switch entry.status {
        case .loading: return .loading
        case .error: return .error
        case .done: return entry.text.isEmpty ? .empty : .text
        }
    }

    private static func showing(_ entry: TranscriptEngine.Entry?) -> Bool {
        guard let entry else { return false }
        return !entry.hidden && entry.status != .error
    }

    public static func showTranscribeMenu(messageUid: Int64, entry: TranscriptEngine.Entry?) -> Bool {
        messageUid > 0 && !showing(entry)
    }

    public static func showHideMenu(messageUid: Int64, entry: TranscriptEngine.Entry?) -> Bool {
        messageUid > 0 && showing(entry)
    }

    /// 长时间离线后积压的语音不自动识别，只识别 2 分钟内到达的
    public static func isRealtime(serverTimestamp: Int64, serverDelta: Int64, now: Int64) -> Bool {
        now - (serverTimestamp - serverDelta) <= realtimeWindowMillis
    }
}
```

- [ ] **Step 7: UserDefaultsTranscriptPersistence**

`Sources/IMKit/UserDefaultsTranscriptPersistence.swift`：

```swift
import Foundation

public final class UserDefaultsTranscriptPersistence: TranscriptPersistence {
    private static let entriesKey = "voiceTranscript.entries"
    private static let autoKey = "voiceTranscript.auto"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadDone() -> [Int64: TranscriptEngine.Saved] {
        guard let data = defaults.data(forKey: Self.entriesKey),
              let decoded = try? JSONDecoder().decode([String: TranscriptEngine.Saved].self, from: data) else { return [:] }
        var out: [Int64: TranscriptEngine.Saved] = [:]
        for (k, v) in decoded { if let uid = Int64(k) { out[uid] = v } }
        return out
    }

    public func saveDone(_ done: [Int64: TranscriptEngine.Saved]) {
        let keyed = Dictionary(uniqueKeysWithValues: done.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(keyed) {
            defaults.set(data, forKey: Self.entriesKey)
        }
    }

    public func loadAuto() -> Bool { defaults.bool(forKey: Self.autoKey) }

    public func saveAuto(_ on: Bool) { defaults.set(on, forKey: Self.autoKey) }
}
```

- [ ] **Step 8: 运行测试确认通过**

Run: `swift test --filter IMKitTests`
Expected: PASS（新增 17 个）

- [ ] **Step 9: Commit**

```bash
git add Sources/IMKit/SpeechToTextFetching.swift Sources/IMKit/TranscriptEngine.swift Sources/IMKit/VoiceTranscriptRules.swift Sources/IMKit/UserDefaultsTranscriptPersistence.swift Tests/IMKitTests/TranscriptEngineTests.swift Tests/IMKitTests/VoiceTranscriptRulesTests.swift
git commit -m "feat(imkit): 语音转文字状态机、显示规则与持久化"
```

---

### Task 5: 接线（AppEnvironment 事件转发、ConversationViewModel、SceneDelegate）

**Files:**
- Modify: `Sources/AppCore/AppEnvironment.swift`（属性区、`connectIfPossible`）
- Modify: `Sources/IMKit/ConversationViewModel.swift`（init 参数、`transcripts` 属性、`markPlayed(row:)`）
- Modify: `App/SceneDelegate.swift`（持有引擎；5 处 `ConversationViewModel(` 传参；订阅新语音事件）
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift`（追加 `markPlayed` 用例）

**Interfaces:**
- Consumes: Task 2 `MessageStore.markPlayed(id:)`；Task 3 `onIncomingVoiceMessage`；Task 4 引擎与规则
- Produces:
  - `AppEnvironment.onIncomingVoiceMessage: ((_ messageUid: Int64, _ serverTimestamp: Int64, _ serverDeltaMillis: Int64) -> Void)?`
  - `ConversationViewModel.transcripts: TranscriptEngine?`、`ConversationViewModel.markPlayed(row: StoredMessageRow)`
  - `SceneDelegate.transcriptEngine: TranscriptEngine`（private）

- [ ] **Step 1: 写 markPlayed 失败测试**

在 `Tests/IMKitTests/ConversationViewModelTests.swift` 中，参照该文件已有用例构造 `storage` 与 `ConversationViewModel` 的方式追加：

```swift
    func test_markPlayed_setsIncomingVoiceToPlayed() throws {
        let inserted = try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 900, conversationType: .single, target: "them", from: "them",
            content: .voice(remoteURL: "http://x/a.amr", localPath: nil, duration: 3),
            timestamp: 1_000, status: .unread, direction: .receive
        ))
        let row = StoredMessageRow(storageId: inserted.id!, localMessageId: 1, messageUid: 900, isOutgoing: false,
                                   status: .unread, timestamp: 1_000, text: "[语音]", imageThumbnail: nil,
                                   imageRemoteURL: "http://x/a.amr", voiceDuration: 3)

        viewModel.markPlayed(row: row)

        XCTAssertEqual(try storage.messages.message(uid: 900)?.status, .played)
    }
```

（`storage` / `viewModel` 用该测试类 `setUp` 中已有的实例名；若 `setUp` 构造的会话不是 `.single`/`"them"`，改成一致的会话参数。）

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter IMKitTests/ConversationViewModelTests`
Expected: 编译失败 `value of type 'ConversationViewModel' has no member 'markPlayed'`。

- [ ] **Step 3: ConversationViewModel**

1. 属性区 `private let remoteHistory: RemoteHistoryFetching?` 之后加：

```swift
    /// 语音转文字引擎，由 `SceneDelegate` 注入；为 nil 时会话页不显示转文字入口
    public let transcripts: TranscriptEngine?
```

2. `public init(...)` 参数列表末尾加 `transcripts: TranscriptEngine? = nil`，方法体中加 `self.transcripts = transcripts`。
3. `deleteMessage(row:)` 之后加：

```swift
    /// 他人语音置为已播放（播放或点「转文字」时调用），GRDB 观察会刷新气泡
    public func markPlayed(row: StoredMessageRow) {
        guard !row.isOutgoing, row.status != .played else { return }
        try? storage.messages.markPlayed(id: row.storageId)
    }
```

- [ ] **Step 4: AppEnvironment 事件转发**

1. `public var onIncomingMessageAlert: ...` 之后加：

```swift
    /// 新收到的他人语音（不含首次登录全量拉取）。`SceneDelegate` 据此做自动转文字。
    /// 与 `onIncomingMessageAlert` 同样挂在 environment 上，跨登出 / 重登保持。
    public var onIncomingVoiceMessage: ((_ messageUid: Int64, _ serverTimestamp: Int64, _ serverDeltaMillis: Int64) -> Void)?
```

2. `connectIfPossible()` 中 `service.onIncomingMessageAlert = { ... }` 之后加：

```swift
        service.onIncomingVoiceMessage = { [weak self] uid, serverTimestamp in
            self?.onIncomingVoiceMessage?(uid, serverTimestamp, client.serverTimeDeltaMillis)
        }
```

- [ ] **Step 5: SceneDelegate**

1. `private var environment: AppEnvironment!` 之后加：

```swift
    private lazy var transcriptEngine = TranscriptEngine(
        fetcher: { [weak self] in self?.environment.messagingService },
        persistence: UserDefaultsTranscriptPersistence(),
        schedule: { delay, block in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block) }
    )
```

2. 在 `environment` 赋值之后、设置 `environment.onIncomingMessageAlert` 的位置附近（`grep -n "onIncomingMessageAlert" App/SceneDelegate.swift` 定位）加：

```swift
        environment.onIncomingVoiceMessage = { [weak self] uid, serverTimestamp, delta in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            guard VoiceTranscriptRules.isRealtime(serverTimestamp: serverTimestamp, serverDelta: delta, now: now) else { return }
            self?.transcriptEngine.enqueueAuto(uid)
        }
```

3. 文件中 5 处 `ConversationViewModel(`（第 201、251、453、573、619 行附近）的参数列表末尾各加 `transcripts: transcriptEngine`（在闭包内用 `self.transcriptEngine` / 已捕获的 `self`，与该处其它参数的写法一致）。

4. 若 `SceneDelegate.swift` 未 import `IMKit`，补 `import IMKit`。

- [ ] **Step 6: 运行测试与编译**

Run: `swift test --filter IMKitTests && swift test --filter AppCoreTests && xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: 测试 PASS，`** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Sources/AppCore/AppEnvironment.swift Sources/IMKit/ConversationViewModel.swift App/SceneDelegate.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat: 转文字引擎接入会话页与自动识别"
```

---

### Task 6: 语音气泡 UI 与长按菜单

**Files:**
- Modify: `App/VoiceMessageCell.swift`
- Modify: `App/ConversationViewController.swift`（`configureDataSource` 第 199–205 行、`viewDidLoad` 订阅、`buildMenuItems` 第 812 行）

**Interfaces:**
- Consumes: Task 4 `TranscriptEngine` / `VoiceTranscriptRules`；Task 5 `viewModel.transcripts`、`viewModel.markPlayed(row:)`
- Produces: `VoiceMessageCell.configure(with:transcript:showPill:)`、`onTranscribeTapped`、`onTranscriptRetryTapped`

显示规则已在 Task 4 单测覆盖，本 Task 为 UIKit 接线，验证为编译 + Task 8 手动走查。

- [ ] **Step 1: VoiceMessageCell**

1. 属性区 `var onAvatarLongPressed` 之后加：

```swift
    var onTranscribeTapped: (() -> Void)?
    var onTranscriptRetryTapped: (() -> Void)?

    private let unplayedDot = UIView()
    private let transcribePill = UIButton(type: .system)
    private let transcriptLabel = PaddingLabel()
    private let bubbleRow = UIStackView()
```

2. `prepareForReuse()` 中追加 `onTranscribeTapped = nil; onTranscriptRetryTapped = nil`。

3. `layoutViews()` 中，把 `bubbleColumn.addArrangedSubview(bubbleView)` 改为：

```swift
        unplayedDot.backgroundColor = .systemRed
        unplayedDot.layer.cornerRadius = 4
        unplayedDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            unplayedDot.widthAnchor.constraint(equalToConstant: 8),
            unplayedDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        transcribePill.setTitle("转文字", for: .normal)
        transcribePill.titleLabel?.font = .systemFont(ofSize: 12)
        transcribePill.setTitleColor(Theme.textSecondary, for: .normal)
        transcribePill.backgroundColor = Theme.backgroundTertiary
        transcribePill.layer.cornerRadius = 12
        transcribePill.contentEdgeInsets = UIEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        transcribePill.addTarget(self, action: #selector(pillTapped), for: .touchUpInside)

        bubbleRow.axis = .horizontal
        bubbleRow.spacing = 8
        bubbleRow.alignment = .center
        bubbleRow.addArrangedSubview(bubbleView)
        bubbleRow.addArrangedSubview(unplayedDot)
        bubbleRow.addArrangedSubview(transcribePill)

        transcriptLabel.numberOfLines = 0
        transcriptLabel.font = .systemFont(ofSize: 14)
        transcriptLabel.backgroundColor = Theme.backgroundTertiary
        transcriptLabel.layer.cornerRadius = 8
        transcriptLabel.layer.masksToBounds = true
        transcriptLabel.isUserInteractionEnabled = true
        transcriptLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(transcriptTapped)))

        bubbleColumn.addArrangedSubview(bubbleRow)
        bubbleColumn.addArrangedSubview(transcriptLabel)
```

（原 `bubbleColumn.spacing = 2` 不变；`statusIndicator` 仍钉在 `bubbleView` 左侧，不受影响。）

4. 新增：

```swift
    @objc private func pillTapped() { onTranscribeTapped?() }

    private var transcriptIsError = false
    @objc private func transcriptTapped() {
        if transcriptIsError { onTranscriptRetryTapped?() }
    }

    private func applyTranscript(isOutgoing: Bool, showDot: Bool, showPill: Bool, entry: TranscriptEngine.Entry?) {
        // 他人语音：气泡在左，红点/按钮在右；自己发的语音不显示红点/按钮
        unplayedDot.isHidden = isOutgoing || !showDot
        transcribePill.isHidden = isOutgoing || !showPill
        transcriptIsError = false
        switch VoiceTranscriptRules.block(entry) {
        case .none:
            transcriptLabel.isHidden = true
        case .loading:
            transcriptLabel.isHidden = false
            transcriptLabel.text = "转文字中…"
            transcriptLabel.textColor = Theme.textSecondary
        case .error:
            transcriptLabel.isHidden = false
            transcriptLabel.text = "转文字失败，点击重试"
            transcriptLabel.textColor = .systemRed
            transcriptIsError = true
        case .empty:
            transcriptLabel.isHidden = false
            transcriptLabel.text = "未识别到文字"
            transcriptLabel.textColor = Theme.textSecondary
        case .text:
            transcriptLabel.isHidden = false
            transcriptLabel.text = entry?.text
            transcriptLabel.textColor = Theme.textPrimary
        }
    }
```

5. 把 `func configure(with row: StoredMessageRow)` 改为：

```swift
    func configure(with row: StoredMessageRow, transcript: TranscriptEngine.Entry? = nil, showPill: Bool = false) {
        let status: MessageStatusIndicatorView.Status
        if row.isOutgoing, row.status == .sending {
            status = .sending
        } else if row.isOutgoing, row.status == .sendFailure {
            status = .failed
        } else {
            status = .none
        }
        applyBubble(
            isOutgoing: row.isOutgoing, duration: row.voiceDuration ?? 0, status: status,
            avatarURL: row.senderAvatarURL, senderDisplayName: row.senderDisplayName
        )
        applyTranscript(isOutgoing: row.isOutgoing, showDot: !row.isOutgoing && row.status != .played, showPill: showPill, entry: transcript)
    }
```

`configurePending(_:)` 末尾加 `applyTranscript(isOutgoing: true, showDot: false, showPill: false, entry: nil)`。

6. 文件末尾新增（若项目中已有带内边距的 UILabel 子类，复用之并删除此定义）：

```swift
/// 带内边距的 UILabel，用于转文字文字块
final class PaddingLabel: UILabel {
    var insets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}
```

文件顶部补 `import IMKit`（已有则跳过）。

- [ ] **Step 2: ConversationViewController — cell 配置**

`configureDataSource` 中语音分支改为：

```swift
            case .message(let message) where message.text?.hasPrefix("[语音]") == true:
                let cell = tableView.dequeueReusableCell(withIdentifier: VoiceMessageCell.reuseIdentifier, for: indexPath) as! VoiceMessageCell
                let engine = self?.viewModel.transcripts
                let entry = engine?.entry(for: message.messageUid)
                let showPill = engine.map {
                    VoiceTranscriptRules.showPill(isIncoming: !message.isOutgoing, isPlayed: message.status == .played,
                                                  messageUid: message.messageUid, entry: entry, auto: $0.isAutoTranscribe)
                } ?? false
                cell.configure(with: message, transcript: entry, showPill: showPill)
                cell.onTapped = { [weak self, weak cell] in
                    self?.viewModel.markPlayed(row: message)
                    self?.playVoice(urlString: message.imageRemoteURL, cell: cell)
                }
                cell.onTranscribeTapped = { [weak self] in self?.transcribe(message) }
                cell.onTranscriptRetryTapped = { [weak self] in self?.viewModel.transcripts?.request(message.messageUid) }
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onAvatarLongPressed = { [weak self] in self?.insertMentionFromAvatar(message) }
                return cell
```

- [ ] **Step 3: ConversationViewController — 转文字动作与刷新**

1. 类中新增：

```swift
    /// 点「转文字」视为已读：消红点
    private func transcribe(_ message: StoredMessageRow) {
        viewModel.markPlayed(row: message)
        viewModel.transcripts?.request(message.messageUid)
    }

    /// 转文字结果变化时只重配对应气泡（ChatMessageRow 本身未变，diffable 不会自动刷新）
    private func reconfigureVoiceRow(messageUid: Int64) {
        var snapshot = dataSource.snapshot()
        let targets = snapshot.itemIdentifiers.filter {
            if case .message(let m) = $0 { return m.messageUid == messageUid }
            return false
        }
        guard !targets.isEmpty else { return }
        snapshot.reconfigureItems(targets)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
```

2. `viewDidLoad` 中（现有 `viewModel.$rows` 订阅附近，使用同一个 cancellables 集合）加：

```swift
        viewModel.transcripts?.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uid in self?.reconfigureVoiceRow(messageUid: uid) }
            .store(in: &cancellables)
```

（集合名以该 VC 中现有 `.store(in:)` 使用的名称为准。）

- [ ] **Step 4: 长按菜单**

`buildMenuItems(for:)` 中 `var items: [PlusMenuView.Item] = []` 之后加：

```swift
        // 转文字 / 隐藏文字 — 语音消息
        if message.voiceDuration != nil, let engine = viewModel.transcripts {
            let entry = engine.entry(for: message.messageUid)
            if VoiceTranscriptRules.showTranscribeMenu(messageUid: message.messageUid, entry: entry) {
                items.append(.init(symbolName: "text.bubble", title: "转文字") { [weak self] in
                    self?.transcribe(message)
                })
            } else if VoiceTranscriptRules.showHideMenu(messageUid: message.messageUid, entry: entry) {
                items.append(.init(symbolName: "eye.slash", title: "隐藏文字") {
                    engine.hide(message.messageUid)
                })
            }
        }
```

- [ ] **Step 5: 编译**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add App/VoiceMessageCell.swift App/ConversationViewController.swift
git commit -m "feat(app): 语音气泡红点、转文字按钮、文字块与长按菜单"
```

---

### Task 7: 设置页「自动转文字」开关

**Files:**
- Modify: `App/SettingsViewController.swift`
- Modify: `App/SceneDelegate.swift`（创建 `SettingsViewController` 处）

**Interfaces:**
- Consumes: Task 5 `SceneDelegate.transcriptEngine`
- Produces: `SettingsViewController.autoTranscribe: (get: () -> Bool, set: (Bool) -> Void)?`

- [ ] **Step 1: SettingsViewController**

1. `Row` 枚举改为：

```swift
    private enum Row: Int, CaseIterable {
        case theme
        case autoTranscribe
        case about
        case logout
    }
```

2. 回调属性区加：

```swift
    /// Set by `SceneDelegate` — 读写转文字引擎的自动转文字开关
    var autoTranscribe: (get: () -> Bool, set: (Bool) -> Void)?
```

3. `viewDidLoad` 中 `tableView.delegate = self` 之后加：

```swift
        tableView.register(ToggleSwitchCell.self, forCellReuseIdentifier: "toggle")
```

4. `cellForRowAt` 中，在 `let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ...` 之前加：

```swift
        if Row(rawValue: indexPath.row) == .autoTranscribe {
            let toggle = tableView.dequeueReusableCell(withIdentifier: "toggle", for: indexPath) as! ToggleSwitchCell
            toggle.configure(title: "自动转文字", isOn: autoTranscribe?.get() ?? false)
            toggle.onToggle = { [weak self] isOn in self?.autoTranscribe?.set(isOn) }
            toggle.backgroundColor = Theme.backgroundTertiary
            return toggle
        }
```

`switch` 中补 `case .autoTranscribe: break`（不会走到，仅为穷尽）；`didSelectRowAt` 的 `switch` 中补 `case .autoTranscribe: break`。

- [ ] **Step 2: SceneDelegate 注入**

`grep -n "SettingsViewController()" App/SceneDelegate.swift` 定位创建处，在设置 `onThemeTapped` 的同一位置加：

```swift
        settingsViewController.autoTranscribe = (
            get: { [weak self] in self?.transcriptEngine.isAutoTranscribe ?? false },
            set: { [weak self] isOn in self?.transcriptEngine.isAutoTranscribe = isOn }
        )
```

（变量名以该处实际的 `SettingsViewController` 实例名为准。）

- [ ] **Step 3: 编译**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 全量单测**

Run: `swift test`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add App/SettingsViewController.swift App/SceneDelegate.swift
git commit -m "feat(app): 设置页自动转文字开关"
```

---

### Task 8: 手动走查（依赖服务端已部署并开启 `push.asr.enabled`）

- [ ] **Step 1: 安装**

模拟器（iPhone 15）或真机（见 CLAUDE.md「真机部署」）安装，`13800000001` 登录，另一端 `13800000000`。

- [ ] **Step 2: 走查清单**

1. 升级安装（保留旧数据）后，历史语音没有红点。
2. 对方发语音 → 气泡右侧红点 + 「转文字」按钮。
3. 点「转文字」→ 红点与按钮消失，下方「转文字中…」→ 出文字。
4. 长按 → 只有「隐藏文字」；点击后文字块消失；再长按只有「转文字」，点击立即恢复（无新请求）。
5. 新语音直接点播放 → 红点与按钮消失；长按「转文字」可转。
6. 设置 → 打开「自动转文字」→ 新语音自动出文字，红点保留，无按钮。
7. 开飞行模式点「转文字」→ 立即或 15 秒内显示「转文字失败，点击重试」；恢复网络点击重试成功。
8. 杀进程重启 → 已转文字、隐藏状态、开关均保持。
9. 深色 / 浅色模式下颜色正常；自己发的语音长按可转文字，文字块在右侧。
