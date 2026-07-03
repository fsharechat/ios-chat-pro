# 音视频通话对齐 Android 协议 — 设计文档

日期:2026-07-03
状态:已确认(用户批准)
前置:`2026-06-23-phase3-av-call-design.md`(Phase 3 首版设计,本文档修正其信令方向等根本性错误)

## 1. 背景与问题

iOS 端(`IMCall` + App target)对照 android-chat-pro 实测存在三个致命问题:

1. **无法接通**:信令协议方向与 Android 相反。
2. **来电不弹窗**:来电界面完全依赖 CallKit 系统 UI,国行 iPhone 上 CallKit 被 Apple 禁用,`reportNewIncomingCall` 失败且错误被忽略,应用内又没有自绘来电页。
3. **拨视频看不到本地画面**:`state = .outgoing` 同步触发 present → `viewDidLoad` 里 attach renderer 时 `mediaEngine.start()` 还没执行,`localVideoTrack == nil`,挂载落空且无重挂机制;远端 track 要等 SDP 协商后才存在,同样永远挂不上。

### Android 参考实现(生产协议,以此为准)

来源:`android-chat-pro/p2penginekit/.../AVEngineKit.java`(SingleVoipCallActivity 实际使用的引擎,源码可见;`avenginekit` 目录下的 AAR 未被单聊使用)。

消息类型:`CallStart=400(Persist)`、`Answer=401(No_Persist)`、`Bye=402`、`Signal=403`(JSON:offer/answer/candidate/remove-candidates)、`Modify=404`、`AnswerT=405(Transparent,多端同步)`。

流程:

```
主叫 A                                被叫 B
startCall: 发 400, state=Outgoing
startPreview(): 开摄像头/本地track
(不建 PeerConnection、不发 offer)
                                      收到 400(90s 内新鲜、Receive 方向、单聊)
                                      → Incoming,弹全屏来电页 + 响铃
                                      用户接听:发 405 + 401
                                      → Connecting, startMedia(isInitiator=true)
                                      → createOffer → 发 403 offer
收到 401 → Connecting
setAudioOnly(answer.audioOnly)   ← 被叫可把视频来电降级为语音接听
startMedia(isInitiator=false),等 offer
收到 403 offer → setRemote → createAnswer
→ 发 403 answer                        收到 403 answer → setRemote
双向 403 candidate(仅 Connecting/Connected 状态处理)
ICE connected → Connected(双方)
```

挂断/异常:任一方发 402;忙线对新来电回 402(rejectOtherCall);收到自己账号其他端的 401 且本端 Incoming → 以 AcceptByOtherClient 结束本端(不发 Bye);Signal 的 callId/发送者不匹配当前会话 → 回 402。应答等待与连接超时均 60s。

**iOS 现状的根本错误**:`CallManager.startCall` 立即 `mediaEngine.start()` + `createOffer` 并发出 403。iOS→Android:Android 在 Incoming 态丢弃早到的 offer,接听后自己发 offer,iOS 已处于 have-local-offer,`setRemoteDescription(offer)` 失败(错误被吞)。Android→iOS:iOS 接听后等一个永远不会来的 offer(`pendingRemoteOfferSDP` 为 nil),Android 主叫也在等 offer,双方死等至 60s 超时。

## 2. 方案总览

按 Android 协议重构,共五部分:

1. `CallManager` 状态机按 Android 方向重排(offer 由被叫发)。
2. `WebRTCClient`/`MediaEngine` 拆"预览"与"连接"两阶段,新增 track 回调。
3. 应用内全屏来电页 + 来电/回铃铃声。
4. 移除 CallKit。
5. 测试重写与跨端联调。

## 3. CallManager 状态机(IMCall)

`MediaEngine` 协议改造:

```swift
public protocol MediaEngine: AnyObject {
    var onLocalCandidate: ((Int32, String, String) -> Void)? { get set }
    var onConnected: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onLocalVideoTrackCreated: (() -> Void)? { get set }   // 新增
    var onRemoteVideoTrackAdded: (() -> Void)? { get set }    // 新增

    func startPreview(audioOnly: Bool)          // 建 capturer + 本地 tracks,不建 PC
    func connect()                              // 建 PC、加入已有 tracks
    func createOffer(completion: @escaping (String) -> Void)   // 仅被叫(initiator)在 connect 后调用
    func createAnswer(forRemoteOffer: String, completion: @escaping (String) -> Void)
    func setRemoteAnswer(_ sdp: String)
    func addRemoteCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String)
    func removeRemoteCandidates(_ candidates: [(sdpMLineIndex: Int32, sdpMid: String, candidate: String)]) // 新增
    func setAudioOnly(_ audioOnly: Bool)
    func close()
}
```

`CallManager` 各路径:

- **startCall(to:audioOnly:)**:发 400(逻辑不变)→ `.outgoing` → `startPreview(audioOnly:)` → 启动 60s 应答超时。不再 createOffer。
- **收到 401(主叫侧)**:`state == .outgoing` 才处理;`audioOnly = answer.audioOnly`(降级支持,同步 `mediaEngine.setAudioOnly`)→ `.connecting` → `connect()`(不 createOffer,等对方 offer)→ 60s 连接超时。
- **answer()(被叫侧)**:`state == .incoming` 才处理;发 405(AnswerT)+ 401 → `.connecting` → `startPreview(audioOnly:)` + `connect()` + `createOffer { 发 403 offer }` → 60s 连接超时。
- **收到 403**:仅 `.connecting`/`.connected` 且 callId+fromUser 匹配当前会话才处理(offer → createAnswer 回 403 answer;answer → setRemote;candidate → add;remove-candidates → remove)。callId 不匹配的 403/401 → 回 402(rejectOtherCall 语义)。`pendingRemoteOfferSDP` 删除。
- **收到 400(来电)**:新增 90s 新鲜度过滤 —— `nowMillis() - message.timestamp > 90_000` 则忽略(消息已照常落库为气泡);忙线回 402;glare 规则保留(uid 比较);正常 → `.incoming` → `onIncomingCall` → 60s 应答超时。
- **收到 401 且 fromUser == myUserId()(多端)**:本端 `.incoming` 且 callId 匹配 → 以新增 `CallEndReason.acceptedElsewhere` 结束,不发 402。
- **收到 402 / 超时 / 挂断 / 媒体断开**:逻辑保持,`endSession` 不再调 CallKit。
- **气泡更新**(status/connectTime/endTime 写回 400 消息)逻辑保持不变。

`CallSignalCodec`:新增 403 `remove-candidates` 解码(`{type, candidates:[{label,id,candidate}]}`);新增 405 编码(与 401 同 payload:searchableContent=callId,data="0"/"1")。收到的 405 维持现状(不进 [401-404] 过滤,`MessageContentCodec.decode` 抛不支持后被丢弃,无害)。

`IMMessaging`:`ReceiveMessageHandler` 的 401-404 转发、400 落库并回调的机制不变(90s 过滤放在 CallManager,便于单测注入时钟)。`MessagingService` 需支持发送 wireType 405(现有 `sendCallControlMessage` 若写死 401-404 校验则放宽)。

## 4. WebRTCClient(IMCall)

- `startPreview(audioOnly:)`:配置 AudioSession;创建 `localAudioTrack`;非纯音频时创建 videoSource/capturer/`localVideoTrack` 并 `startCapture`(前摄),完成后触发 `onLocalVideoTrackCreated`。
- `connect()`:创建 `RTCPeerConnection`(unifiedPlan、ICE servers 不变),`add` 已有 tracks。offer 由 CallManager 视角色决定:被叫在 `connect()` 后调 `createOffer(completion:)`;主叫等远端 offer 走 `createAnswer`。
- 远端 track:`RTCPeerConnectionDelegate` 的 `didStartReceivingOn transceiver`(或 `didAdd rtpReceiver`)中发现远端视频 track → 记录 + 触发 `onRemoteVideoTrackAdded`。
- `attachLocalRenderer`/`attachRemoteRenderer` 保持,但语义变为"挂到当前已存在的 track";配合回调由 UI 在正确时机调用。
- `close()`:全部拆干净(含新回调状态),保持可复用。

