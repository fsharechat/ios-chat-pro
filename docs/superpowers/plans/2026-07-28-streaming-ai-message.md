# 官方客服流式消息(SAI)接收展示 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS 端接收并流式展示服务端推送的官方客服(AI)增量消息(`PUBLISH`/`SAI`),对齐 android-chat-pro 的占位气泡设计。

**Architecture:** `IMMessaging` 新增 `StreamingAiHandler` 解析 SAI JSON 帧,`MessagingService` 持有 `activeStream` 状态机并上抛 `onSaiToken`;`IMKit.ConversationViewModel` 用内存态 `.streaming` 占位行拼进 `publishRows()`(复用 pendingImages 模式);App 层 `TextMessageCell` 渲染 `▌` 光标并自动跟底。完整消息由服务端流结束后走正常 MN→拉取→入库通道,占位行被真实消息"原位替换"。

**Tech Stack:** Swift Package(无新依赖),XCTest,GRDB ValueObservation,UIKit diffable data source。

**Spec:** `docs/superpowers/specs/2026-07-28-streaming-ai-message.md`

## Global Constraints

- 所有回复/注释用中文;注释只写代码本身看不出的约束(遵循周围代码风格)
- 线程模型:无锁,全部主队列调用(项目全局约定)
- 依赖方向严格单向:IMTransport ← IMClient ← IMMessaging ← IMKit ← App
- **不要中途 commit**:用户要求装机验证通过后才提交(memory: commit-after-verification)。每个任务以"测试通过"收尾,最后统一提交一个 feat commit
- `swift test --filter` 必须用**测试类名**(如 `--filter StreamingAiHandlerTests`),target 前缀形式会假绿(Executed 0 tests);跑完必须确认 `Executed N > 0`
- 若 swift test 构建报 WebRTC 头文件缺失:从 `.build/artifacts/*/WebRTC/WebRTC.xcframework/ios-arm64/WebRTC.framework/Headers/` rsync 头文件(排除 WebRTC.h)到 `macos-x86_64_arm64/WebRTC.framework/Versions/A/Headers/`,并创建空 `RTCMTLNSVideoView.h` 占位
- 主干有固有测试失败基线(MessageContentCodecTests 3 个、MediaUploadServiceTests、ConversationViewModelTests 2 个 flaky、GroupInfoViewModelTests 1 个、IMCallTests GRDB 崩溃)——勿误判为回归,只关注本次新增测试

---

### Task 1: IMMessaging — StreamingAiHandler(SAI 帧解析)

**Files:**
- Create: `Sources/IMMessaging/StreamingAiHandler.swift`
- Test: `Tests/IMMessagingTests/StreamingAiHandlerTests.swift`

**Interfaces:**
- Consumes: `IMClient.MessageHandler` 协议(`canHandle(signal:subSignal:)` + `handle(frame:)`)、`IMTransport.Frame/Header/Signal/SubSignal`
- Produces:
  - `public struct StreamingState { streamId: String, target: String, accumulatedText: String, done: Bool }`(Equatable)
  - `public final class StreamingAiHandler: MessageHandler`,回调 `onSaiToken: ((_ streamId: String, _ delta: String, _ done: Bool, _ target: String) -> Void)?`

- [ ] **Step 1: 写失败测试**

创建 `Tests/IMMessagingTests/StreamingAiHandlerTests.swift`:

