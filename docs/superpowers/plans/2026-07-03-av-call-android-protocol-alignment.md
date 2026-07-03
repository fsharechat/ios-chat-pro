# 音视频通话对齐 Android 协议 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 android-chat-pro `p2penginekit/AVEngineKit` 的生产协议重构 iOS 音视频通话,修复"无法接通、来电不弹窗、本地无画面"三个致命问题。

**Architecture:** 信令方向反转(offer 由被叫发)→ `CallManager` 状态机重排;`WebRTCClient` 拆"预览/连接"两阶段并内置 pending-renderer 挂载;移除 CallKit,改应用内全屏来电页 + 铃声。依据规格:`docs/superpowers/specs/2026-07-03-av-call-android-protocol-alignment-design.md`。

**Tech Stack:** Swift Package(IMCore)、stasel/WebRTC 149.0.0(exact pinned)、GRDB、UIKit、XcodeGen。

## Global Constraints

- 所有回复与代码注释使用中文(CLAUDE.md 语言约定;既有英文注释文件维持原语言风格亦可)。
- 不手工编辑 `.xcodeproj`;改 `project.yml` 或增删 App 目录文件后必须运行 `bash Scripts/generate-xcodeproj.sh`。
- 线程契约:无内部锁,一切从主队列调用;WebRTC 回调线程必须派发回主队列再触达 `CallManager`。
- 依赖方向严格单向:`IMCall` 不得依赖 `AppCore`/`App`。
- 本机 `swift test` 前置:stasel/WebRTC macOS 切片缺子头文件,需按记忆 `swift-test-env-quirks` 补齐(从 `.build/artifacts/*/WebRTC/WebRTC.xcframework/ios-arm64/.../Headers/` rsync 到 macos 切片,另建空 `RTCMTLNSVideoView.h`);主干有固有失败基线(`MessageContentCodecTests` 的 600 型期望、`MediaUploadServiceTests`、个别 flaky),对比前先取基线,勿误判回归。
- 删除文件(`CallKitProvider.swift`、`CallKitAdapting.swift`、`FakeCallKitAdapter.swift`)已获用户在设计评审中明确批准(规格 §5"移除 CallKit")。
- 编译 App:`xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`。
- 不驱动模拟器做 UI 验证(用户自行真机联调)。

## Android 参考协议速查(实现时随时对照)

- 类型:`400 CallStart(落库)`、`401 Answer`、`402 Bye`、`403 Signal(JSON: offer/answer/candidate/remove-candidates)`、`404 Modify`、`405 AnswerT(透传,多端同步,payload 同 401)`。
- 主叫:发 400 → Outgoing → 只开本地预览;收 401 → Connecting → 建 PC(非 initiator)等 offer。
- 被叫:收 400(90s 内新鲜)→ Incoming 弹窗响铃;接听 → 发 405+401 → Connecting → 建 PC(initiator)→ createOffer 发 403。
- Signal 仅在 Connecting/Connected 且 callId+sender 匹配时处理;不匹配回 402;忙线对新 400 回 402;自己账号其他端的 Answer → 本端 Incoming 静默结束(AcceptByOtherClient),不发 Bye。
- 双超时均 60s;ICE connected → Connected;ICE disconnected → MediaError 挂断。

---

### Task 1: CallSignalCodec — 405 AnswerT 编码、405/remove-candidates 解码

**Files:**
- Modify: `Sources/IMCall/CallSignalCodec.swift`
- Modify: `Sources/IMCall/CallManager.swift`(仅新增 case 的最小编译适配,语义重构在 Task 3)
- Test: `Tests/IMCallTests/CallSignalCodecTests.swift`

**Interfaces:**
- Produces(Task 3 依赖):
  - `public struct RemoteIceCandidate: Equatable { public var sdpMLineIndex: Int32; public var sdpMid: String; public var candidate: String; public init(sdpMLineIndex: Int32, sdpMid: String, candidate: String) }`
  - `IncomingCallSignal` 新增 `case removeCandidates(callId: String, candidates: [RemoteIceCandidate])`;`decode` 对 type 405 返回 `.answer(...)`(与 401 同构)。
  - `OutgoingCallSignal` 新增 `case answerT(callId: String, audioOnly: Bool)` → encode 为 `(405, callId, "0"/"1")`。

- [ ] **Step 1: 写失败测试** — 在 `Tests/IMCallTests/CallSignalCodecTests.swift` 追加:

```swift
    func test_encode_answerT_producesType405WithAudioOnlyFlag() {
        let encoded = CallSignalCodec.encode(.answerT(callId: "call-1", audioOnly: true))
        XCTAssertEqual(encoded.wireType, 405)
        XCTAssertEqual(encoded.callId, "call-1")
        XCTAssertEqual(encoded.data, Data("1".utf8))
    }

    func test_decode_type405_decodesAsAnswer() {
        var wire = Im_Message()
        wire.content.type = 405
        wire.content.searchableContent = "call-1"
        wire.content.data = Data("0".utf8)
        XCTAssertEqual(CallSignalCodec.decode(wire), .answer(callId: "call-1", audioOnly: false))
    }

    func test_decode_removeCandidates_parsesCandidateList() {
        let json = #"{"type":"remove-candidates","candidates":[{"label":0,"id":"audio","candidate":"candidate:1"},{"label":1,"id":"video","candidate":"candidate:2"}]}"#
        var wire = Im_Message()
        wire.content.type = 403
        wire.content.searchableContent = "call-1"
        wire.content.data = Data(json.utf8)
        XCTAssertEqual(CallSignalCodec.decode(wire), .removeCandidates(callId: "call-1", candidates: [
            RemoteIceCandidate(sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1"),
            RemoteIceCandidate(sdpMLineIndex: 1, sdpMid: "video", candidate: "candidate:2"),
        ]))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMCallTests/CallSignalCodecTests 2>&1 | tail -5`
Expected: 编译失败(`answerT`/`removeCandidates`/`RemoteIceCandidate` 未定义)。

- [ ] **Step 3: 实现** — `Sources/IMCall/CallSignalCodec.swift`:

在文件顶部(`IncomingCallSignal` 之前)加:

```swift
/// 一条远端 ICE 候选的三元组 — Android Signal JSON 的 {label,id,candidate}。
/// 被 `IncomingCallSignal.removeCandidates` 与 `MediaEngine.removeRemoteCandidates` 共用。
public struct RemoteIceCandidate: Equatable {
    public var sdpMLineIndex: Int32
    public var sdpMid: String
    public var candidate: String

    public init(sdpMLineIndex: Int32, sdpMid: String, candidate: String) {
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
        self.candidate = candidate
    }
}
```

`IncomingCallSignal` 加 case:

```swift
    case removeCandidates(callId: String, candidates: [RemoteIceCandidate])
```

`OutgoingCallSignal` 加 case:

```swift
    /// 405 AnswerT — Android 端接听时先于 401 发送的透传消息,服务器把它
    /// 同步给接听者自己的其他设备(多端"已被他端接听"信号);payload 与 401 相同。
    case answerT(callId: String, audioOnly: Bool)
```

`decode` 的 switch 加:

```swift
        case 405:
            // AnswerT 与 Answer 同构 —— Android 引擎里 AnswerTMessage 继承
            // AnswerMessage,接收侧按同一分支处理(多端接听同步就靠它)。
            return .answer(callId: callId, audioOnly: audioOnlyFlag(from: data))
```

`encode` 的 switch 加:

```swift
        case .answerT(let callId, let audioOnly):
            return (405, callId, Data((audioOnly ? "1" : "0").utf8))
```

`decodeSignal` 的 switch 加(在 `default` 前):

```swift
        case "remove-candidates":
            guard let parsed = try? JSONDecoder().decode(RemoveCandidatesWireSignal.self, from: data) else { return nil }
            return .removeCandidates(callId: callId, candidates: parsed.candidates.map {
                RemoteIceCandidate(sdpMLineIndex: $0.label, sdpMid: $0.id, candidate: $0.candidate)
            })
```

私有结构区加:

```swift
    private struct RemoveCandidatesWireSignal: Codable { let type: String; let candidates: [CandidateEntry] }
    private struct CandidateEntry: Codable { let label: Int32; let id: String; let candidate: String }
```

- [ ] **Step 4: CallManager 最小编译适配**(语义重构在 Task 3,这里只让新 case 可编译)— `Sources/IMCall/CallManager.swift`:

`matchesCurrentCall` 的 case 行加上 `.removeCandidates`:

```swift
        case .answer(let callId, _), .bye(let callId), .sdpOffer(let callId, _), .sdpAnswer(let callId, _), .iceCandidate(let callId, _, _, _), .removeCandidates(let callId, _), .modify(let callId, _):
            return callId == session.callId
```

