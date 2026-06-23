# Phase 3 音视频通话设计

## 概述

本设计覆盖 Phase 3 的完整闭环:一对一语音/视频通话(对应 Android `p2penginekit`/`avenginekit` 中的 `AVEngineKit`),包括呼叫发起/接听/拒绝/挂断、WebRTC 媒体连接、CallKit 系统集成、通话中界面,以及通话结束后的会话气泡记录。

复用现有 IM 消息通道(`IMMessaging`/`IMStorage`/`IMClient`)做信令传输,不修改服务端、不新增 proto 文件。新增一个 `IMCall` Swift Package 模块,并扩展 `IMMessaging`/`IMStorage`/`IMKit`/`App`。

## 1. 范围与明确排除

**本轮覆盖:**

- 一对一语音通话、一对一视频通话(同一套信令/状态机,`audioOnly` 标志区分)
- 呼叫发起/振铃/接听/拒绝/挂断/超时(60s 未应答、60s 连接中未连通)
- 通话中切换音视频模式、切换前后摄像头、静音、扬声器
- CallKit(`CXProvider`)系统级来电/通话条集成,App 在前台或刚转入后台的短时间窗口内可用
- 通话结束后在会话里生成一条"[网络电话]"系统气泡,展示时长/未接听/已取消等结果
- 与 Android 端的跨平台信令互通(复用相同的 wire content type 编号)

**明确排除(留给后续独立子项目,各自单独 brainstorm):**

- **后台/锁屏接听**:依赖 VoIP Push(PushKit)在 App 被系统挂起后唤醒,需要 `chat-server-pro` 新增 VoIP 推送通道,这超出"纯客户端迁移"范围,留给 Phase 4(与 APNs 推送一起做)。
- **群组通话**:对应 Android `AVGroupEngineKit`(mesh 拓扑,最多 9 路),架构与一对一通话是两套平行引擎,工作量独立,留作单独子项目。
- **多端同步(`AnswerTMessage`,wire type 405)**:用于"已在其他设备接听"的多端协调,本项目当前阶段不考虑多端同时登录场景,不实现。
- **ICE 自动重连**:通话中网络切换(Wi-Fi ↔ 蜂窝)导致连接失败时,按异常挂断处理,不做 ICE restart。

## 2. 信令协议(复用现有 IM 消息通道)

不新增 proto 文件、不新增 `SubSignal`。通话信令就是 5 种 `MessageContent`,通过现有的发送/接收消息管道(`IMMessaging`/`ReceiveMessageHandler`)收发,`type` 编号直接沿用 `android-chat-pro`(`cn.wildfirechat.message`)里对应类的 `@ContentTag.type`,以保证跨平台互通:

| type | 名称 | PersistFlag | 字段(映射到 `Im_MessageContent`) | 用途 |
|---|---|---|---|---|
| 400 | CallStart | **Persist** | `content`=callId;`data`=JSON `{c:connectTime, e:endTime, s:status, t:targetId, a:audioOnly}` | 呼叫发起,**持久化为会话气泡**;status:0=未接听/1=通话中/2=已结束 |
| 401 | Answer | No_Persist | `content`=callId;`data`="0"/"1"(audioOnly) | 对方接受呼叫 |
| 402 | Bye | No_Persist | `content`=callId | 挂断/拒绝/忙线自动拒绝 |
| 403 | Signal | Transparent | `content`=callId;`data`=原始字节(JSON:`{"type":"offer"/"answer","sdp":"..."}` 或 `{"type":"candidate","label":Int,"id":String,"candidate":String}`) | SDP offer/answer、ICE candidate |
| 404 | Modify | No_Persist | `content`=callId;`data`="0"/"1"(audioOnly) | 通话中切换音视频模式 |

405(AnswerT)不实现,见第 1 节。

### 对现有代码的改动

依赖方向是 `IMCall → IMMessaging`,所以 401-404 的解码逻辑不能放进 `IMMessaging`(会导致反向依赖)。两类信令分别处理:

- **400(CallStart)**:这是要落库展示成气泡的"正经"消息类型,处理方式和现有的 `groupNotification`(104-112)完全一样——`MessageContentCodec`(`Sources/IMMessaging`)新增 decode/encode 分支,`IMStorage.MessageContent` 新增一个 `.callRecord(callId:targetId:audioOnly:status:connectTime:endTime:)` case,`IMKit` 渲染气泡时直接读这个 case,不需要知道 `IMCall` 的存在。
- **401/402/403/404(Answer/Bye/Signal/Modify)**:这几个本来就不落库,`IMMessaging` 不需要理解它们的内部结构,只需要识别"这是 call 信令、不要持久化、转发出去"。`ReceiveMessageHandler.persist`(`Sources/IMMessaging/ReceiveMessageHandler.swift`)目前对解码出的每条消息一律调用 `storage.messages.insert(...)`,这是本设计**唯一一处修改 Phase 1/2 既有代码的地方**:在 `persist` 前按 `wire.content.type` 分流,401-404 直接跳过 `persist`,把原始 `Im_Message`(`IMProto` 类型,`IMMessaging`/`IMCall` 都已经依赖)透传给一个新增的闭包 `onCallSignal: ((Im_Message) -> Void)?`(与 Phase 2 给群通知用的 `onGroupNotificationMessage` 同一种模式)。`IMCall.CallSignalCodec`(在 `IMCall` 内部,直接依赖 `IMProto`)拿到这个原始 wire message 后自己解出 Answer/Bye/Signal/Modify 四种内部信令,`IMMessaging` 全程不需要认识这四个类型的字段结构。

400 仍然走原有持久化路径:被叫方收到时落库一次,主叫方在本机发送成功回调里落库一次,callId 相同但各自是本地独立的一条消息记录。

### 通话气泡的更新方式

跟 Android 一致:呼叫发起时落库一条 status=0 的本地记录,记下 `localMessageId`;本机状态机切到 `Connected` 时,本地把这条记录更新为 status=1 + `connectTime`;状态机回到 `Idle`(无论挂断/拒绝/超时)时更新为 status=2 + `endTime`。**双方各自更新自己本地那一条,不需要为同步时长再发一次网络消息**,避免双端时钟/时延不一致问题。

这需要给 `IMStorage.MessageStore`(目前只有 `updateStatus`/`updateMessageUid`)新增一个方法:

```swift
public func updateContent(localMessageId: Int64, content: MessageContent) throws
```

### 气泡文案规则

- status=0 且最终以 Bye/超时结束:主叫方显示"已取消",被叫方显示"未接听"
- status=2 且 `connectTime > 0`:显示通话时长 `mm:ss`(`endTime - connectTime`)
- 音频/视频通话用不同 icon 区分,复用现有消息气泡的图文混排能力,不新建气泡渲染类型体系

## 3. `IMCall` 模块(状态机 + WebRTC)

新建 Swift Package 模块,与 `IMGroups`/`IMContacts` 平级:

```
Sources/IMCall/
├── CallSignalCodec.swift      # Answer/Bye/Signal/Modify(401-404)的 wire 编解码,输入是 IMMessaging 透传出来的原始 Im_Message
├── CallSession.swift          # 单次通话的上下文 + 状态机
├── CallManager.swift          # 入口:管理 currentSession、ICE 配置、暴露 Combine 状态
├── WebRTCClient.swift         # 包一层 RTCPeerConnectionFactory/RTCPeerConnection
└── CallKitAdapting.swift      # protocol,由 App target 实现
```

依赖方向:`IMCall → IMMessaging → IMStorage`,`IMCall → IMProto`(wire 编解码),`IMCall` 另依赖社区维护的 WebRTC XCFramework SPM 包(如 `stasel/WebRTC`,Google 官方 `libwebrtc` 编译产物打包发行,不引入 CocoaPods、不需要本地编译 `depot_tools`/`ninja`)。

### 状态机

`CallSession.State`,字面对照 Android `AVEngineKit.CallState`:

```
Idle ──发起──▶ Outgoing ─┐
Idle ──收到CallStart──▶ Incoming ─┤
                                  ├─(Answer)──▶ Connecting ──(ICE连通)──▶ Connected
                                  └─(Bye / 超时)──▶ Idle
Connecting ──60s未连通──▶ Idle(Timeout)
Outgoing/Incoming ──60s未应答──▶ Idle(Timeout)
Connected ──Bye / ICE失败──▶ Idle
```

`CallSession` 持有 callId、对端 uid、`audioOnly`、当前 state、两个 60s 定时器(等待应答 / 等待 ICE 连通),状态变化通过 Combine `@Published` 暴露。

### WebRTC 接入(`WebRTCClient`)

职责:创建/销毁 `RTCPeerConnection`、本地音视频 track(`RTCCameraVideoCapturer` 采集,支持前后摄像头切换)、生成/设置本地 SDP、应用远端 SDP、收发 ICE candidate、提供 `RTCVideoRenderer` 挂载点给 UI 层(本地预览 + 远端渲染)。`CallManager` 收到 403(Signal)解出的 offer/answer/candidate 后调用 `WebRTCClient` 对应方法;`WebRTCClient` 产生本地 SDP/candidate 时,`CallManager` 包成 403 发出去。

### ICE/TURN 配置

直接复用 Android 现网在用的 TURN 地址,写进 `AppCore/AppConfig.swift`(与现有 `imHosts`/`imPort` 同级):

```
turn:turn.fsharechat.cn:3478
turn:sh-turn.fsharechat.cn:3478
用户名/密码:comsince/comsince
```

`chat-server-pro` 不参与 ICE 服务器分发,这里不需要任何服务端改动。

### CallKit 集成(`CallKitAdapting`)

`CXProvider`/`CXProviderDelegate`/`CXCallController` 的初始化放在 **App target**(CallKit 要求尽早在 App 生命周期里注册),`IMCall` 本身不依赖 CallKit、只依赖一个协议,方便单测:

```swift
public protocol CallKitAdapting: AnyObject {
    func reportIncomingCall(callId: String, callerName: String, audioOnly: Bool)
    func reportOutgoingCallConnecting(callId: String)
    func reportOutgoingCallConnected(callId: String)
    func reportCallEnded(callId: String, reason: CallEndReason)
}
```

- 收到 400(CallStart)、状态切到 `Incoming` → `CallManager` 调 `adapter.reportIncomingCall(...)`,`App` 层据此调 `CXProvider.reportNewIncomingCall`,系统弹出来电界面。
- 用户在系统来电界面接听/挂断 → `CXProviderDelegate` 的 `CXAnswerCallAction`/`CXEndCallAction` 回调进 `CallManager`,驱动状态机走 Answer/Bye。
- 状态切到 `Connected`/`Idle` → 对应调用 `reportOutgoingCallConnected`/`reportCallEnded`,保持系统通话条、控制中心音频路由按钮正确。
- 麦克风静音/扬声器走 `AVAudioSession`(CallKit 自动接管 category/激活时机),`WebRTCClient` 只需把本地音频 track 的 `isEnabled` 跟静音按钮状态同步。

## 4. `IMKit` UI 层

三个界面状态,复用现有深色/日间双主题 token:

1. **拨号中**(`Outgoing`):头像 + 昵称 + "正在呼叫…" + 单个挂断按钮。
2. **来电**:交给 CallKit 系统 UI 接管,App 内不另画来电卡片——前台收到来电直接 `reportNewIncomingCall`,用户从系统 UI 接听后直接进入第 3 步。
3. **通话中**(`Connecting`/`Connected`):远端视频全屏(纯语音通话时这块换成对方头像+昵称居中+计时文字,不留黑屏);右上角可拖动小窗显示本端预览(仅视频通话出现,不做吸边/吸角动画);底部悬浮半透明控制栏:静音、挂断(红色)、扬声器,视频通话额外加"切换摄像头"按钮。