```swift
import XCTest
import IMClient
import IMTransport
@testable import IMMessaging

final class StreamingAiHandlerTests: XCTestCase {
    private func saiFrame(json: String) -> Frame {
        let body = Data(json.utf8)
        return Frame(header: Header(signal: .publish, subSignal: .sai, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    func test_canHandle_onlyMatchesPublishAndSAI() {
        let handler = StreamingAiHandler()
        XCTAssertTrue(handler.canHandle(signal: .publish, subSignal: .sai))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mn))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .sai))
    }

    func test_handle_parsesAllFourFields() {
        let handler = StreamingAiHandler()
        var captured: (String, String, Bool, String)?
        handler.onSaiToken = { captured = ($0, $1, $2, $3) }

        handler.handle(frame: saiFrame(json: #"{"i":"s1","d":"你好","f":false,"t":"agent"}"#))

        XCTAssertEqual(captured?.0, "s1")
        XCTAssertEqual(captured?.1, "你好")
        XCTAssertEqual(captured?.2, false)
        XCTAssertEqual(captured?.3, "agent")
    }

    func test_handle_doneTrue_isForwarded() {
        let handler = StreamingAiHandler()
        var capturedDone: Bool?
        handler.onSaiToken = { capturedDone = $2 }

        handler.handle(frame: saiFrame(json: #"{"i":"s1","d":"","f":true,"t":"agent"}"#))

        XCTAssertEqual(capturedDone, true)
    }

    func test_handle_missingField_isSilentlyDropped() {
        let handler = StreamingAiHandler()
        var invoked = false
        handler.onSaiToken = { _, _, _, _ in invoked = true }

        handler.handle(frame: saiFrame(json: #"{"i":"s1","d":"x","f":false}"#))

        XCTAssertFalse(invoked)
    }

    func test_handle_nonJSONBody_isSilentlyDropped() {
        let handler = StreamingAiHandler()
        var invoked = false
        handler.onSaiToken = { _, _, _, _ in invoked = true }

        handler.handle(frame: Frame(header: Header(signal: .publish, subSignal: .sai, bodyLength: 2, messageId: 1), body: Data([0xFF, 0xFE])))

        XCTAssertFalse(invoked)
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `swift test --filter StreamingAiHandlerTests`
Expected: 编译失败,`cannot find 'StreamingAiHandler' in scope`

- [ ] **Step 3: 写最小实现**

创建 `Sources/IMMessaging/StreamingAiHandler.swift`:

```swift
import Foundation
import IMClient
import IMTransport

/// 一次流式 AI(官方客服)回复的累积状态,对齐 Android
/// `ChatManager.StreamingState`。由 `MessagingService` 持有并更新,
/// 供会话页中途退出重进时恢复占位气泡。
public struct StreamingState: Equatable {
    public let streamId: String
    public let target: String
    public let accumulatedText: String
    public let done: Bool

    public init(streamId: String, target: String, accumulatedText: String, done: Bool) {
        self.streamId = streamId
        self.target = target
        self.accumulatedText = accumulatedText
        self.done = done
    }
}

/// 解析服务端推送的流式 AI 增量帧(`PUBLISH`/`SAI`),对齐 Android
/// `StreamingAiHandler`。payload 为明文 JSON:
/// `{"i":"streamId","d":"delta","f":true/false,"t":"agentUserId"}`,
/// 任一字段缺失或非 JSON 时静默丢弃(与 Android 仅打日志的行为一致)。
public final class StreamingAiHandler: MessageHandler {
    public var onSaiToken: ((_ streamId: String, _ delta: String, _ done: Bool, _ target: String) -> Void)?