`handleIncomingSignal` 的 switch 加(在 `.modify` 分支前):

```swift
        case .removeCandidates:
            break // Task 3 接到 MediaEngine.removeRemoteCandidates
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter IMCallTests/CallSignalCodecTests 2>&1 | tail -5`
Expected: 新增 3 个用例 PASS,原有用例不回归。

- [ ] **Step 6: Commit**

```bash
git add Sources/IMCall/CallSignalCodec.swift Sources/IMCall/CallManager.swift Tests/IMCallTests/CallSignalCodecTests.swift
git commit -m "feat(IMCall): 信令编解码补齐 405 AnswerT 与 remove-candidates"
```

---

### Task 2: IMMessaging — 405 进转发列表 + onCallSignal 移出写事务(修 GRDB 重入崩溃)

背景:`ReceiveMessageHandler.persist` 里 `onCallSignal?(wireMessage)` 在 `storage.write` 事务**内部**触发。`CallManager` 收到 Bye 等信令会同步写库(更新通话气泡),GRDB 串行队列不可重入 → fatalError。这就是记忆中"IMCallTests 在 macOS 上 GRDB 重入崩溃"的根因,与 `onCallStartMessage` 已修过的问题同类。

**Files:**
- Modify: `Sources/IMMessaging/ReceiveMessageHandler.swift`
- Modify: `Sources/IMMessaging/MessagingService.swift`(`persistHistory` 的过滤列表 + `sendCallControlMessage` 注释)
- Test: `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift`

