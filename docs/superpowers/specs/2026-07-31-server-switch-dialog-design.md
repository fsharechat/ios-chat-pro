# 连接服务信息弹窗与节点切换（iOS） · 设计

日期：2026-07-31

参考实现：`android-chat-pro` 的 `docs/superpowers/specs/2026-07-30-server-switch-dialog-design.md` 与 `chat/src/main/java/cn/wildfire/chat/kit/net/`。

## 目标

点击共用顶栏的「飞享IM」标题，弹出「当前连接服务」信息弹窗，展示服务名称、连接地址、端口、连接状态与延迟；提供「切换连接地址」入口，让用户在预置集群节点之间选择并固定一个节点，或恢复自动轮询。选择持久化，深浅色模式均适配。

## 现状

- 顶栏标题在 `App/AppHeaderBar.swift:23` 的 `titleLabel`，由 `SceneDelegate.swift:110-112` 随连接状态更新为 `飞享IM` / `飞享IM(正在连接...)` / `飞享IM(连接断开)`，当前不可点击。
- `AppConfig.imHosts`（`Sources/AppCore/AppConfig.swift:33`）是 `:` 分隔的 3 个 host，`RoundRobinHostSelector` 在每次 `startConnection()` 时轮询取下一个。用户无法指定节点，选择也不持久化。
- 没有任何延迟采集，也没有「当前连到哪个 host」的对外读口。
- `AboutViewController.swift:44` 已在明文展示 `imHosts` + port，故本功能不额外收敛服务器信息可见性。

### 与 Android 的关键差异

Android 那份设计一大半篇幅在填跨进程与连接清理的坑，这些在 iOS 全部不存在：

| Android 的坑 | iOS 现状 |
| --- | --- |
| `ClientService` 跑在 `:marsservice` 独立进程，取 host / 切 host 都要新增 AIDL + `JavaProtoLogic` 静态转发 | 同进程。`AppEnvironment` 直接持 `IMClient`，加一个 `private(set) var` 即可读到当前 host |
| `AbstractProtoService.connect()` 新建 `AndroidNIOClient` 不关旧实例 → 泄漏 socket 与 selector 线程 | `startConnection()`(`Sources/IMClient/IMClient.swift:212`) 是「每一轮连接的唯一入口」，进门先 `detachAndCancelTransport()` |
| 积压的 reconnect runnable 打到新 client 上 / 未摘 callback 自动重连回旧 host / `alarmWrapper` 待触发定时器 | 同一处 `startConnection()` 已统一 `cancelPendingReconnect()` / `cancelViabilityGraceTimer()` / `cancelHandshakeTimeoutTimer()` + `frameDecoder.reset()` |
| `disConnect()` 会拆 `imMemoryStore` 并永久堵死 `reconnect()`，切节点不能走它 | 同理不能走 `IMClient.disconnect()`（它置 `userDisconnect = true`）。新增的 `switchHosts()` 显式 `userDisconnect = false` |

因此 iOS 版无需改动 `RoundRobinHostSelector` 的选择算法，也无需任何新的进程间通道。

## 交互设计

### 入口

`AppHeaderBar.titleLabel` 开 `isUserInteractionEnabled` 并挂 `UITapGestureRecognizer`，暴露 `var onTitleTapped: (() -> Void)?`。不给整个 `AppHeaderBar` 挂手势——否则标题右侧空白区也可点。不加下拉指示符，现有的 `(连接断开)` 文字后缀已在承担状态提示。`MainTabBarController` 透传，`SceneDelegate` 里 wire 到弹窗。

### 弹窗

`ServerInfoViewController`，`modalPresentationStyle = .overFullScreen`，半透明遮罩 + 居中 `Theme.popupCard` 圆角卡片。两个状态由同一张卡片内的两个子 view 承载，crossfade + 高度约束动画切换，**不销毁重建**。

**状态 1 · 当前连接服务**