    public init() {}

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .publish && subSignal == .sai
    }

    public func handle(frame: Frame) {
        guard
            let obj = (try? JSONSerialization.jsonObject(with: frame.body)) as? [String: Any],
            let streamId = obj["i"] as? String,
            let delta = obj["d"] as? String,
            let done = obj["f"] as? Bool,
            let target = obj["t"] as? String
        else { return }
        onSaiToken?(streamId, delta, done, target)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter StreamingAiHandlerTests`
Expected: PASS,`Executed 5 tests`(必须确认非 0)

---

### Task 2: MessagingService — activeStream 状态机 + handler 注册

**Files:**
- Modify: `Sources/IMMessaging/MessagingService.swift`(init 注册 handler;新增属性/方法)
- Test: `Tests/IMMessagingTests/MessagingServiceTests.swift`(追加测试)

**Interfaces:**
- Consumes: Task 1 的 `StreamingAiHandler`(`onSaiToken` 闭包)、`StreamingState`
- Produces(`MessagingService` 上,Task 3 的协议将映射这三个成员):
  - `public private(set) var activeStream: StreamingState?`
  - `public var onSaiToken: ((_ streamId: String, _ delta: String, _ done: Bool, _ target: String) -> Void)?`
  - `public func clearActiveStream()`

- [ ] **Step 1: 写失败测试**

在 `Tests/IMMessagingTests/MessagingServiceTests.swift` 末尾(类内)追加:

```swift
    // MARK: - SAI 流式状态机

    private func simulateSai(_ json: String) {
        let body = Data(json.utf8)
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .publish, subSignal: .sai, messageId: 0, body: body))
    }

    func test_saiStream_stateMachine_accumulatesTextAndMarksDone() {
        simulateSai(#"{"i":"s1","d":"","f":false,"t":"agent"}"#)
        XCTAssertEqual(service.activeStream, StreamingState(streamId: "s1", target: "agent", accumulatedText: "", done: false))

        simulateSai(#"{"i":"s1","d":"你","f":false,"t":"agent"}"#)
        simulateSai(#"{"i":"s1","d":"好","f":false,"t":"agent"}"#)
        XCTAssertEqual(service.activeStream?.accumulatedText, "你好")
        XCTAssertEqual(service.activeStream?.done, false)

        simulateSai(#"{"i":"s1","d":"","f":true,"t":"agent"}"#)
        XCTAssertEqual(service.activeStream?.accumulatedText, "你好")
        XCTAssertEqual(service.activeStream?.done, true)
    }

    func test_saiStream_mismatchedStreamId_ignoredByStateMachine_butStillForwarded() {
        var forwarded: [String] = []
        service.onSaiToken = { streamId, _, _, _ in forwarded.append(streamId) }

        simulateSai(#"{"i":"s1","d":"","f":false,"t":"agent"}"#)
        simulateSai(#"{"i":"s2","d":"x","f":false,"t":"agent"}"#)

        XCTAssertEqual(service.activeStream, StreamingState(streamId: "s1", target: "agent", accumulatedText: "", done: false))
        XCTAssertEqual(forwarded, ["s1", "s2"])
    }

    func test_saiStream_clearActiveStream_resetsState() {
        simulateSai(#"{"i":"s1","d":"","f":false,"t":"agent"}"#)
        service.clearActiveStream()
        XCTAssertNil(service.activeStream)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MessagingServiceTests`
Expected: 编译失败,`value of type 'MessagingService' has no member 'activeStream'`

- [ ] **Step 3: 写实现**

`Sources/IMMessaging/MessagingService.swift` 三处修改:

(a) 存储属性区(`private let remoteMessageAckHandler: RemoteMessageAckHandler` 之后)加:

```swift
    private let streamingAiHandler: StreamingAiHandler
```

(b) `onMessageRecalled` 计算属性之后加:

```swift
    /// 当前活跃的流式 AI(官方客服)回复,对齐 Android `ChatManager` 的
    /// `activeStream`——会话页中途退出重进时用它恢复占位气泡;真实完整
    /// 消息入库替换占位后由 UI 调 `clearActiveStream()` 清掉。
    public private(set) var activeStream: StreamingState?

    /// SAI 增量事件的单监听者(同 Android `setOnSaiTokenListener`),由
    /// 当前打开的会话页 ViewModel 绑定;无论状态机是否吃下该事件都会
    /// 原样上抛(与 Android 先更新 activeStream 再回调 listener 一致)。
    public var onSaiToken: ((_ streamId: String, _ delta: String, _ done: Bool, _ target: String) -> Void)?

    public func clearActiveStream() {
        activeStream = nil
    }
```

(c) init 内:`let remoteAckHandlerInstance = RemoteMessageAckHandler()` /
`remoteMessageAckHandler = remoteAckHandlerInstance` 两行之后(仍在所有
`[weak self]` 闭包之前,满足 Swift phase-1 init 约束)加存储属性赋值:

```swift
        let streamingHandler = StreamingAiHandler()
        streamingAiHandler = streamingHandler
```

init 末尾 `imClient.register(remoteAckHandlerInstance)` 之后加:

```swift
        streamingHandler.onSaiToken = { [weak self] streamId, delta, done, target in
            self?.handleSaiToken(streamId: streamId, delta: delta, done: done, target: target)
        }
        imClient.register(streamingHandler)
```

(d) 类内(如 `clearActiveStream()` 附近)加私有状态机,分支条件逐条对齐
Android `ChatManager.onSaiToken`:

```swift
    private func handleSaiToken(streamId: String, delta: String, done: Bool, target: String) {
        if !done, delta.isEmpty, activeStream == nil {
            activeStream = StreamingState(streamId: streamId, target: target, accumulatedText: "", done: false)
        } else if !done, !delta.isEmpty, let stream = activeStream, stream.streamId == streamId {
            activeStream = StreamingState(streamId: streamId, target: target, accumulatedText: stream.accumulatedText + delta, done: false)
        } else if done, let stream = activeStream, stream.streamId == streamId {
            activeStream = StreamingState(streamId: streamId, target: target, accumulatedText: stream.accumulatedText, done: true)
        }
        onSaiToken?(streamId, delta, done, target)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter MessagingServiceTests`
Expected: PASS(新增 3 个测试全绿,`Executed N > 0`;原有测试不回归)

---

### Task 3: IMKit — StreamingRow 占位行 + ConversationViewModel 生命周期

**Files:**
- Create: `Sources/IMKit/StreamingAiObserving.swift`
- Modify: `Sources/IMKit/ChatMessageRow.swift`(新 case + 三个 switch)
- Modify: `Sources/IMKit/ConversationViewModel.swift`
- Test: `Tests/IMKitTests/ConversationViewModelStreamingTests.swift`(新建)

**Interfaces:**
- Consumes: Task 2 的 `MessagingService.activeStream`/`onSaiToken`/`clearActiveStream()`、`IMMessaging.StreamingState`
- Produces:
  - `public protocol StreamingAiObserving: AnyObject`(三成员,签名见下)+ `extension MessagingService: StreamingAiObserving {}`
  - `public struct StreamingRow { streamId: String, text: String, done: Bool }`(Equatable, Hashable)
  - `ChatMessageRow` 新 case `.streaming(StreamingRow)`
  - `ConversationViewModel.init` 新可选参数 `streaming: StreamingAiObserving? = nil`(位于 `activeTracking:` 之后)

- [ ] **Step 1: 写失败测试**

创建 `Tests/IMKitTests/ConversationViewModelStreamingTests.swift`:

```swift
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
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `swift test --filter ConversationViewModelStreamingTests`
Expected: 编译失败,`cannot find type 'StreamingAiObserving' in scope`

- [ ] **Step 3: 写实现 — StreamingAiObserving 协议**

创建 `Sources/IMKit/StreamingAiObserving.swift`:

```swift
import IMMessaging

/// `ConversationViewModel` 依赖的流式 AI(官方客服)窄接口,而非具体的
/// `MessagingService`——与 `MessageSending`/`ContactInfoFetching` 相同的
/// 可测性解耦模式。`onSaiToken` 是单监听者(同 Android
/// `setOnSaiTokenListener`):后打开的会话页覆盖先前的绑定,旧 ViewModel
/// 的闭包因 `[weak self]` 自动失效,故无需(也不能)在 deinit 里清空——
/// deinit 时机晚于新页 init 时会误清别人的绑定。
public protocol StreamingAiObserving: AnyObject {
    var onSaiToken: ((_ streamId: String, _ delta: String, _ done: Bool, _ target: String) -> Void)? { get set }
    var activeStream: StreamingState? { get }
    func clearActiveStream()
}

extension MessagingService: StreamingAiObserving {}
```

- [ ] **Step 4: 写实现 — ChatMessageRow 新 case**

`Sources/IMKit/ChatMessageRow.swift`:

(a) `SystemTipRow` 定义之后(`enum ChatMessageRow` 之前)加:

```swift
/// 流式 AI(官方客服)回复的占位气泡——从未入库,仅存在于
/// `ConversationViewModel` 的内存态;`done` 后保留,等真实完整消息经
/// MN 通道入库到达时被移除(原位替换),对齐 Android `ConversationActivity`
/// 的 streamingPlaceholder。
public struct StreamingRow: Equatable, Hashable {
    public let streamId: String
    public let text: String
    public let done: Bool

    public init(streamId: String, text: String, done: Bool) {
        self.streamId = streamId
        self.text = text
        self.done = done
    }
}
```

(b) `enum ChatMessageRow` 内加 case:

```swift
    case streaming(StreamingRow)
```

(c) extension 中三个 switch(`storageId`/`timestamp`/`messageUid`)的 nil
分支各追加 `.streaming`,例如:

```swift
        case .pendingImage, .pendingVideo, .pendingVoice, .timeHeader, .streaming: return nil
```

(`timestamp` 返回 nil 是有意的:占位行永远拼在列表末尾,且不参与
`injectTimeHeaders` 的时间分组。)

- [ ] **Step 5: 写实现 — ConversationViewModel**

`Sources/IMKit/ConversationViewModel.swift` 六处修改:

(a) 存储属性:`private let activeTracking: ActiveConversationTracking?` 之后加

```swift
    private let streaming: StreamingAiObserving?
```

`private var pendingVoices: [PendingVoiceUpload] = []` 之后加

```swift
    private var streamingRow: StreamingRow?
```

(b) init 签名:`activeTracking: ActiveConversationTracking? = nil,` 之后加参数

```swift
        streaming: StreamingAiObserving? = nil,
```

init 体:`self.activeTracking = activeTracking` 之后加 `self.streaming = streaming`;
init 末尾(`cancellable = ...` 之后)加 `bindStreaming()`。

(c) 新增绑定方法(放在 `markActive()` 附近):

```swift
    /// 绑定 SAI 单监听者并恢复未完成的流(init 与 markActive 都调:
    /// 后打开的会话页会覆盖绑定,viewWillAppear 时需要抢回来)。
    private func bindStreaming() {
        guard conversationType == .single, let streaming else { return }
        streaming.onSaiToken = { [weak self] streamId, delta, done, target in
            self?.handleSaiToken(streamId: streamId, delta: delta, done: done, target: target)
        }
        if streamingRow == nil, let stream = streaming.activeStream,
           stream.target == target, !stream.done {
            streamingRow = StreamingRow(streamId: stream.streamId, text: stream.accumulatedText, done: false)
            publishRows()
        }
    }

    /// 占位行状态机,分支条件与 Android `ConversationActivity` 的
    /// `setOnSaiTokenListener` 逐条对齐;done 后保留占位行,等真实消息
    /// 入库时在 `handleMessagesUpdate` 里移除。
    private func handleSaiToken(streamId: String, delta: String, done: Bool, target tokenTarget: String) {
        guard tokenTarget == target else { return }
        if !done, delta.isEmpty, streamingRow == nil {
            streamingRow = StreamingRow(streamId: streamId, text: "", done: false)
        } else if !done, !delta.isEmpty, let row = streamingRow, row.streamId == streamId {
            streamingRow = StreamingRow(streamId: streamId, text: row.text + delta, done: false)
        } else if done, let row = streamingRow, row.streamId == streamId {
            streamingRow = StreamingRow(streamId: streamId, text: row.text, done: true)
        } else {
            return
        }
        publishRows()
    }
```

(d) `markActive()` 体内追加一行 `bindStreaming()`:

```swift
    public func markActive() {
        activeTracking?.markConversationActive(conversationType: conversationType, target: target, line: line)
        bindStreaming()
    }
```

(e) `handleMessagesUpdate(_:)`:函数开头 `lastMessages = messages` 之后加

```swift
        let previousStorageIds = Set((olderRows + liveRows).compactMap(\.storageId))
```

函数末尾 `liveRows = newLiveRows` 与 `publishRows()` 之间加:

```swift
        // 真实消息入库到达 → 移除流式占位行(Android 的"原位替换"):
        // 单聊里 target 发来的任何一条新消息都视为流的最终落库形态。
        if streamingRow != nil {
            let hasNewIncoming = newLiveRows.contains { row in
                guard case .message(let message) = row, !message.isOutgoing else { return false }
                return !previousStorageIds.contains(message.storageId)
            }
            if hasNewIncoming {
                streamingRow = nil
                streaming?.clearActiveStream()
            }
        }
```

(f) `publishRows()` 改为:

```swift
    private func publishRows() {
        rows = olderRows + liveRows + pendingImages.map { .pendingImage($0) } + pendingVideos.map { .pendingVideo($0) } + pendingVoices.map { .pendingVoice($0) } + (streamingRow.map { [ChatMessageRow.streaming($0)] } ?? [])
    }
```

- [ ] **Step 6: 跑测试确认通过**

Run: `swift test --filter ConversationViewModelStreamingTests`
Expected: PASS,`Executed 10 tests`

- [ ] **Step 7: 跑相邻回归**

Run: `swift test --filter 'ConversationViewModelTests|ConversationViewModelRemoteHistoryTests'`
Expected: 与主干基线一致(`test_recalledByOtherWithNoProfile_fallsBackToUid`/`test_loadMore_prependsOlderHistory` 两个已知 flaky 除外,不新增失败)

---

### Task 4: App — SceneDelegate 注入 + Cell 渲染 + 自动跟底

**Files:**
- Modify: `App/SceneDelegate.swift`(5 处 `ConversationViewModel(` 构造)
- Modify: `App/ConversationViewController.swift`(cell 分发、rowIdentity、applySnapshot)

**Interfaces:**
- Consumes: Task 3 的 `.streaming(StreamingRow)` case、`streaming:` init 参数;`AppEnvironment.messagingService`(已遵循 `StreamingAiObserving`)
- Produces: 无(叶子任务)

- [ ] **Step 1: SceneDelegate 注入**

`App/SceneDelegate.swift` 全部 5 处 `ConversationViewModel(` 构造中,在
`target:` 参数行之前统一加一行:

```swift
                streaming: self.environment.messagingService,
```

(群聊构造点也照加——ViewModel 内部按 `conversationType == .single` 过滤,
保持 5 处调用形态一致。)

定位方式:`grep -n "ConversationViewModel(" App/SceneDelegate.swift`,当前
在 165/211/397/515/559 行附近。

- [ ] **Step 2: ConversationViewController — cell 分发**

`configureDataSource()` 的 switch 中,`case .systemTip(let tip):` 之前加:

```swift
            case .streaming(let streamingRow):
                let cell = tableView.dequeueReusableCell(withIdentifier: TextMessageCell.reuseIdentifier, for: indexPath) as! TextMessageCell
                // 复用 TextMessageCell:拼一个未入库的合成行,流式中尾部带 ▌ 光标
                //(对齐 Android TextMessageContentViewHolder 的 displayText)。
                cell.configure(with: StoredMessageRow(
                    storageId: -1,
                    localMessageId: -1,
                    isOutgoing: false,
                    status: .unread,
                    timestamp: 0,
                    text: streamingRow.done ? streamingRow.text : streamingRow.text + "▌",
                    imageThumbnail: nil,
                    imageRemoteURL: nil
                ))
                cell.onExpandTapped = { [weak self] in
                    self?.navigationController?.pushViewController(TextPreviewViewController(text: streamingRow.text), animated: true)
                }
                cell.onLinkTapped = { url in UIApplication.shared.open(url) }
                return cell
```

- [ ] **Step 3: ConversationViewController — rowIdentity**

`rowIdentity(_:)` 的 switch 中 `case nil:` 之前加:

```swift
        case .streaming(let streamingRow): return "streaming-\(streamingRow.streamId)"
```

(delta 追加只改 text 不改 identity → `isAppend` 仅在占位行首次出现时为
true,首次出现自动滚底;后续增量走下一步的跟底逻辑。)

- [ ] **Step 4: ConversationViewController — 流式自动跟底**

`applySnapshot(rows:)` 中,`let isAppend = ...` 行之后加:

```swift
        // 流式增量:同一占位行原地长文本。用户当前在底部才继续跟底,
        // 上滑离开底部即停止(对齐 Android 的 moveToBottom 行为)。
        let isStreamingUpdate: Bool = {
            guard !isAppend, case .streaming = rows.last else { return false }
            return rows.last != oldRows.last
        }()
        let wasNearBottom = tableView.contentOffset.y + tableView.bounds.height >= tableView.contentSize.height - 80
```

`dataSource.apply(snapshot, animatingDifferences: false)` 完成闭包中,现有
`if isAppend { ... }` 之后加 else-if 分支:

```swift
            if isAppend {
                // ……现有代码不动……
            } else if isStreamingUpdate && wasNearBottom {
                self.scrollToBottom(animated: false)
            }
```

- [ ] **Step 5: 编译验证**

Run:

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: 全量单测回归**

Run: `swift test 2>&1 | tail -20`
Expected: 失败集合与主干固有基线一致(见 Global Constraints),无新增失败

- [ ] **Step 7: 装机给用户验证**

按 CLAUDE.md 真机部署流程:

```bash
xcrun devicectl list devices
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008120-001945391147401E ~/Library/Developer/Xcode/DerivedData/ios-chat-pro-*/Build/Products/Debug-iphoneos/App.app
```

然后**停下等用户在真机上验证**(给官方客服发消息,观察流式气泡/光标/
跟底/完成替换)。

- [ ] **Step 8: 用户验证通过后统一提交**

```bash
git add Sources/IMMessaging/StreamingAiHandler.swift Sources/IMMessaging/MessagingService.swift Sources/IMKit/StreamingAiObserving.swift Sources/IMKit/ChatMessageRow.swift Sources/IMKit/ConversationViewModel.swift App/SceneDelegate.swift App/ConversationViewController.swift Tests/IMMessagingTests/StreamingAiHandlerTests.swift Tests/IMMessagingTests/MessagingServiceTests.swift Tests/IMKitTests/ConversationViewModelStreamingTests.swift docs/superpowers/specs/2026-07-28-streaming-ai-message-design.md docs/superpowers/plans/2026-07-28-streaming-ai-message.md
git commit -m "feat(IMKit): 官方客服流式消息(SAI)接收展示

对齐 android-chat-pro:StreamingAiHandler 解析 PUBLISH/SAI 增量帧,
MessagingService 持有 activeStream 状态机,ConversationViewModel 用
内存态占位行流式追加,真实消息入库后原位替换;流式中尾部渲染 ▌ 光标
并自动跟底。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