```swift
public final class IncomingCallViewController: UIViewController {
    public init(callManager: CallManager)
}

public final class InCallViewController: UIViewController {
    public init(callManager: CallManager)
    // 绑定 callManager.currentSession.$state 驱动文案/按钮;
    // 挂载 callManager.localRenderer/remoteRenderer 到对应的 RTCMTLVideoView
}
```

UI 层只通过 `CallManager` 暴露的接口驱动,不直接接触 WebRTC API:`answer()`/`reject()`/`hangUp()`/`toggleMute()`/`toggleSpeaker()`/`switchCamera()`/`setAudioOnly(_:)`(对应 404 Modify)。

## 5. 边界情况

各给一条简单规则,不做穷举式防御:

| 场景 | 处理 |
|---|---|
| 本机已在通话中,又收到一条新 CallStart | 自动回 402(Bye),不弹来电、不进 CallKit |
| 双方同时互相拨打同一个人(glare) | 按 uid 字符串比较:更小的一方呼叫继续,更大的一方撤销自己发出的 Outgoing,转为接听对方的 Incoming |
| 60s 未应答 / Connecting 60s 未连通 | 状态机自动转 `Idle`,本地挂断,气泡按第 2 节文案规则展示"未接听"/"已取消" |
| 麦克风/摄像头权限被拒绝 | 发起呼叫前检查 `AVAudioSession`/`AVCaptureDevice` 权限,未授权直接提示系统设置入口,不进入拨号状态 |
| 通话建立后 ICE 连接失败或长时间 disconnected | 视为异常结束,本地挂断、发 402,气泡按已结束 + 实际 `connectTime`/`endTime` 展示 |
| 对端不在前台(没在用 App) | 已知限制——消息能送达但对方收不到来电提醒,呼叫方 60s 后超时,与"仅前台接通"的范围一致,不是 bug |

## 6. 测试策略

- `IMCall` 纯逻辑单测:状态机各状态转换路径、`CallSignalCodec` 编解码往返、忙线自动拒绝、glare 规则、60s 超时定时器(用可注入的 clock/scheduler,不真等 60 秒)
- `IMStorage`:新增的 `updateContent(localMessageId:content:)` 写单测
- `IMMessaging`:`ReceiveMessageHandler` 分流逻辑断言(400 落库、401-404 不落库且转发给信令消费者)
- `WebRTCClient`/CallKit 依赖真实硬件、麦克风摄像头、系统 UI,不强制自动化覆盖,走人工走查
- **验收标准**:先双 iOS 真机互通(语音+视频双向,接听/拒绝/挂断/未接听超时、通话气泡时长准确),再人工验证与 Android 端的信令互通(确认 SDP/ICE JSON 格式、400-404 字段在两端能互相解析)。测试账号复用 Phase 1 的 `13800000000`/`13800000001`(验证码 `556677`)。

## 已知风险与待实现阶段核实事项

1. **WebRTC XCFramework SPM 包的版本/更新节奏**——社区维护(非 Google 官方发行),需要在实现阶段确认所选包当前版本对应的 `libwebrtc` 分支稳定可用,后续升级节奏依赖社区维护频率。
2. **CallKit 在"仅前台接通"场景下的实际表现**——`reportNewIncomingCall` 在 App 已经前台时是否每次都弹出系统全屏来电 UI、还是有时只是顶部 banner,需要在实现阶段用真机实测确认,可能要做一点细节调整(但不影响本设计的整体边界划分)。
3. **`updateContent` 的并发安全**——`CallSession` 在状态机回调线程更新本地气泡内容,需要确认与 `IMClient` 现有"调用方必须用单一队列(main)驱动"的约定(见 Phase 1 设计文档 §11.6)保持一致,不引入跨队列写 GRDB 的竞争。
4. **与 Android 端的字段级互通**——本文档的 400-404 字段映射基于读 Android 源码推导,实现阶段仍需要用真实抓包/双端互发的字节做交叉验证(参照 Phase 1 Plan B 对 AES 握手的验证方式),不能只凭这里的推断编码上线。