| 元素 | 规格 |
| --- | --- |
| 标题栏 | 文案「当前连接服务」+ 右侧 8pt 状态色圆点：`statusOnline` 已连接 / `statusConnecting` 连接中 / `statusOffline` 未连接 |
| 信息行 | 服务名称 / 连接地址 / 端口 / 连接状态 / 延迟，共 5 行；label 用 `Theme.textSecondary`，value 用 `Theme.textPrimary`，行间 `Theme.separator` 发丝线 |
| 服务名称值 | 固定文案「飞享IM 消息服务」。节点身份由「连接地址」行体现，不在此行重复 |
| 连接地址值 | 见「连接地址的取值」 |
| 端口值 | `AppConfig.imPort` |
| 连接状态值 | 「已连接」/「正在连接…」/「未连接」，配同一组状态色 |
| 延迟值 | 如 `32ms`；探测中显示 `UIActivityIndicatorView`；未连接或探测失败显示 `——` |
| 底部按钮 | 左「切换连接地址」（`Theme.backgroundSecondary` 底 / `textPrimary` 字），右「关闭」（`Theme.accent` 底 / `textOnAccent` 字） |

**状态 2 · 选择连接服务**

- 标题改为「选择连接服务」，右上角小字标注「建连耗时」。
- 单选列表：`自动（集群轮询）` / `上海节点` / `主节点` / `备节点 S2`。每行为 radio + 节点名 + 灰色小字 host，行尾显示建连耗时 `32ms` / `超时` / `无法解析` / `不可达` / 探测中转圈。「自动」行不显示耗时。
- 底部按钮：左「返回」，右「确定」（`Theme.accent` 底）。
- 点「确定」后写入持久化、触发重连，并**回到状态 1**，用户直接看到新地址与连接状态变化，弹窗不关闭。

### 深浅色

复用 `Theme` 的 `popupCard / textPrimary / textSecondary / separator / accent / textOnAccent / backgroundSecondary`。新增三个语义色 token `statusOnline / statusConnecting / statusOffline`，走 `Theme` 内部已有的 `dynamicColor(dark:light:)`（`App/Theme.swift:78`，`private static`，同文件内可直接用）——现有 `Theme` 只有 `accent`，没有绿/红。

## 连接地址的取值

`IMClient` 新增 `public private(set) var currentHost: String?`，在 `startConnection()` 里 `hostSelector.nextHost()` 之后赋值；`AppEnvironment` 加只读转发 `public var connectedHost: String? { imClient?.currentHost }`。

它记录的是**本轮连接尝试选中的 host**（非「最近一次握手成功的 host」）。这与「连接状态」行天然配套：地址说「在连谁」，状态说「连上没有」。

UI 兜底（对齐 Android）：`connectedHost` 为 nil（未登录 / 尚未发起过连接）时——pin 了显示 pin 的 host，未 pin 显示「自动（集群轮询）」。

## 延迟指标

统一为**到 `host` + `AppConfig.imPort`(6789) 的 TCP 建连耗时**：新开一条 `NWConnection`，计时到 `.ready` 后立即 `cancel()`，2s 超时。

选择这个指标的理由：

- 状态 1 的「延迟」与状态 2 列表中的数字是同一指标，可直接横向比较（「我现在 318ms，上海节点 41ms，该切」）。
- 探测路径与端口和真实 IM 连接完全一致，不会出现「ICMP 通但 IM 端口不通」的假绿灯。

已知取舍：若服务端 TCP 能 accept 但 IM 业务逻辑卡死，建连耗时仍显示正常。该场景由「连接状态」行覆盖——它由 `IMConnectionStatus` 驱动（CONNECT_ACK + 心跳），会掉到「未连接」。两行各管一件事：连接状态管应用层健康，延迟管网络往返。

明确不采用心跳 RTT：iOS 心跳在同进程内确实拿得到真实往返，但那样状态 1 的数字与状态 2 列表的建连耗时不是一个量纲，横向比较会误导；且未连接时本就没有值。