## 5. App 层:来电页、铃声、接线

### CallViewController

- 支持 `.incoming` 状态:显示头像/姓名/"邀请你进行视频(语音)通话",底部换成 **拒绝(红)+ 接听(绿)** 两个大按钮;其余控制条(静音/扬声器/切换摄像头/挂断)仅 `.outgoing`/`.connecting`/`.connected` 显示。
- 接听按钮 → `CallPermissions.ensureAuthorized`(拒绝 → `callManager.reject()` + 提示)→ `callManager.answer()`。
- renderer 挂载改为事件驱动:订阅 `webRTCClient.onLocalVideoTrackCreated` / `onRemoteVideoTrackAdded`(VC 在位时立即补挂已存在的 track),替代 `viewDidLoad` 一次性挂载。
- 主叫视频通话在 `.outgoing` 阶段即可看到本地预览(startPreview 已建 track)。

### SceneDelegate

- `handleCallStateChange`:`.incoming` 也 present(原来只有 `.outgoing`/`.connecting`);去掉 CallKit 相关注释/接线。
- `wireCallManagerIfReady` 简化:不再创建 `CallKitProvider`,只订阅 `$state`。

### CallRingtonePlayer(App target,新文件)

- `AVAudioPlayer` 循环播放;`.incoming` → `incoming_call_ring.mp3`,`.outgoing` → `outgoing_call_ring.mp3`,离开这两个状态即停。
- 两个 mp3 从 `android-chat-pro/chat/src/main/res/raw/` 复制到 App 资源(project.yml 的 App sources 已含 App 目录,直接放 `App/Resources/` 或同级即可,需确认 XcodeGen 打包)。
- 播放类别:来电铃声用不打断 WebRTC 的方式 —— 在 `.incoming`/`.outgoing` 阶段 WebRTC 音频单元尚未激活(connect 之后才需要),用默认 `.playback`/ambient 即可,接通即停,避免与 `configureAudioSession()` 冲突。

### 移除 CallKit

删除 `App/CallKitProvider.swift`、`Sources/IMCall/CallKitAdapting.swift`、`CallManager.callKitAdapter` 属性及全部调用点、`FakeCallKitAdapter` 与相关断言。`CallEndReason` 保留(UI/铃声/测试仍用),新增 `.acceptedElsewhere`。

## 6. 范围外

- 群组通话(`AVGroupEngineKit`)。
- 后台/锁屏来电(需 VoIP Push + PushKit;App 目前为前台通话)。
- 语音通话中升级为视频的 SDP 重协商(维持只能降级,与现状一致;Android 的 Modify 也只在 Connected 后生效)。
- 通话浮窗(Android FloatingVoipService)。

## 7. 测试

- **CallManagerTests 重写**:
  - 主叫:startCall 只发 400 + startPreview,不建连接;收 401 → connecting + `connect(isInitiator:false)` + audioOnly 降级;收 403 offer → 回 answer。
  - 被叫:answer() 发 405+401、`connect()` + `createOffer` 发 403 offer;收 403 answer → setRemote。
  - 90s 过滤:旧 CallStart 不触发 `onIncomingCall`。
  - 多端:自己的 401 → `.acceptedElsewhere` 结束且不发 402。
  - 保留:glare、忙线回 402、60s 双超时、Bye、气泡状态写回。
- **CallSignalCodecTests**:补 remove-candidates 解码、405 编码。
- `swift test --filter IMCallTests` 全绿(注意主干有固有失败基线,勿误判)。
- 真机 iOS↔Android 联调由用户自行验证:双向拨打、接听、双向画面、语音降级接听、挂断、忙线、超时。

## 8. 决策记录

- **纯应用内来电页,移除 CallKit**(用户确认):国行 CallKit 不可用,App 又只做前台通话,保留 CallKit 只增加双 UI 去重复杂度。
- **铃声本期做**(用户确认):资源直接复用 Android 项目 mp3。