**Interfaces:**
- Consumes: 无(独立于 Task 1)。
- Produces: `onCallSignal` 现在(a)对 401/402/403/404/**405** 都触发,(b)保证在写事务提交后触发 —— Task 3 的 `CallManager` 依赖 (b) 才能在回调里安全写库。

- [ ] **Step 1: 写失败测试** — `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift`:

把 `test_handle_byeSignalMessageSignalModify_allSkipPersistence` 的循环 `for wireType: Int32 in [401, 402, 403, 404]` 改为 `[401, 402, 403, 404, 405]`,并追加:

```swift
    func test_handle_answerTSignal405_firesOnCallSignal() throws {
        var capturedType: Int32?
        handler.onCallSignal = { capturedType = $0.content.type }

        var message = Im_Message()
        message.messageID = 504
        message.fromUser = "me" // 自己其他端的 AnswerT 经服务器同步回来
        message.conversation.type = 0
        message.conversation.target = "them"
        message.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 405
        wireContent.searchableContent = "call-1"
        wireContent.data = Data("0".utf8)
        message.content = wireContent
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 504)

        handler.handle(frame: frame)

        XCTAssertNil(try storage.messages.message(uid: 504)) // 透传,不落库
        XCTAssertEqual(capturedType, 405)
    }

    func test_onCallSignal_firesAfterTheWriteTransactionCompletes() throws {
        var insertedDuringCallback: StoredMessage?
        handler.onCallSignal = { [storage] _ in
            // 模拟 CallManager 在信令回调里同步写库(如收到 Bye 更新通话气泡)。
            // 若回调仍在 ReceiveMessageHandler 的 write 事务内,GRDB 会因串行
            // 队列重入直接 fatalError(测试进程崩溃即失败)。
            insertedDuringCallback = try? storage!.messages.insert(StoredMessage(
                localMessageId: 9_001,
                conversationType: .single,
                target: "them",
                from: "me",
                content: .text("written-from-callback"),
                timestamp: 1,
                status: .sending,
                direction: .send
            ))
        }

        var message = Im_Message()
        message.messageID = 505
        message.fromUser = "them"
        message.conversation.type = 0
        message.conversation.target = "them"
        message.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 402 // Bye
        wireContent.searchableContent = "call-1"
        message.content = wireContent
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 505)

        handler.handle(frame: frame)

        XCTAssertNotNil(insertedDuringCallback)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMMessagingTests/ReceiveMessageHandlerTests 2>&1 | tail -8`
Expected: 405 用例 FAIL(未转发);事务用例导致进程 crash(GRDB 重入 fatalError)—— crash 也算红。

- [ ] **Step 3: 实现** — `Sources/IMMessaging/ReceiveMessageHandler.swift`:

`handle(frame:)` 中,`var callStartMessages: [StoredMessage] = []` 后加一行:

```swift
        var callSignalMessages: [Im_Message] = []
```

`persist` 调用处传入:

```swift
                persist(wireMessage, db: db, suppressUnread: shouldSuppressUnread, groupNotificationTargets: &groupNotificationTargets, callStartMessages: &callStartMessages, callSignalMessages: &callSignalMessages)
```

写事务后的回调区,`onCallStartMessage` 循环**之后**加(同一批里 CallStart 必须先于其 Bye/Answer 被处理):

```swift
        for wireMessage in callSignalMessages {
            onCallSignal?(wireMessage)
        }
```

`persist` 签名加 `callSignalMessages: inout [Im_Message]`,并把:

```swift
        if [401, 402, 403, 404].contains(wireMessage.content.type) {
            onCallSignal?(wireMessage)
            return
        }
```

改为:

```swift
        if [401, 402, 403, 404, 405].contains(wireMessage.content.type) {
            // 不能在这里(写事务内)直接回调 —— CallManager 的信令处理会同步
            // 写库(更新通话气泡),GRDB 串行队列不可重入;与 callStartMessages
            // 相同的"事务后再发"模式。
            callSignalMessages.append(wireMessage)
            return
        }
```

同步更新该方法上方 doc comment 中的"401/402/403/404"为"401-405"。

- [ ] **Step 4: MessagingService 同步两处** — `Sources/IMMessaging/MessagingService.swift`:

`persistHistory` 中 `if [401, 402, 403, 404].contains(...)` → `[401, 402, 403, 404, 405]`;`sendCallControlMessage` doc comment 的"401/402/403/404"改为"401/402/403/404/405"(方法体无需改,`wireType` 本就是参数)。`onCallSignal` 计算属性的 doc comment(第 55 行附近)同步提及 405。

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter IMMessagingTests/ReceiveMessageHandlerTests 2>&1 | tail -5`
Expected: 全部 PASS,无 crash。

- [ ] **Step 6: Commit**

```bash
git add Sources/IMMessaging/ReceiveMessageHandler.swift Sources/IMMessaging/MessagingService.swift Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift
git commit -m "fix(IMMessaging): 通话信令转发含 405,且移出 GRDB 写事务防重入崩溃"
```

---

### Task 3: IMCall 核心重构 — MediaEngine 两阶段协议、CallManager 状态机、WebRTCClient、移除 CallKit 协议

模块内类型互相咬合(协议改动同时波及 CallManager/WebRTCClient/Fake/测试),必须一个任务内完成:先重写测试(红),再逐文件实现(绿)。

**Files:**
- Modify: `Sources/IMCall/MediaEngine.swift`(协议重写)
- Modify: `Sources/IMCall/CallManager.swift`(全量重写)
- Modify: `Sources/IMCall/CallSession.swift`(`CallEndReason` 加 `.acceptedElsewhere`)
- Modify: `Sources/IMCall/WebRTCClient.swift`(两阶段 + pending renderer + 主队列派发)
- Delete: `Sources/IMCall/CallKitAdapting.swift`
- Delete: `Tests/IMCallTests/Support/FakeCallKitAdapter.swift`
- Modify: `Tests/IMCallTests/Support/FakeMediaEngine.swift`(全量重写)
- Modify: `Tests/IMCallTests/CallManagerTests.swift`(全量重写)

**Interfaces:**
- Consumes: Task 1 的 `RemoteIceCandidate`/`.answerT`/`.removeCandidates`;Task 2 的事务外 `onCallSignal`。
- Produces(Task 4/5 依赖):
  - `CallManager`:`startCall(to:audioOnly:) throws`、`answer() throws`、`reject() throws`、`hangUp() throws`、`setAudioOnly(_:) throws`、`@Published state/audioOnly`、`peerUid`、`onCallEnded`。**不再有** `onIncomingCall`、`callKitAdapter`。
  - `CallEndReason` 增加 `case acceptedElsewhere`。
  - `WebRTCClient`:`attachLocalRenderer(_:)`/`attachRemoteRenderer(_:)` 变为"立即挂或等 track 出现后自动挂";`setMuted(_:)`/`switchCamera()` 不变。

- [ ] **Step 1: 重写 `Tests/IMCallTests/Support/FakeMediaEngine.swift`**(整文件替换):

```swift
import Foundation
@testable import IMCall

final class FakeMediaEngine: MediaEngine {
    var onLocalCandidate: ((Int32, String, String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private(set) var startPreviewCalls: [Bool] = []
    private(set) var connectCallCount = 0
    private(set) var createOfferCallCount = 0
    private(set) var createAnswerCalls: [String] = []
    private(set) var remoteAnswers: [String] = []
    private(set) var remoteCandidates: [(Int32, String, String)] = []
    private(set) var removedCandidateBatches: [[RemoteIceCandidate]] = []
    private(set) var audioOnlyCalls: [Bool] = []
    private(set) var closeCallCount = 0

    var offerSDPToReturn = "fake-offer-sdp"
    var answerSDPToReturn = "fake-answer-sdp"

    func startPreview(audioOnly: Bool) {
        startPreviewCalls.append(audioOnly)
    }

    func connect() {
        connectCallCount += 1
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

    func removeRemoteCandidates(_ candidates: [RemoteIceCandidate]) {
        removedCandidateBatches.append(candidates)
    }

    func setAudioOnly(_ audioOnly: Bool) {
        audioOnlyCalls.append(audioOnly)
    }

    func close() {
        closeCallCount += 1
    }

    func simulateConnected() { onConnected?() }
    func simulateDisconnected() { onDisconnected?() }
    func simulateLocalCandidate(sdpMLineIndex: Int32 = 0, sdpMid: String = "audio", candidate: String = "candidate:1...") {
        onLocalCandidate?(sdpMLineIndex, sdpMid, candidate)
    }
}
```

- [ ] **Step 2: 删除 `Tests/IMCallTests/Support/FakeCallKitAdapter.swift`**

```bash
git rm Tests/IMCallTests/Support/FakeCallKitAdapter.swift
```

- [ ] **Step 3: 重写 `Tests/IMCallTests/CallManagerTests.swift`**(整文件替换):

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
    /// 注入给 CallManager 的"当前时间"(毫秒)。deliverCallStart 默认
    /// serverTimestamp=99_000,距 now 1 秒 → 新鲜;新鲜度用例单独调大 now。
    private var now: Int64 = 100_000

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
        manager = makeManager()
    }

    private func makeManager(myUserId: String = "me") -> CallManager {
        CallManager(
            messagingService: messagingService,
            storage: storage,
            mediaEngine: mediaEngine,
            scheduler: scheduler,
            myUserId: { myUserId },
            nowMillis: { [unowned self] in self.now }
        )
    }

    // MARK: - 主叫

    func test_startCall_transitionsToOutgoingAndSendsCallStart() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertEqual(manager.state, .outgoing)
        XCTAssertEqual(manager.peerUid, "them")
        let messages = try sentWireMessages()
        XCTAssertEqual(messages.first?.content.type, 400)
    }

    func test_startCall_onlyStartsPreview_noConnectionNoOffer() throws {
        // Android 协议:offer 由被叫在接听后发起,主叫此时只开本地预览。
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertEqual(mediaEngine.startPreviewCalls, [false])
        XCTAssertEqual(mediaEngine.connectCallCount, 0)
        XCTAssertEqual(mediaEngine.createOfferCallCount, 0)
        XCTAssertFalse(try sentWireMessages().contains { $0.content.type == 403 })
    }

    func test_startCall_whenNotIdle_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let countBefore = try sentWireMessages().count

        try manager.startCall(to: "someone-else", audioOnly: false)

        XCTAssertEqual(manager.peerUid, "them") // 不变
        XCTAssertEqual(try sentWireMessages().count, countBefore)
    }

    func test_receivingAnswer_transitionsToConnecting_andConnectsAsNonInitiator() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")

        XCTAssertEqual(manager.state, .connecting)
        XCTAssertEqual(mediaEngine.connectCallCount, 1)
        XCTAssertEqual(mediaEngine.createOfferCallCount, 0) // 主叫等对方 offer
    }

    func test_receivingAnswerWithAudioOnly_downgradesVideoCallToAudio() throws {
        // Android answerCall 可以把视频来电按语音接听 —— 主叫侧要跟着降级。
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: true), from: "them")

        XCTAssertEqual(manager.audioOnly, true)
        XCTAssertEqual(mediaEngine.audioOnlyCalls, [true])
    }

    func test_callerReceivingOfferWhileConnecting_createsAndSendsAnswerSDP() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")

        try deliverSignal(.sdpOffer(callId: callId, sdp: "their-offer"), from: "them")

        XCTAssertEqual(mediaEngine.createAnswerCalls, ["their-offer"])
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .sdpAnswer(callId: callId, sdp: mediaEngine.answerSDPToReturn) })
    }

    func test_offerArrivingWhileStillOutgoing_isIgnored() throws {
        // 新协议下 offer 不会先于 Answer 到达;若出现(旧版本 iOS 对端),丢弃。
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.sdpOffer(callId: callIdFromLastCallStart(), sdp: "early-offer"), from: "them")

        XCTAssertTrue(mediaEngine.createAnswerCalls.isEmpty)
    }

    // MARK: - 接通/挂断

    func test_mediaEngineConnected_transitionsToConnectedAndUpdatesBubble() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")

        mediaEngine.simulateConnected()

        XCTAssertEqual(manager.state, .connected)
        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, let connectTime, _) = bubble?.content {
            XCTAssertEqual(status, 1)
            XCTAssertEqual(connectTime, now)
        } else {
            XCTFail("通话气泡应仍是 callRecord")
        }
    }

    func test_hangUp_sendsByeAndReturnsToIdle() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()

        try manager.hangUp()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.peerUid)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: callId) })
        XCTAssertEqual(mediaEngine.closeCallCount, 1)
    }

    func test_hangUp_updatesBubbleToEndedStatus() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        try manager.hangUp()

        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, let connectTime, let endTime) = bubble?.content {
            XCTAssertEqual(status, 2)
            XCTAssertEqual(connectTime, now) // 接通时间不能被挂断时丢掉
            XCTAssertEqual(endTime, now)
        } else {
            XCTFail("通话气泡应仍是 callRecord")
        }
    }

    func test_hangUp_whenIdle_isANoOp() throws {
        XCTAssertNoThrow(try manager.hangUp())
        XCTAssertEqual(manager.state, .idle)
    }

    func test_receivingBye_endsCallAndUpdatesBubble() throws {
        try manager.startCall(to: "them", audioOnly: false)
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }

        try deliverSignal(.bye(callId: callIdFromLastCallStart()), from: "them")

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .remoteBye)
        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, _, _) = bubble?.content {
            XCTAssertEqual(status, 2)
        } else {
            XCTFail("通话气泡应仍是 callRecord")
        }
    }

    // MARK: - 超时

    func test_answerTimeout_60Seconds_endsCallAsTimeoutAndSendsBye() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }

        scheduler.fireNext() // 60s 应答超时

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .timeout)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: callId) })
    }

    func test_connectingTimeout_60SecondsAfterAnswer_endsCallAsTimeout() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }

        scheduler.fireNext() // 60s 连接超时(应答超时已在收到 Answer 时取消)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .timeout)
    }

    // MARK: - 信令转发到 MediaEngine

    func test_receivingSdpAnswer_whileConnecting_forwardsToMediaEngine() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()

        try deliverSignal(.sdpAnswer(callId: "call-1", sdp: "remote-answer-sdp"), from: "them")

        XCTAssertEqual(mediaEngine.remoteAnswers, ["remote-answer-sdp"])
    }

    func test_receivingIceCandidate_whileConnecting_forwardsToMediaEngine() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()

        try deliverSignal(.iceCandidate(callId: "call-1", sdpMLineIndex: 1, sdpMid: "video", candidate: "candidate:9..."), from: "them")

        XCTAssertEqual(mediaEngine.remoteCandidates.count, 1)
        XCTAssertEqual(mediaEngine.remoteCandidates.first?.1, "video")
    }

    func test_receivingIceCandidate_whileOutgoing_isIgnored() throws {
        // Android 仅在 Connecting/Connected 处理 Signal —— 对齐。
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.iceCandidate(callId: callIdFromLastCallStart(), sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1..."), from: "them")

        XCTAssertTrue(mediaEngine.remoteCandidates.isEmpty)
    }

    func test_receivingRemoveCandidates_whileConnecting_forwardsToMediaEngine() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()
        let candidates = [RemoteIceCandidate(sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1")]

        try deliverSignal(.removeCandidates(callId: "call-1", candidates: candidates), from: "them")

        XCTAssertEqual(mediaEngine.removedCandidateBatches, [candidates])
    }

    func test_mediaEngineLocalCandidate_sentAsSignal403() throws {
        try manager.startCall(to: "them", audioOnly: false)

        mediaEngine.simulateLocalCandidate()

        let signalMessages = try sentWireMessages().filter { $0.content.type == 403 }
        XCTAssertTrue(signalMessages.contains { CallSignalCodec.decode($0) == .iceCandidate(callId: callIdFromLastCallStart(), sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1...") })
    }

    func test_mediaEngineDisconnectedAfterConnected_endsCallAsMediaFailure() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        mediaEngine.simulateConnected()
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }

        mediaEngine.simulateDisconnected()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .mediaFailure)
    }

    // MARK: - 被叫

    func test_receivingCallStartWhileIdle_transitionsToIncoming() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: true, from: "them")

        XCTAssertEqual(manager.state, .incoming)
        XCTAssertEqual(manager.peerUid, "them")
        XCTAssertEqual(manager.audioOnly, true)
        XCTAssertTrue(scheduler.scheduledDelays.contains(60)) // 应答超时已启动
        XCTAssertTrue(mediaEngine.startPreviewCalls.isEmpty) // 接听前不开摄像头
    }

    func test_staleCallStart_olderThan90Seconds_doesNotRing() throws {
        // 离线期间积压的 CallStart 重新同步时只落库,不能弹一个早就结束的来电。
        try deliverCallStart(callId: "stale-call", audioOnly: false, from: "them", serverTimestamp: 5_000) // 95 秒前

        XCTAssertEqual(manager.state, .idle)
        // 气泡照常落库(由 ReceiveMessageHandler 负责,与弹不弹窗无关)
        XCTAssertFalse(try storage.messages.messages(conversationType: .single, target: "them").isEmpty)
    }

    func test_answer_sendsAnswerTAndAnswer_connectsAsInitiator_andSendsOffer() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")

        try manager.answer()

        XCTAssertEqual(manager.state, .connecting)
        XCTAssertEqual(mediaEngine.startPreviewCalls, [false])
        XCTAssertEqual(mediaEngine.connectCallCount, 1)
        XCTAssertEqual(mediaEngine.createOfferCallCount, 1) // 被叫是 initiator
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 405 }) // AnswerT 先行
        XCTAssertTrue(messages.contains { $0.content.type == 401 })
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .sdpOffer(callId: "call-incoming-1", sdp: mediaEngine.offerSDPToReturn) })
    }

    func test_answer_whenNotIncoming_isANoOp() throws {
        XCTAssertNoThrow(try manager.answer())
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(mediaEngine.startPreviewCalls.isEmpty)
    }

    func test_secondCallStartWhileBusy_autoRejectsWithBye() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()

        try deliverCallStart(callId: "call-2", audioOnly: false, from: "someone-else")

        XCTAssertEqual(manager.state, .connecting) // 原通话不受影响
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "call-2") })
    }

    // MARK: - 多端与无关信令

    func test_ownAnswerFromOtherDevice_whileIncoming_endsAsAcceptedElsewhere_withoutBye() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }
        let countBefore = try sentWireMessages().count

        try deliverSignal(.answer(callId: "call-1", audioOnly: false), from: "me")

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .acceptedElsewhere)
        XCTAssertEqual(try sentWireMessages().count, countBefore) // 没发 Bye
    }

    func test_signalForUnrelatedCallId_isRejectedWithBye() throws {
        // Android rejectOtherCall:与当前通话无关的来电信令直接回 Bye。
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")

        try deliverSignal(.answer(callId: "other-call", audioOnly: false), from: "someone-else")

        XCTAssertEqual(manager.state, .incoming) // 当前来电不受影响
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "other-call") })
    }

    // MARK: - glare(双方同时拨打)

    func test_glare_myUidSmaller_myOutgoingCallContinues_rejectsTheirs() throws {
        // "me" < "them",按字典序我赢 —— 我的去电继续,拒掉对方的。
        try manager.startCall(to: "them", audioOnly: false)

        try deliverCallStart(callId: "their-call-id", audioOnly: false, from: "them")

        XCTAssertEqual(manager.state, .outgoing)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "their-call-id") })
    }

    func test_glare_myUidLarger_abandonsMyOutgoingAndAcceptsTheirs() throws {
        // "me" > "a",我输 —— 放弃自己的去电,把对方来电转入 incoming。
        let losingManager = makeManager()
        try losingManager.startCall(to: "a", audioOnly: false)

        try deliverCallStart(callId: "their-call-id", audioOnly: true, from: "a")

        XCTAssertEqual(losingManager.state, .incoming)
        XCTAssertEqual(losingManager.peerUid, "a")
        XCTAssertGreaterThanOrEqual(mediaEngine.closeCallCount, 1) // 被弃去电的预览已撤

        let abandonedBubble = try storage.messages.messages(conversationType: .single, target: "a").last
        if case .callRecord(_, _, _, let status, let connectTime, _) = abandonedBubble?.content {
            XCTAssertEqual(status, 2) // 被弃去电的气泡已收场
            XCTAssertEqual(connectTime, 0)
        } else {
            XCTFail("被弃去电的气泡应仍是 callRecord")
        }
    }

    // MARK: - 音视频切换

    func test_setAudioOnly_whileConnected_sendsModifyAndUpdatesEngine() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        try manager.setAudioOnly(true)

        XCTAssertEqual(manager.audioOnly, true)
        XCTAssertEqual(mediaEngine.audioOnlyCalls, [true])
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .modify(callId: callId, audioOnly: true) })
    }

    func test_setAudioOnly_whileOutgoing_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertNoThrow(try manager.setAudioOnly(true))

        XCTAssertEqual(manager.audioOnly, false)
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
    }

    func test_setAudioOnly_turningVideoOn_whenCallStartedAsAudioOnly_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: true)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: true), from: "them")
        mediaEngine.simulateConnected()
        let countBefore = try sentWireMessages().count

        try manager.setAudioOnly(false)

        XCTAssertEqual(manager.audioOnly, true) // 音频通话没有可再启用的视频轨
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
        XCTAssertEqual(try sentWireMessages().count, countBefore)
    }

    func test_receivingModify_turnVideoOff_appliesLocally() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        try deliverSignal(.modify(callId: callId, audioOnly: true), from: "them")

        XCTAssertEqual(manager.audioOnly, true)
        XCTAssertEqual(mediaEngine.audioOnlyCalls, [true])
    }

    func test_receivingModify_turnVideoOn_whenCallStartedAsAudioOnly_isIgnored() throws {
        try manager.startCall(to: "them", audioOnly: true)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: true), from: "them")
        mediaEngine.simulateConnected()

        try deliverSignal(.modify(callId: callId, audioOnly: false), from: "them")

        XCTAssertEqual(manager.audioOnly, true) // 不变
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
    }

    // MARK: - Helpers

    private func sentWireMessages() throws -> [Im_Message] {
        // `try?`(而非 `try`)解码:sentFrames 里还混着 IMClient 自己发的
        // 非 Im_Message 帧(CONNECT 握手 JSON、心跳 PING),那些不是合法
        // protobuf,跳过即可,不能让整个扫描失败。
        fakeTransport.sentFrames.compactMap { data in
            FrameDecoder().feed(data).first.flatMap { try? Im_Message(serializedBytes: $0.body) }
        }
    }

    private func callIdFromLastCallStart() -> String {
        guard let message = try? sentWireMessages().first(where: { $0.content.type == 400 }),
              case .callRecord(let callId, _, _, _, _, _) = try! MessageContentCodec.decode(message.content) else {
            XCTFail("应已发送 CallStart")
            return ""
        }
        return callId
    }

    private func deliverSignal(_ signal: OutgoingCallSignal, from: String, target: String = "me") throws {
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
        wireMessage.serverTimestamp = 99_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = wireMessage.messageID
        result.head = wireMessage.messageID
        let body = Data([0x00]) + (try result.serializedData())
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body))
    }

    private func deliverCallStart(callId: String, audioOnly: Bool, from: String, target: String = "me", serverTimestamp: Int64 = 99_000) throws {
        var wireMessage = Im_Message()
        wireMessage.messageID = Int64.random(in: 1_000_000...9_999_999)
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = target
        wireMessage.conversation.line = 0
        wireMessage.content = MessageContentCodec.encode(.callRecord(callId: callId, targetId: target, audioOnly: audioOnly, status: 0, connectTime: 0, endTime: 0))
        wireMessage.serverTimestamp = serverTimestamp
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = wireMessage.messageID
        result.head = wireMessage.messageID
        let body = Data([0x00]) + (try result.serializedData())
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body))
    }
}
```

- [ ] **Step 4: 跑测试确认红**

Run: `swift test --filter IMCallTests/CallManagerTests 2>&1 | tail -5`
Expected: 编译失败(MediaEngine 协议尚未改、`acceptedElsewhere` 未定义等)。

- [ ] **Step 5: 重写 `Sources/IMCall/MediaEngine.swift`**(整文件替换):

```swift
import Foundation

/// `CallManager` 眼中的 WebRTC 实现 —— 协议化以便 `CallManagerTests` 用
/// `FakeMediaEngine` 驱动状态机而不链接真 WebRTC。生产实现是 `WebRTCClient`。
///
/// 两阶段模型(对齐 Android AVEngineKit):
/// 1. `startPreview(audioOnly:)` —— 建 capturer + 本地音/视频轨,不建
///    PeerConnection。主叫在拨出瞬间调用(本地预览立即可见),被叫在接听
///    时调用。
/// 2. `connect()` —— 建 PeerConnection 并把已有本地轨加进去。offer 的方向
///    由 CallManager 决定:被叫(initiator)在 connect 后调 `createOffer`;
///    主叫等远端 offer 走 `createAnswer`。
public protocol MediaEngine: AnyObject {
    /// 本地 ICE 候选产出 —— CallManager 包成 403 candidate 发出。
    var onLocalCandidate: ((_ sdpMLineIndex: Int32, _ sdpMid: String, _ candidate: String) -> Void)? { get set }
    /// ICE 首次连通 —— 驱动 `.connecting → .connected`。
    var onConnected: (() -> Void)? { get set }
    /// 连通后 ICE 断开且未恢复 —— CallManager 按 `.mediaFailure` 收场。
    var onDisconnected: (() -> Void)? { get set }

    func startPreview(audioOnly: Bool)
    func connect()
    func createOffer(completion: @escaping (String) -> Void)
    func createAnswer(forRemoteOffer sdp: String, completion: @escaping (String) -> Void)
    func setRemoteAnswer(_ sdp: String)
    func addRemoteCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String)
    func removeRemoteCandidates(_ candidates: [RemoteIceCandidate])
    func setAudioOnly(_ audioOnly: Bool)
    func close()
}
```

- [ ] **Step 6: `Sources/IMCall/CallSession.swift` 加结束原因**:

`CallEndReason` 中追加:

```swift
    /// 自己账号的另一台设备接听了这通来电 —— 本端静默收场,不发 Bye
    /// (对齐 Android CallEndReason.AcceptByOtherClient)。
    case acceptedElsewhere
```

- [ ] **Step 7: 删除 `Sources/IMCall/CallKitAdapting.swift`**

```bash
git rm Sources/IMCall/CallKitAdapting.swift
```

- [ ] **Step 8: 重写 `Sources/IMCall/CallManager.swift`**(整文件替换):

```swift
import Foundation
import Combine
import IMClient
// 消歧义:`Scheduler` 同时存在于 IMClient 与 Combine(@Published 引入)——
// 见 `AppCore.LoginViewModel` 同款 import 的说明。
import protocol IMClient.Scheduler
import IMProto
import IMStorage
import IMMessaging

/// 一对一通话的状态机与协调入口,协议方向与 Android `AVEngineKit` 完全一致
/// (offer 由被叫发起,见设计文档 §1 的流程图):
/// - 主叫:发 CallStart(400) → `.outgoing`,只开本地预览;收到 Answer(401)
///   → `.connecting`,建连接等对方 offer。
/// - 被叫:收到 CallStart → `.incoming`;`answer()` 发 AnswerT(405)+Answer(401)
///   → `.connecting`,建连接并主动 createOffer。
///
/// **线程契约:** 与整个代码库一致,无内部锁,必须固定从主队列驱动。
public final class CallManager {
    @Published public private(set) var state: CallState = .idle
    @Published public private(set) var audioOnly: Bool = false
    public private(set) var peerUid: String?

    /// 每次通话结束(任何原因)触发 —— UI 收掉通话页。
    public var onCallEnded: ((CallEndReason) -> Void)?

    private static let answerTimeoutSeconds: TimeInterval = 60
    private static let connectingTimeoutSeconds: TimeInterval = 60
    /// Android `AVEngineKit.onReceiveCallMessage` 的 90 秒新鲜度窗口:离线
    /// 期间积压的 CallStart 在重新同步时只落库为通话记录,不再弹窗。
    private static let callStartFreshnessMillis: Int64 = 90_000

    private let messagingService: MessagingService
    private let storage: IMStorage
    private let mediaEngine: MediaEngine
    private let scheduler: Scheduler
    private let myUserId: () -> String
    private let nowMillis: () -> Int64

    private var session: CallSession?
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
        messagingService.onCallStartMessage = { [weak self] message in self?.handleIncomingCallStart(message) }
    }

    // MARK: - 主叫

    public func startCall(to peerUid: String, audioOnly: Bool) throws {
        guard state == .idle else { return }
        let callId = UUID().uuidString

        // 先排应答超时再发 CallStart:sendCallStart 会经 MessagingService 注册
        // 自己的 5s ack 超时到同一个 scheduler,先排 60s 让它保持最老的 pending
        // 条目,ManualScheduler.fireNext() 驱动的测试依赖这一点;session 尚为
        // nil 时 timeoutFired() 是 no-op,安全。
        startAnswerTimeoutTimer()
        let stored = try messagingService.sendCallStart(targetId: peerUid, callId: callId, audioOnly: audioOnly)

        session = CallSession(callId: callId, peerUid: peerUid, audioOnly: audioOnly, localMessageRowId: stored.id)
        self.audioOnly = audioOnly
        self.peerUid = peerUid
        state = .outgoing
        // Android 协议:主叫此刻只开本地预览(摄像头画面立即可见),
        // PeerConnection 等收到 Answer 再建,offer 由被叫发起。
        mediaEngine.startPreview(audioOnly: audioOnly)
    }

    // MARK: - 被叫

    public func answer() throws {
        guard state == .incoming, let session else { return }
        answerTimeoutToken?.cancel()
        // Android answerCall 的发送顺序:AnswerT(405,透传给自己其他端)
        // 先行,Answer(401,发给对方)随后。
        try sendSignal(.answerT(callId: session.callId, audioOnly: session.audioOnly), to: session.peerUid)
        try sendSignal(.answer(callId: session.callId, audioOnly: session.audioOnly), to: session.peerUid)
        state = .connecting
        startConnectingTimeoutTimer()

        mediaEngine.startPreview(audioOnly: session.audioOnly)
        mediaEngine.connect()
        // 被叫是 WebRTC initiator(Android startMedia(true))—— offer 从这边发。
        let answeringCallId = session.callId
        mediaEngine.createOffer { [weak self] sdp in
            guard let self, let current = self.session, current.callId == answeringCallId else { return }
            try? self.sendSignal(.sdpOffer(callId: current.callId, sdp: sdp), to: current.peerUid)
        }
    }

    public func reject() throws { try hangUp(reason: .localHangup) }
    public func hangUp() throws { try hangUp(reason: .localHangup) }

    private func hangUp(reason: CallEndReason) throws {
        guard let session else { return }
        try sendSignal(.bye(callId: session.callId), to: session.peerUid)
        endSession(reason: reason)
    }

    // MARK: - 通话中切换

    /// 视频通话中关掉视频永远可行(禁用已有本地轨);重新打开仅当这通电话
    /// 本来就是视频通话(`!session.audioOnly`,该字段记录通话原始模式,不被
    /// 本方法改写)—— 音频通话升级视频需要 SDP 重协商,不在本期范围,静默
    /// no-op 而不是误发 Modify。
    public func setAudioOnly(_ audioOnly: Bool) throws {
        guard let session, state == .connecting || state == .connected else { return }
        guard audioOnly || !session.audioOnly else { return }
        try sendSignal(.modify(callId: session.callId, audioOnly: audioOnly), to: session.peerUid)
        self.audioOnly = audioOnly
        mediaEngine.setAudioOnly(audioOnly)
    }

    // MARK: - 来电信令分发(401-405 via MessagingService.onCallSignal)

    private func handleIncomingSignal(_ wireMessage: Im_Message) {
        guard let signal = CallSignalCodec.decode(wireMessage) else { return }
        guard let session else { return }
        let sender = wireMessage.fromUser

        // 自己账号的其他设备接听了(401/405 经服务器同步回来)—— 本端还在
        // 响铃就静默收场,不发 Bye(Android AcceptByOtherClient)。
        if sender == myUserId() {
            if case .answer(let callId, _) = signal, state == .incoming, callId == session.callId {
                endSession(reason: .acceptedElsewhere)
            }
            return
        }

        guard signalCallId(signal) == session.callId, sender == session.peerUid else {
            // 与当前通话无关的信令 —— 对方在别的通话里找我,回 Bye 拒掉
            // (Android rejectOtherCall);无关的 Bye 本身不用回应。
            if case .bye = signal { return }
            try? sendSignal(.bye(callId: signalCallId(signal)), to: sender)
            return
        }

        switch signal {
        case .answer(_, let peerAudioOnly):
            guard state == .outgoing else { return }
            answerTimeoutToken?.cancel()
            if peerAudioOnly, !audioOnly {
                // 被叫把视频来电按语音接听(Android answerCall 的 audioOnly
                // 降级)—— 主叫侧跟着关掉本地视频。
                audioOnly = true
                mediaEngine.setAudioOnly(true)
            }
            state = .connecting
            startConnectingTimeoutTimer()
            mediaEngine.connect() // 主叫非 initiator:等对方 offer

        case .bye:
            endSession(reason: .remoteBye)

        case .sdpOffer(let offerCallId, let sdp):
            // Android 仅在 Connecting/Connected 处理 Signal —— 早到的 offer
            //(理论上只可能来自旧协议对端)丢弃。
            guard state == .connecting || state == .connected else { return }
            mediaEngine.createAnswer(forRemoteOffer: sdp) { [weak self] answerSDP in
                guard let self, let current = self.session, current.callId == offerCallId else { return }
                try? self.sendSignal(.sdpAnswer(callId: current.callId, sdp: answerSDP), to: current.peerUid)
            }

        case .sdpAnswer(_, let sdp):
            guard state == .connecting || state == .connected else { return }
            mediaEngine.setRemoteAnswer(sdp)

        case .iceCandidate(_, let index, let mid, let candidate):
            guard state == .connecting || state == .connected else { return }
            mediaEngine.addRemoteCandidate(sdpMLineIndex: index, sdpMid: mid, candidate: candidate)

        case .removeCandidates(_, let candidates):
            guard state == .connecting || state == .connected else { return }
            mediaEngine.removeRemoteCandidates(candidates)

        case .modify(_, let newAudioOnly):
            // 与 setAudioOnly 相同的门:这台设备以纯音频开局的通话没有可
            // 再启用的视频轨,对方请求打开视频只能忽略。
            guard newAudioOnly || !session.audioOnly else { return }
            audioOnly = newAudioOnly
            mediaEngine.setAudioOnly(newAudioOnly)
        }
    }

    private func signalCallId(_ signal: IncomingCallSignal) -> String {
        switch signal {
        case .answer(let callId, _), .bye(let callId), .sdpOffer(let callId, _), .sdpAnswer(let callId, _),
             .iceCandidate(let callId, _, _, _), .removeCandidates(let callId, _), .modify(let callId, _):
            return callId
        }
    }

    // MARK: - 来电 CallStart

    private func handleIncomingCallStart(_ message: StoredMessage) {
        guard case .callRecord(let callId, _, let audioOnlyFlag, _, _, _) = message.content else { return }
        // 90 秒新鲜度窗口(Android 同款):过期的 CallStart 只作为通话记录
        // 气泡存在(ReceiveMessageHandler 已落库),绝不能事后弹铃。
        guard nowMillis() - message.timestamp < Self.callStartFreshnessMillis else { return }
        let callerUid = message.from

        if state == .outgoing, let session, session.peerUid == callerUid {
            // glare:双方同一瞬间互拨 —— uid 小的一方的去电胜出。
            if myUserId() < callerUid {
                try? sendSignal(.bye(callId: callId), to: callerUid)
                return
            } else {
                answerTimeoutToken?.cancel()
                updateCallBubble(status: 2, endTime: nowMillis())
                mediaEngine.close() // 撤掉被弃去电已开的本地预览
                acceptIncomingCall(callId: callId, callerUid: callerUid, audioOnly: audioOnlyFlag, localMessageRowId: message.id)
                return
            }
        }

        guard state == .idle else {
            try? sendSignal(.bye(callId: callId), to: callerUid) // 忙线自动拒接
            return
        }

        acceptIncomingCall(callId: callId, callerUid: callerUid, audioOnly: audioOnlyFlag, localMessageRowId: message.id)
    }

    private func acceptIncomingCall(callId: String, callerUid: String, audioOnly: Bool, localMessageRowId: Int64?) {
        session = CallSession(callId: callId, peerUid: callerUid, audioOnly: audioOnly, localMessageRowId: localMessageRowId)
        self.audioOnly = audioOnly
        peerUid = callerUid
        state = .incoming // UI(SceneDelegate)监听 $state 弹出来电页
        startAnswerTimeoutTimer()
    }

    // MARK: - MediaEngine 回调

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

    // MARK: - 计时器

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

    // MARK: - 收场

    private func endSession(reason: CallEndReason) {
        answerTimeoutToken?.cancel()
        connectingTimeoutToken?.cancel()
        updateCallBubble(status: 2, endTime: nowMillis())
        mediaEngine.close()
        session = nil
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

注意:`endSession` 里 `updateCallBubble(status: 2, ...)` 在已接通的通话上覆盖 status=1 → 2 是正确收场;`connectTime` 从 `session.connectTime` 带回,不丢。

- [ ] **Step 9: 重写 `Sources/IMCall/WebRTCClient.swift`**(整文件替换):

```swift
import AVFoundation
import CoreMedia
import WebRTC

/// 纯数据的 ICE/TURN 配置 —— 不复用 `AppCore.AppConfig.IceServer` 以避免
/// 反向依赖成环(AppCore 依赖 IMCall)。App target 在构造 `WebRTCClient`
/// 的唯一调用点做映射。
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

/// 生产版 `MediaEngine`,两阶段模型(对齐 Android AVEngineKit):
/// `startPreview` 建 capturer/本地轨(本地画面立即可渲染),`connect` 建
/// PeerConnection。单实例跨通话复用:`close()` 拆干净,下一通重建。
///
/// **渲染挂载(pending-renderer):** `attachLocalRenderer`/`attachRemoteRenderer`
/// 随时可调 —— 轨道已存在就立即挂,否则记下 renderer,等轨道出现(本地:
/// `startPreview`;远端:`didAdd rtpReceiver` 代理回调)时自动补挂。这消除
/// 了旧实现"viewDidLoad 挂载时轨道还不存在,一次挂空永不重试"的黑屏根因。
///
/// **线程:** WebRTC 的代理/completion 在其内部线程回调,这里统一派发回主
/// 队列再向外抛,维持 CallManager 的主队列契约。
public final class WebRTCClient: NSObject, MediaEngine {
    public var onLocalCandidate: ((Int32, String, String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: (() -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let iceServers: [IceServer]
    private var peerConnection: RTCPeerConnection?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var localRenderer: RTCVideoRenderer?
    private var remoteRenderer: RTCVideoRenderer?
    /// 保证 onConnected/onDisconnected 每次通话只各发一次(ICE 状态会多次抖动)。
    private var hasReportedConnected = false
    private var isUsingFrontCamera = true

    public init(iceServers: [IceServer]) {
        self.iceServers = iceServers
        super.init()
    }

    // MARK: - 渲染挂载

    public func attachLocalRenderer(_ renderer: RTCVideoRenderer) {
        localRenderer = renderer
        localVideoTrack?.add(renderer)
    }

    public func attachRemoteRenderer(_ renderer: RTCVideoRenderer) {
        remoteRenderer = renderer
        remoteVideoTrack?.add(renderer)
    }

    // MARK: - 阶段一:本地预览

    public func startPreview(audioOnly: Bool) {
        guard localAudioTrack == nil else { return } // 重入保护(如 glare 后重开)
        configureAudioSession(audioOnly: audioOnly)

        localAudioTrack = Self.factory.audioTrack(withTrackId: "audio0")

        if !audioOnly {
            let videoSource = Self.factory.videoSource()
            let capturer = RTCCameraVideoCapturer(delegate: videoSource)
            videoCapturer = capturer
            let videoTrack = Self.factory.videoTrack(with: videoSource, trackId: "video0")
            localVideoTrack = videoTrack
            if let renderer = localRenderer { videoTrack.add(renderer) } // 补挂已登记的 renderer
            startCapture(front: true)
        }
    }

    // MARK: - 阶段二:建立连接

    public func connect() {
        guard peerConnection == nil else { return }
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: [$0.urlString], username: $0.username, credential: $0.credential)
        }
        configuration.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else { return }
        connection.delegate = self
        peerConnection = connection

        if let audioTrack = localAudioTrack { connection.add(audioTrack, streamIds: ["stream0"]) }
        if let videoTrack = localVideoTrack { connection.add(videoTrack, streamIds: ["stream0"]) }
    }

    /// 没这个配置 setMuted/扬声器切换会静默失效(overrideOutputAudioPort 只
    /// 对 .playAndRecord 会话生效);.voiceChat 给 WebRTC 音频单元 VoIP 语义
    ///(回声消除、听筒/扬声器自动路由)。视频通话默认外放,对齐 Android。
    private func configureAudioSession(audioOnly: Bool) {
        // iOS-only:macOS 无 AVAudioSession,Package.swift 声明 .macOS(.v12)
        // 只为让 swift test 能构建。
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        if !audioOnly { options.insert(.defaultToSpeaker) }
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try? session.setActive(true)
        #endif
    }

    /// 默认前摄(自拍小窗);格式选最接近 720p 的(Android 端 VideoProfile
    /// 默认 VP720P),fps 封顶 30 —— 旧实现取"第一个格式"可能极低清。
    private func startCapture(front: Bool) {
        guard let capturer = videoCapturer else { return }
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }) else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let targetPixels = 1280 * 720
        guard let format = formats.min(by: { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return abs(Int(l.width) * Int(l.height) - targetPixels) < abs(Int(r.width) * Int(r.height) - targetPixels)
        }) else { return }
        let maxFps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(maxFps, 30)))
    }

    // MARK: - SDP / ICE

    public func createOffer(completion: @escaping (String) -> Void) {
        guard let connection = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection.offer(for: constraints) { sdp, _ in
            guard let sdp else { return }
            connection.setLocalDescription(sdp) { _ in
                DispatchQueue.main.async { completion(sdp.sdp) } // 回主队列,守 CallManager 契约
            }
        }
    }

    public func createAnswer(forRemoteOffer sdp: String, completion: @escaping (String) -> Void) {
        guard let connection = peerConnection else { return }
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        connection.setRemoteDescription(remoteDescription) { _ in
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            connection.answer(for: constraints) { answerSDP, _ in
                guard let answerSDP else { return }
                connection.setLocalDescription(answerSDP) { _ in
                    DispatchQueue.main.async { completion(answerSDP.sdp) }
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

    public func removeRemoteCandidates(_ candidates: [RemoteIceCandidate]) {
        let iceCandidates = candidates.map {
            RTCIceCandidate(sdp: $0.candidate, sdpMLineIndex: $0.sdpMLineIndex, sdpMid: $0.sdpMid)
        }
        peerConnection?.remove(iceCandidates)
    }

    // MARK: - 通话中控制

    public func setAudioOnly(_ audioOnly: Bool) {
        localVideoTrack?.isEnabled = !audioOnly
    }

    public func setMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    public func switchCamera() {
        isUsingFrontCamera.toggle()
        videoCapturer?.stopCapture()
        startCapture(front: isUsingFrontCamera)
    }

    // MARK: - 收场

    public func close() {
        videoCapturer?.stopCapture()
        peerConnection?.close()
        peerConnection = nil
        videoCapturer = nil
        localVideoTrack = nil
        localAudioTrack = nil
        remoteVideoTrack = nil
        localRenderer = nil
        remoteRenderer = nil
        isUsingFrontCamera = true
        // 必须复位:实例跨通话复用,留 true 会永久吞掉下一通的 onConnected。
        hasReportedConnected = false
        // .notifyOthersOnDeactivation:让被 .playAndRecord 压掉的后台音频恢复。
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        // WebRTC 内部线程 → 主队列,维持 CallManager 的主队列契约。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch newState {
            case .connected, .completed:
                guard !self.hasReportedConnected else { return }
                self.hasReportedConnected = true
                self.onConnected?()
            case .failed, .disconnected, .closed:
                // 从未连通过的失败由 CallManager 的 60s 连接超时兜底。
                guard self.hasReportedConnected else { return }
                self.onDisconnected?()
            default:
                break
            }
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let (index, mid, sdp) = (candidate.sdpMLineIndex, candidate.sdpMid ?? "", candidate.sdp)
        DispatchQueue.main.async { [weak self] in
            self?.onLocalCandidate?(index, mid, sdp)
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        // unified-plan 下远端轨道从 receiver 到达 —— 这是远端画面能渲染的关键
        //(旧实现在 viewDidLoad 时从 transceivers 找轨道,彼时协商未完成,
        // 永远挂空)。
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.remoteVideoTrack = track
            if let renderer = self.remoteRenderer { track.add(renderer) }
        }
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

- [ ] **Step 10: 跑 IMCall 全部测试确认绿**

Run: `swift test --filter IMCallTests 2>&1 | tail -8`
Expected: CallManagerTests + CallSignalCodecTests 全 PASS(Task 2 已修 GRDB 重入,历史 crash 不应复现)。若 WebRTC 头文件报错,先按 Global Constraints 的 quirks 补头文件再跑。

- [ ] **Step 11: Commit**

```bash
git add -A Sources/IMCall Tests/IMCallTests
git commit -m "feat(IMCall): 按 Android 协议重构通话状态机,offer 改由被叫发起

- 主叫 startCall 只发 CallStart+开本地预览,收 Answer 后建连接等 offer
- 被叫 answer 发 AnswerT(405)+Answer(401),作为 initiator 创建 offer
- Signal 仅在 connecting/connected 且 callId+sender 匹配时处理,无关信令回 Bye
- 新增 90s 来电新鲜度过滤、多端接听 acceptedElsewhere、remove-candidates
- WebRTCClient 拆 startPreview/connect 两阶段,pending-renderer 修双向黑屏,
  代理回调统一派发主队列
- 移除 CallKitAdapting(国行 CallKit 不可用,改纯应用内来电页)"
```

---

### Task 4: App 层 — 应用内来电页、SceneDelegate 接线、删除 CallKitProvider

**Files:**
- Modify: `App/CallViewController.swift`(加来电操作区、renderer 挂载说明)
- Modify: `App/SceneDelegate.swift`(`.incoming` 弹窗、移除 CallKit)
- Delete: `App/CallKitProvider.swift`

**Interfaces:**
- Consumes: Task 3 的 `CallManager`(无 `callKitAdapter`/`onIncomingCall`)、`WebRTCClient.attachLocalRenderer/attachRemoteRenderer`(pending 语义)、`CallPermissions.ensureAuthorized(audioOnly:completion:)`(已存在,不改)。
- Produces: `CallViewController` 全生命周期(incoming/outgoing/connecting/connected)单屏;`SceneDelegate.handleCallStateChange` 对任何非 idle 状态弹屏(Task 5 在此追加铃声一行)。

- [ ] **Step 1: 删除 `App/CallKitProvider.swift`**

```bash
git rm App/CallKitProvider.swift
```

- [ ] **Step 2: 修改 `App/CallViewController.swift`** — 具体改动(保持其余不变):

(a) 属性区:把局部 `controlBar` 提升为属性,并新增来电操作区(在 `hangUpButton` 声明之后加):

```swift
    private let controlBar = UIStackView()
    // 来电操作区:接听前只显示 拒绝/接听 两个大按钮(对齐 Android 来电页)。
    private let incomingBar = UIStackView()
    private let acceptButton = CallControlButton(systemImageName: "phone.fill", backgroundColor: .systemGreen)
    private let rejectButton = CallControlButton(systemImageName: "phone.down.fill", backgroundColor: .systemRed)
```

(b) `layoutViews()` 中,删掉原来的 `let controlBar = UIStackView(arrangedSubviews: ...)`,改为:

```swift
        [muteButton, switchCameraButton, toggleVideoButton, hangUpButton, speakerButton].forEach { controlBar.addArrangedSubview($0) }
        controlBar.axis = .horizontal
        controlBar.distribution = .equalSpacing
        controlBar.alignment = .center

        acceptButton.addTarget(self, action: #selector(acceptTapped), for: .touchUpInside)
        rejectButton.addTarget(self, action: #selector(rejectTapped), for: .touchUpInside)
        [rejectButton, acceptButton].forEach { incomingBar.addArrangedSubview($0) }
        incomingBar.axis = .horizontal
        incomingBar.distribution = .equalSpacing
        incomingBar.alignment = .center
```

`[remoteVideoView, centerStack, localVideoView, controlBar].forEach` 的数组里加入 `incomingBar`,并在约束区追加:

```swift
            incomingBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 64),
            incomingBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -64),
            incomingBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
```

(c) `applyState(_:)` 整体替换为:

```swift
    private func applyState(_ state: CallState) {
        let isIncoming = state == .incoming
        incomingBar.isHidden = !isIncoming
        controlBar.isHidden = isIncoming
        // 视频开关只在媒体已就绪、且这通电话以视频开局时才有意义。
        toggleVideoButton.isHidden = !startedAsVideo || (state != .connecting && state != .connected)
        switch state {
        case .idle:
            durationTimer?.invalidate()
        case .outgoing:
            statusLabel.text = "正在呼叫…"
        case .incoming:
            statusLabel.text = callManager.audioOnly ? "邀请你进行语音通话" : "邀请你进行视频通话"
        case .connecting:
            statusLabel.text = "连接中…"
        case .connected:
            callConnectedAt = Date()
            startDurationTimer()
        }
    }
```

(d) 动作区追加(`hangUpTapped` 旁):

```swift
    @objc private func acceptTapped() {
        // 与被移除的 CallKit 接听路径同语义:权限不足时自动拒接,而不是
        // 接进一个没声音/没画面的通话。
        CallPermissions.ensureAuthorized(audioOnly: callManager.audioOnly) { [weak self] authorized in
            guard let self else { return }
            guard authorized else {
                try? self.callManager.reject()
                return
            }
            try? self.callManager.answer()
        }
    }

    @objc private func rejectTapped() {
        try? callManager.reject()
    }
```

(e) `viewDidLoad` 中 `attachRemoteRenderer/attachLocalRenderer` 两行**保留原样**——`WebRTCClient` 的 pending-renderer 语义(Task 3)保证轨道晚到时自动补挂;将两行上方注释更新为:

```swift
        // pending-renderer:轨道尚未创建也没关系,WebRTCClient 会在轨道
        // 出现时自动补挂(本地:startPreview;远端:didAdd rtpReceiver)。
```

(f) `bindCallManager` 的 `$audioOnly` sink 里,`avatarView.isHidden = !audioOnly` 之后追加一行(音频来电时确保头像可见、视频区隐藏的既有逻辑已覆盖,无需更多)。此项确认无需改动即可,不加代码。

- [ ] **Step 3: 修改 `App/SceneDelegate.swift`**:

(a) 删除属性 `private var callKitProvider: CallKitProvider?`。

(b) `wireCallManagerIfReady()` 整体替换为:

```swift
    /// environment.callManager 为 nil(未登录)时 no-op,登录成功回调里会再
    /// 调一次;用 cancellables 里已有订阅做幂等门(callManager 重建仅发生在
    /// 重新登录,那时 SceneDelegate 也会重走这里)。
    private var callManagerWired = false

    private func wireCallManagerIfReady() {
        guard let callManager = environment.callManager, !callManagerWired else { return }
        callManagerWired = true
        callManager.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.handleCallStateChange(state) }
            .store(in: &cancellables)
    }
```

(c) `handleCallStateChange(_:)` 整体替换为:

```swift
    /// 任何非 idle 状态都保证通话页在场(incoming 弹应用内来电页 ——
    /// 国行 iPhone 无 CallKit 可用,这是唯一的来电 UI),回到 idle 收掉。
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
        // 从真正的最顶层 present —— 来电必须能打断任何已存在的模态流程,
        // 否则 UIKit 静默丢弃 presentation,通话页永远出不来。
        topmostPresentedViewController()?.present(callViewController, animated: true)
    }
```

(d) 文件内如仍有 `CallKitProvider` 相关 import/引用,一并清除(`grep -n CallKit App/SceneDelegate.swift` 应无结果)。

- [ ] **Step 4: 重新生成工程并编译**

```bash
bash Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 5: Commit**

```bash
git add -A App project.yml ios-chat-pro.xcodeproj
git commit -m "feat(App): 应用内全屏来电页替代 CallKit,任何通话状态保证通话页在场"
```

---

### Task 5: 铃声 — CallRingtonePlayer + 资源复制

**Files:**
- Create: `App/Resources/incoming_call_ring.mp3`、`App/Resources/outgoing_call_ring.mp3`(从 android-chat-pro 复制)
- Create: `App/CallRingtonePlayer.swift`
- Modify: `App/SceneDelegate.swift`(接一行)

**Interfaces:**
- Consumes: Task 4 的 `handleCallStateChange`;`IMCall.CallState`。
- Produces: `final class CallRingtonePlayer { func update(for state: CallState) }`。

- [ ] **Step 1: 复制铃声资源**

```bash
mkdir -p App/Resources
cp ../android-chat-pro/chat/src/main/res/raw/incoming_call_ring.mp3 App/Resources/
cp ../android-chat-pro/chat/src/main/res/raw/outgoing_call_ring.mp3 App/Resources/
```

- [ ] **Step 2: 新建 `App/CallRingtonePlayer.swift`**:

```swift
// App/CallRingtonePlayer.swift
import AVFoundation
import IMCall

/// 来电/去电铃声(资源复用 android-chat-pro 的 raw 音频,行为对齐:
/// incoming 循环放来电铃声、outgoing 循环放回铃音,离开这两个状态即停)。
/// 由 SceneDelegate 在 CallManager.$state 变化时驱动 —— 状态一进入
/// connecting(接听)或 idle(挂断/超时)铃声即停,不需要额外事件。
///
/// 铃声阶段 WebRTC 的 .playAndRecord 会话尚未激活(主叫 startPreview 已
/// 激活,音量走通话路由,与回铃音语义一致;被叫要到接听才激活),
/// AVAudioPlayer 直接用默认会话播放即可,无需自行改会话配置。
final class CallRingtonePlayer {
    private enum Mode { case incoming, outgoing }

    private var player: AVAudioPlayer?
    private var currentMode: Mode?

    func update(for state: CallState) {
        switch state {
        case .incoming: play(.incoming)
        case .outgoing: play(.outgoing)
        case .idle, .connecting, .connected: stop()
        }
    }

    private func play(_ mode: Mode) {
        guard currentMode != mode else { return }
        stop()
        let resourceName = mode == .incoming ? "incoming_call_ring" : "outgoing_call_ring"
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp3") else { return }
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        newPlayer.numberOfLoops = -1
        newPlayer.play()
        player = newPlayer
        currentMode = mode
    }

    private func stop() {
        player?.stop()
        player = nil
        currentMode = nil
    }
}
```

- [ ] **Step 3: SceneDelegate 接线** — `App/SceneDelegate.swift`:

属性区加:

```swift
    private let ringtonePlayer = CallRingtonePlayer()
```

`handleCallStateChange(_:)` 方法体第一行(`guard let callManager` 之前)加:

```swift
        ringtonePlayer.update(for: state)
```

- [ ] **Step 4: 重新生成工程、编译并确认资源入包**

```bash
bash Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
find ~/Library/Developer/Xcode/DerivedData -path '*App.app/incoming_call_ring.mp3' -newer App/Resources/incoming_call_ring.mp3 2>/dev/null | head -1
```

Expected: BUILD SUCCEEDED;find 输出一条 .app 内的 mp3 路径(XcodeGen 把非源码文件归入 resources phase)。若 find 为空,在 `project.yml` 的 App target 显式加 `resources: [App/Resources]` 语义的 sources 条目后重新生成再验。

- [ ] **Step 5: Commit**

```bash
git add App/CallRingtonePlayer.swift App/Resources App/SceneDelegate.swift ios-chat-pro.xcodeproj project.yml
git commit -m "feat(App): 来电/去电铃声,资源与行为对齐 Android"
```

---

### Task 6: 全量验证收尾

**Files:** 无新改动(只验证;发现问题回上游任务修)。

- [ ] **Step 1: SPM 全量测试对比基线**

```bash
swift test 2>&1 | tail -20
```

Expected: `IMCallTests`、`IMMessagingTests` 全绿;其余失败须与主干固有基线一致(`MessageContentCodecTests` 600 型期望、`MediaUploadServiceTests` URL 断言、两个已知 flaky)。任何新增失败都要在对应任务里修掉。

- [ ] **Step 2: App 编译最终确认**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 交付说明** — 向用户汇报,并列出真机联调清单(用户自行验证,不驱动模拟器):
  1. iOS → Android 拨视频:Android 弹来电页,接听后双向画面/声音。
  2. Android → iOS 拨视频:iOS 前台弹应用内来电页 + 铃声,接听后双向画面。
  3. 视频来电以语音接听(Android 端"语音接听"按钮)→ iOS 主叫自动降级。
  4. 挂断/拒接/60s 未接超时,通话气泡状态正确(未接听/通话中/已结束)。
  5. 忙线时第三方来电被自动拒接,原通话不受影响。
  6. 通话中锁屏/切后台不崩溃(前台通话为既定范围)。

## Self-Review 记录

- 规格逐节核对:§3 状态机(Task 3)、§4 两阶段+渲染(Task 3)、§5 来电页/铃声/接线(Task 4/5)、CallKit 移除(Task 3/4)、§7 测试(Task 2/3/6)——全覆盖。规格中"onLocalVideoTrackCreated/onRemoteVideoTrackAdded 回调"实现为 WebRTCClient 内置 pending-renderer(等价且更简,UI 无需订阅新事件),已在 Task 3/4 注明。
- 类型一致性:`RemoteIceCandidate`(Task 1 定义,Task 3 协议与测试使用)、`startPreview/connect/createOffer` 签名在 FakeMediaEngine/WebRTCClient/CallManager/计划内测试三处一致;`acceptedElsewhere` 在 Task 3 定义并被测试引用。
- 无占位符;每步含完整代码与命令。