## 节点固定语义

- 列表首项「自动（集群轮询）」= 把全量 `:` 拼接串交给 `IMClient`，`RoundRobinHostSelector` 恢复轮询。
- 选中具体节点 = 只传该单个 host。`RoundRobinHostSelector` 拿到单 host 时 `index = (index + 1) % 1` 恒为 0，永远返回它——**pin 语义无需改动选择算法**。
- 选择写入 `UserDefaults`，异常重连与下次启动都沿用，直到用户改回「自动」。
- pin 的 host 已不在节点表中时（版本升级后集群调整）降级为自动。
- 切到不可用节点时**不自动回退**：4 次退避重连（`IMClient.maxAutomaticReconnectAttempts`）耗尽后停在「未连接」，用户可再开弹窗改回「自动」。注意 iOS 比 Android 多两条复活路径（`NWPathMonitor` 断网→有网沿、回前台 `ensureConnected()`），它们会重置退避重试，但仍是同一个坏节点——不构成自动回退。

## 改动清单

| 文件 | 改动 |
| --- | --- |
| `Sources/AppCore/AppConfig.swift` | 新增 `public struct ServerNode { name; host }` 与 `serverNodes: [ServerNode]`（上海节点 / 主节点 / 备节点 S2，顺序同现状）；`imHosts` 保留 `String` 类型但改为由节点表 `:` 拼接派生，`AboutViewController.swift:44` 不动 |
| `Sources/AppCore/ServerNodeStore.swift` **新** | `UserDefaults` 读写 pin（key `AppCore.pinnedIMHost`），形状照 `ThemePreferenceStore`。API：`pinnedHost(nodes:)`（校验并降级）/ `currentHostSpec(nodes:)` / `pin(_:)` / `unpin()`。纯逻辑，可单测 |
| `Sources/AppCore/AppEnvironment.swift` | 新增 `public let serverNodeStore: ServerNodeStore`（构造器注入，默认值 `ServerNodeStore()`）；`connectIfPossible()` 的 `hosts:` 改用 `serverNodeStore.currentHostSpec(nodes: config.serverNodes)`；新增 `connectedHost` 只读属性与 `switchServerNode(pinnedHost:)` |
| `Sources/IMClient/IMClient.swift` | `hostSelector` 由 `let` 改 `private var`；新增 `public private(set) var currentHost: String?`；新增 `public func switchHosts(_ hostsString: String) throws` |
| `Sources/IMClient/HostLatencyProbe.swift` **新** | `NWConnection` 建连计时，2s 超时，主队列回调，返回可 cancel 的句柄 |
| `App/Theme.swift` | 新增 `statusOnline` / `statusConnecting` / `statusOffline` |
| `App/AppHeaderBar.swift` | `titleLabel.isUserInteractionEnabled = true` + tap 手势，暴露 `onTitleTapped` |
| `App/MainTabBarController.swift` | 透传 `onTitleTapped` |
| `App/ServerInfoViewController.swift` **新** | 两状态弹窗容器 + `ServerInfoCardView`（状态 1）+ `ServerNodePickerView`（状态 2） |
| `App/SceneDelegate.swift` | wire `onTitleTapped` → present 弹窗；`applyConnectionStatus` 里同时把状态转发给在场弹窗（`weak var presentedServerInfoViewController`） |

### `switchHosts(_:)` 落定顺序

```
switchHosts(spec)                       // 主队列，无锁（全局线程约定）
  → hostSelector = try RoundRobinHostSelector(hostsString: spec)
  → userDisconnect = false              // 不是登出语义
  → reconnectAttempt = 0                // 退避计数归零
  → heartbeatToken?.cancel()
  → startConnection()                   // 已有统一清场：摘回调 + cancel transport
                                        //   + 取消重连/宽限/握手定时器 + frameDecoder.reset()
```

`switchHosts` 不置 `userDisconnect = true`、不动 `IMStorage`、不清 credentials，重连后照常 `sendConnectMessage()` 用已有 token 重新鉴权。同集群 token 通用，用户无需重新登录，本地消息库不受影响。

Android 必须手工处理的三个竞态在这里由 `startConnection()` 一次性覆盖，无需额外代码——但**该保证依赖于「`startConnection()` 是唯一连接入口」这一不变量**，后续若新增绕过它的连接路径，本设计的竞态安全性随之失效。

### 服务端侧

不发 DISCONNECT 信号（那是登出语义、会清 session），旧节点只看到 TCP FIN，按正常掉线处理；新连接落在另一个节点上，是全新 session。快速来回切换时旧节点可能在自身超时窗口内短暂保留半开会话，由服务端既有的重连与 `local_messageId` 去重机制处理。

## 数据流

```
点标题 → ServerInfoViewController
  ├ 状态1：AppEnvironment.connectedHost ?: ServerNodeStore 兜底
  │        + connectionStatus + HostLatencyProbe(该 host, 6789)
  └ 状态2：HostLatencyProbe(全部节点 host, 6789) 并发
       点确定 → AppEnvironment.switchServerNode(pinnedHost:)
              → ServerNodeStore.pin/unpin（UserDefaults）
              → IMClient.switchHosts(spec) → startConnection()
              → onConnectionStatusChange 回流 → 顶栏标题与状态1 同步刷新
```

弹窗依赖用闭包注入（`nodes` / `port` / `pinnedHost()` / `connectedHost()` / `connectionStatus()` / `onSwitch(String?)`），照 `SceneDelegate` 现有 wire 惯例，不把整个 `AppEnvironment` 递进 View 层，也不引单例。

## 错误处理

- 未连接 / 未登录：延迟显示 `——`，连接状态显示「未连接」，「切换连接地址」仍可用。未登录时 `switchServerNode` 只写 `ServerNodeStore`，下次 `connectIfPossible()` 生效。
- 选中项与当前项相同：点「确定」直接回状态 1，不触发重连。
- 探测结果映射：`.ready` → 耗时；2s 到点未 ready → 「超时」；DNS 类 `NWError` → 「无法解析」；其余 `.failed` → 「不可达」。
- 弹窗 dismiss 或切换状态后，上一批探测回调全部丢弃，不触碰已销毁的 view。
- 切到不可用节点：4 次退避重连耗尽后停在「未连接」，不自动回退。
- `switchHosts` 的 `throw` 只可能是 `emptyHostsString`——节点表是编译期常量，调用方 `try?` 吞掉即可，与 `connectIfPossible()` 里对 `IMClient.init` 的既有处理一致。

## 测试

SPM 单元测试：

- `AppCoreTests/ServerNodeStoreTests`：pin / unpin → `currentHostSpec` 映射；pin 到不在节点表中的 host 时降级为全量串。
- `IMClientTests/RoundRobinHostSelectorTests` 补：单 host 时恒定返回该 host（跨多次调用）。
- `IMClientTests`：`switchHosts` 后新 transport 连到新 host、旧 transport 被 cancel、`currentHost` 更新、`reconnectAttempt` 归零——复用现有的 fake `transportFactory`。
- `IMClientTests/HostLatencyProbeTests`：对本地 `NWListener` 测得非负耗时；对不可路由地址在 2s 左右返回 `.timeout`。

手动验收（真机，`00008120-001945391147401E`）：

- 依次切换三个节点，每次顶栏状态回到「已连接」且能正常收发消息。
- 快速连续切换 5 次以上，确认不崩、不出现连回旧 host 的现象。
- 切换后杀进程重启，确认仍连在所选节点。
- 改回「自动」后确认恢复轮询。
- 飞行模式下打开弹窗，确认显示「未连接」+ `——` 且不卡主线程。
- 深色 / 浅色模式下两个状态各截图核对配色。
