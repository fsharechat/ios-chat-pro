# 连接服务信息弹窗与节点切换（iOS） Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 点击共用顶栏的「飞享IM」标题弹出连接服务信息弹窗，展示当前地址/端口/状态/延迟，并允许在三个预置 IM 节点之间固定选择或恢复自动轮询。

**Architecture:** 节点表下沉到 `AppConfig.serverNodes`，pin 选择由 `AppCore/ServerNodeStore`（UserDefaults）持久化。运行时切换靠 `IMClient.switchHosts(_:)`——换掉 `hostSelector` 后调既有的 `startConnection()`，后者本就是每一轮连接的唯一入口并已做完整清场，因此不需要 Android 版为跨进程与旧连接泄漏所写的任何额外代码。延迟统一为到 `host:6789` 的 TCP 建连耗时，由 `IMClient/HostLatencyProbe` 用非阻塞 BSD socket 采集（**不能用 `NWConnection`**，它走系统代理，见 Task 3 开头的实测记录）。UI 是 `App` 层一个 `.overFullScreen` 的居中卡片弹窗，两状态在同一张卡片内切换。

**Tech Stack:** Swift / UIKit / BSD socket(`connect`+`poll`) / XCTest / SwiftPM（包名 `IMCore`）+ XcodeGen。

## Global Constraints

- **设计来源：** `docs/superpowers/specs/2026-07-31-server-switch-dialog-design.md`。有冲突以 spec 为准。
- **语言：** 所有新增代码注释与用户可见文案一律中文。
- **线程模型：** 全仓库无内部锁，一切从主队列调用。新增代码（`HostLatencyProbe` 回调、`switchHosts`）必须遵守，回调一律投递到 `.main`。
- **依赖方向严格单向：** `IMClient` 不得引用 `AppCore`/`IMKit`/`App`；`AppCore` 可引用 `IMClient`；`App` 可引用两者。
- **不手工编辑 `.xcodeproj`。** 新增文件放进已被 `project.yml` 的 `sources: [App]` 覆盖的 `App/` 目录，或 SPM 已覆盖的 `Sources/<Module>/` 目录，两者都无需重新生成工程。
- **不改 `RoundRobinHostSelector` 的选择算法。** pin 语义靠「只传单个 host」实现。
- **节点表定值（顺序即轮询顺序，首位是首选）：**
  - `上海节点` → `sh-backend-tcp.fsharechat.cn`
  - `主节点` → `backend-tcp.fsharechat.cn`
  - `备节点 S2` → `backend-tcp-s2.fsharechat.cn`
  - 端口 `6789`（`AppConfig.imPort`）
- **弹窗文案定值：** 标题「当前连接服务」/「选择连接服务」；服务名称值固定「飞享IM 消息服务」；状态值「已连接」/「正在连接…」/「未连接」；按钮「切换连接地址」/「关闭」/「返回」/「确定」；自动项「自动（集群轮询）」+ 副标题「按集群顺序轮询」；状态 2 右上角小字「建连耗时」；无值占位 `——`。
- **探测超时 2 秒。**
- **测试命令：** `swift test --filter <TestTarget>`。注意 `swift test` 在本机有固有失败基线（WebRTC macOS 切片），只看自己那个 filter 的结果，不要把既有失败当回归。
- **提交纪律：** 每个 Task 末尾提交一次。Task 5-7 是 UI，装机由用户验证后再由用户决定是否合并，**不要自行跑模拟器截图判定通过**。

---

## File Structure

| 文件 | 职责 |
| --- | --- |
| `Sources/AppCore/AppConfig.swift`（改） | 新增 `AppConfig.ServerNode` 与 `serverNodes`；`imHosts` 改为派生的计算属性 |
| `Sources/AppCore/ServerNodeStore.swift`（新） | pin 的持久化读写 + 「pin → host 串」的纯映射。无 UIKit、无网络 |
| `Sources/AppCore/AppEnvironment.swift`（改） | 持有 `ServerNodeStore`；暴露 `connectedHost` 与 `switchServerNode(pinnedHost:)` |
| `Sources/IMClient/IMClient.swift`（改） | `currentHost` 只读属性 + `switchHosts(_:)` |
| `Sources/IMClient/HostLatencyProbe.swift`（新） | TCP 建连耗时探测，与业务状态无关的纯工具 |
| `App/Theme.swift`（改） | 三个连接状态语义色 token |
| `App/AppHeaderBar.swift`（改） | 标题可点击，暴露 `onTitleTapped` |
| `App/MainTabBarController.swift`（改） | 透传 `onTitleTapped` |
| `App/ServerInfoViewController.swift`（新） | 弹窗容器：遮罩 + 卡片 + 两状态切换 + 探测生命周期 |
| `App/ServerInfoCardView.swift`（新） | 状态 1 的纯展示 view，不知道 `AppEnvironment` 存在 |
| `App/ServerNodePickerView.swift`（新） | 状态 2 的单选列表 view，同样纯展示 |
| `App/SceneDelegate.swift`（改） | wire 顶栏点击 → 弹窗；把连接状态转发给在场弹窗 |

---

## Task 1: 节点表与 ServerNodeStore

**Files:**
- Modify: `Sources/AppCore/AppConfig.swift`
- Create: `Sources/AppCore/ServerNodeStore.swift`
- Test: `Tests/AppCoreTests/ServerNodeStoreTests.swift`

**Interfaces:**
- Consumes: 无（首个 task）。
- Produces:
  - `AppConfig.ServerNode`：`struct`，`Equatable`，`public var name: String`、`public var host: String`、`public init(name: String, host: String)`
  - `AppConfig.serverNodes: [ServerNode]`（存储属性）
  - `AppConfig.imHosts: String`（**计算属性**，由 `serverNodes` 派生）
  - `AppConfig.init(apiBaseURL: URL, serverNodes: [ServerNode], imPort: UInt16, iceServers: [IceServer])`
  - `ServerNodeStore`：`final class`，`public init(defaults: UserDefaults = .standard)`、`public func pinnedHost(nodes: [AppConfig.ServerNode]) -> String?`、`public func currentHostSpec(nodes: [AppConfig.ServerNode]) -> String`、`public func pin(_ host: String)`、`public func unpin()`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/AppCoreTests/ServerNodeStoreTests.swift`：

```swift
import XCTest
@testable import AppCore

final class ServerNodeStoreTests: XCTestCase {
    private let nodes = [
        AppConfig.ServerNode(name: "上海节点", host: "sh.example.cn"),
        AppConfig.ServerNode(name: "主节点", host: "main.example.cn"),
        AppConfig.ServerNode(name: "备节点 S2", host: "s2.example.cn"),
    ]
    private var defaults: UserDefaults!
    private var store: ServerNodeStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ServerNodeStoreTests-\(UUID().uuidString)")
        store = ServerNodeStore(defaults: defaults)
    }

    func test_neverPinned_isAutoAndReturnsAllHostsJoined() {
        XCTAssertNil(store.pinnedHost(nodes: nodes))
        XCTAssertEqual(store.currentHostSpec(nodes: nodes), "sh.example.cn:main.example.cn:s2.example.cn")
    }

    func test_pin_returnsThatSingleHostOnly() {
        store.pin("s2.example.cn")

        XCTAssertEqual(store.pinnedHost(nodes: nodes), "s2.example.cn")
        XCTAssertEqual(store.currentHostSpec(nodes: nodes), "s2.example.cn")
    }

    func test_unpin_restoresAutoRoundRobin() {
        store.pin("s2.example.cn")
        store.unpin()

        XCTAssertNil(store.pinnedHost(nodes: nodes))
        XCTAssertEqual(store.currentHostSpec(nodes: nodes), "sh.example.cn:main.example.cn:s2.example.cn")
    }

    func test_pinnedHostNoLongerInNodeTable_degradesToAuto() {
        store.pin("retired.example.cn")

        XCTAssertNil(store.pinnedHost(nodes: nodes))
        XCTAssertEqual(store.currentHostSpec(nodes: nodes), "sh.example.cn:main.example.cn:s2.example.cn")
    }

    func test_pin_persistsAcrossStoreInstances() {
        store.pin("main.example.cn")

        let secondStore = ServerNodeStore(defaults: defaults)
        XCTAssertEqual(secondStore.pinnedHost(nodes: nodes), "main.example.cn")
    }

    func test_productionConfig_imHostsIsDerivedFromNodeTableInOrder() {
        XCTAssertEqual(
            AppConfig.production.imHosts,
            "sh-backend-tcp.fsharechat.cn:backend-tcp.fsharechat.cn:backend-tcp-s2.fsharechat.cn"
        )
        XCTAssertEqual(AppConfig.production.serverNodes.map(\.name), ["上海节点", "主节点", "备节点 S2"])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AppCoreTests.ServerNodeStoreTests`
Expected: 编译失败，`cannot find 'ServerNodeStore' in scope` / `type 'AppConfig' has no member 'ServerNode'`。

- [ ] **Step 3: 改 `AppConfig.swift`**

把 `Sources/AppCore/AppConfig.swift` 整体替换为：

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

    /// 一个可选的 IM 接入节点。`name` 是给用户看的中文名（连接服务弹窗的
    /// 单选列表用它），`host` 是实际连接地址。数组顺序即
    /// `RoundRobinHostSelector` 的轮询顺序，首位就是首选节点。
    public struct ServerNode: Equatable {
        public var name: String
        public var host: String

        public init(name: String, host: String) {
            self.name = name
            self.host = host
        }
    }

    public var apiBaseURL: URL
    public var serverNodes: [ServerNode]
    public var imPort: UInt16
    public var iceServers: [IceServer]

    /// 全部节点 host 的 `:` 拼接串——`RoundRobinHostSelector` 与
    /// `AboutViewController` 沿用的既有格式。由 `serverNodes` 派生而非
    /// 单独存储，避免节点表与拼接串两处失同步。
    public var imHosts: String { serverNodes.map(\.host).joined(separator: ":") }

    public init(apiBaseURL: URL, serverNodes: [ServerNode], imPort: UInt16, iceServers: [IceServer]) {
        self.apiBaseURL = apiBaseURL
        self.serverNodes = serverNodes
        self.imPort = imPort
        self.iceServers = iceServers
    }

    public static let production = AppConfig(
        apiBaseURL: URL(string: "https://backend-http.fsharechat.cn")!,
        serverNodes: [
            ServerNode(name: "上海节点", host: "sh-backend-tcp.fsharechat.cn"),
            ServerNode(name: "主节点", host: "backend-tcp.fsharechat.cn"),
            ServerNode(name: "备节点 S2", host: "backend-tcp-s2.fsharechat.cn"),
        ],
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

- [ ] **Step 4: 新建 `ServerNodeStore.swift`**

创建 `Sources/AppCore/ServerNodeStore.swift`：

```swift
import Foundation

/// 「用户固定了哪个 IM 节点」的唯一读写入口，形状照 `ThemePreferenceStore`。
///
/// 固定单个节点时只把该 host 交给 `IMClient`，`RoundRobinHostSelector` 拿到
/// 单 host 时 `index = (index + 1) % 1` 恒为 0、永远返回它——固定语义因此
/// 无需改动轮询算法。未固定时交出全部 host，恢复轮询。
///
/// **Threading contract:** safe to call from any queue — `UserDefaults`
/// serializes its own reads/writes internally, same as `ThemePreferenceStore`.
public final class ServerNodeStore {
    private static let key = "AppCore.pinnedIMHost"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 用户固定的 host。未固定，或固定值已不在节点表中（版本升级后集群
    /// 调整），都返回 nil，即「自动轮询」。
    public func pinnedHost(nodes: [AppConfig.ServerNode]) -> String? {
        guard let stored = defaults.string(forKey: Self.key),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              nodes.contains(where: { $0.host == stored }) else { return nil }
        return stored
    }

    /// 传给 `IMClient` 的 `:` 分隔 host 串：固定了返回单 host，否则返回全部。
    public func currentHostSpec(nodes: [AppConfig.ServerNode]) -> String {
        pinnedHost(nodes: nodes) ?? nodes.map(\.host).joined(separator: ":")
    }

    public func pin(_ host: String) {
        defaults.set(host, forKey: Self.key)
    }

    public func unpin() {
        defaults.removeObject(forKey: Self.key)
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter AppCoreTests.ServerNodeStoreTests`
Expected: 6 个用例全 PASS。

- [ ] **Step 6: 确认没有打断既有调用方**

Run: `swift build`
Expected: 成功。`AppEnvironment.swift:112` 的 `config.imHosts` 与 `App/AboutViewController.swift:44` 都读计算属性，签名未变。（`AppConfig(...)` 全仓库只有 `.production` 一处调用，已在 Step 3 一并改掉。）

- [ ] **Step 7: 提交**

```bash
git add Sources/AppCore/AppConfig.swift Sources/AppCore/ServerNodeStore.swift Tests/AppCoreTests/ServerNodeStoreTests.swift
git commit -m "feat(AppCore): 节点表下沉到 AppConfig.serverNodes + ServerNodeStore 持久化 pin"
```

---

## Task 2: IMClient 暴露当前 host 并支持运行时切换

**Files:**
- Modify: `Sources/IMClient/IMClient.swift`（`hostSelector` 声明处 `:116`、`startConnection()` `:212-228`、公开方法区 `:161-191`）
- Test: `Tests/IMClientTests/IMClientTests.swift`（追加）

**Interfaces:**
- Consumes: 无（不依赖 Task 1，可并行）。
- Produces:
  - `IMClient.currentHost: String?`（`public private(set)`）
  - `IMClient.switchHosts(_ hostsString: String) throws`

- [ ] **Step 1: 写失败的测试**

在 `Tests/IMClientTests/IMClientTests.swift` 的类内追加（放在文件末尾最后一个 `}` 之前）。注意 `setUp()` 里的 `transportFactory` 恒返回同一个 fake，所以这几个用例自建 client 以便记录每次拿到的 host：

```swift
    // MARK: - switchHosts

    /// 自建 client：`setUp()` 的 factory 不记录 host，这里要断言选中的 host。
    private func makeRecordingClient(
        hosts: String,
        transports: [FakeTransportConnection],
        recordedHosts: @escaping (String) -> Void
    ) throws -> IMClient {
        var index = 0
        let configuration = IMClientConfiguration(
            hosts: hosts,
            port: 6789,
            userId: "u1",
            token: makeTestToken(),
            clientIdentifier: "device-1"
        )
        return try IMClient(
            configuration: configuration,
            scheduler: scheduler,
            heartbeatManager: HeartbeatManager(),
            transportFactory: { host, _ in
                recordedHosts(host)
                let transport = transports[min(index, transports.count - 1)]
                index += 1
                return transport
            }
        )
    }

    func test_currentHost_isNilBeforeConnectingThenTracksSelectedHost() throws {
        var hosts: [String] = []
        let client = try makeRecordingClient(
            hosts: "host-a:host-b",
            transports: [FakeTransportConnection(), FakeTransportConnection()],
            recordedHosts: { hosts.append($0) }
        )
        XCTAssertNil(client.currentHost)

        client.connect()

        XCTAssertEqual(client.currentHost, "host-a")
        XCTAssertEqual(hosts, ["host-a"])
    }

    func test_switchHosts_cancelsOldTransportAndConnectsToNewHost() throws {
        let oldTransport = FakeTransportConnection()
        let newTransport = FakeTransportConnection()
        var hosts: [String] = []
        let client = try makeRecordingClient(
            hosts: "host-a:host-b",
            transports: [oldTransport, newTransport],
            recordedHosts: { hosts.append($0) }
        )
        client.connect()
        XCTAssertEqual(oldTransport.cancelCallCount, 0)

        try client.switchHosts("pinned-host")

        XCTAssertEqual(oldTransport.cancelCallCount, 1)
        XCTAssertEqual(newTransport.startCallCount, 1)
        XCTAssertEqual(hosts, ["host-a", "pinned-host"])
        XCTAssertEqual(client.currentHost, "pinned-host")
        XCTAssertEqual(client.connectionStatus, .connecting)
    }

    func test_switchHosts_singleHostIsUsedForEveryReconnect() throws {
        var hosts: [String] = []
        let client = try makeRecordingClient(
            hosts: "host-a:host-b",
            transports: [FakeTransportConnection(), FakeTransportConnection(), FakeTransportConnection()],
            recordedHosts: { hosts.append($0) }
        )
        client.connect()

        try client.switchHosts("pinned-host")
        // 断开一次，让退避重连再选一次 host
        client.connect()

        XCTAssertEqual(hosts, ["host-a", "pinned-host", "pinned-host"])
    }

    func test_switchHosts_resetsBackoffSoAutomaticReconnectsStartOver() throws {
        var hosts: [String] = []
        let transports = (0..<8).map { _ in FakeTransportConnection() }
        let client = try makeRecordingClient(
            hosts: "host-a",
            transports: transports,
            recordedHosts: { hosts.append($0) }
        )
        client.connect()
        // 耗尽 4 次自动重连额度（`maxAutomaticReconnectAttempts` = 4）
        for _ in 0..<4 {
            (client.currentTransportForTesting as? FakeTransportConnection)?.simulate(.failed(URLError(.timedOut)))
            XCTAssertTrue(scheduler.fireNext())
        }
        // 初次 connect 1 次 + 4 次退避重连
        XCTAssertEqual(hosts.count, 5)

        try client.switchHosts("pinned-host")
        (client.currentTransportForTesting as? FakeTransportConnection)?.simulate(.failed(URLError(.timedOut)))

        // 切换后额度归零，这次失败仍能排到一次自动重连（额度未归零时
        // `scheduleReconnectIfNeeded` 会直接 return，fireNext 就返回 false）
        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(hosts.count, 7)
        XCTAssertEqual(hosts.last, "pinned-host")
    }

    func test_switchHosts_emptyStringThrowsAndLeavesExistingConnectionAlone() throws {
        let transport = FakeTransportConnection()
        let client = try makeRecordingClient(
            hosts: "host-a",
            transports: [transport],
            recordedHosts: { _ in }
        )
        client.connect()

        XCTAssertThrowsError(try client.switchHosts("")) { error in
            XCTAssertEqual(error as? RoundRobinHostSelector.Error, .emptyHostsString)
        }
        XCTAssertEqual(transport.cancelCallCount, 0)
        XCTAssertEqual(client.currentHost, "host-a")
    }
```

`test_switchHosts_resetsBackoffSoAutomaticReconnectsStartOver` 需要 `IMClient` 上一个 `@testable` 逃生口（Step 3 会加）：

```swift
    /// 测试逃生口：让用例能对「当前在途的 transport」发事件。生产代码不用。
    var currentTransportForTesting: IMTransportConnection? { transport }
```

`scheduler.fireNext()` 是 `ManualScheduler`(`Sources/IMClient/Scheduler.swift:36`) 已有的 API：运行并移除最早的待执行动作，无待执行时返回 `false`。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMClientTests.IMClientTests`
Expected: 编译失败，`value of type 'IMClient' has no member 'switchHosts'` / `'currentHost'`。

- [ ] **Step 3: 改 `IMClient.swift`**

改动三处。

其一，`:116` 的 `let` 改 `var` 并在其后加 `currentHost` 的存储：

```swift
    private var hostSelector: RoundRobinHostSelector
```

其二，在公开属性区（`serverTimeDeltaMillis` 声明之后，`:100` 附近）加：

```swift
    /// 本轮连接尝试选中的 host（`startConnection()` 从 `hostSelector` 取到
    /// 即赋值），尚未发起过任何连接时为 nil。
    ///
    /// 记录的是「正在连谁」而不是「握手成功的是谁」——后者由
    /// `connectionStatus` 单独表达。连接服务弹窗把两者分别显示成
    /// 「连接地址」和「连接状态」两行，正是这个分工。
    public private(set) var currentHost: String?
```

其三，`startConnection()`(`:222`) 里记录选中的 host：

```swift
        let host = hostSelector.nextHost()
        currentHost = host
        let newTransport = transportFactory(host, configuration.port)
```

其四，在 `reconnectIfNeeded()` 之后加公开方法：

```swift
    /// 运行时切换 IM 接入节点：换掉轮询器后立刻重连到新目标。
    ///
    /// 不走 `disconnect()` —— 那会置 `userDisconnect = true` 永久堵死后续
    /// 重连（那是登出语义）。旧连接的清场（摘回调 + cancel transport +
    /// 取消重连/宽限/握手三个定时器 + `frameDecoder.reset()`）全部由
    /// `startConnection()` 完成，它是每一轮连接的唯一入口。**本方法的正确性
    /// 依赖这个不变量**：若将来新增绕过 `startConnection()` 的连接路径，
    /// 这里就会退化成「旧 socket 的字节和新连接交织进同一个 FrameDecoder」。
    ///
    /// 不清 `IMStorage`、不动 credentials，重连后照常 `sendConnectMessage()`
    /// 用已有 token 重新鉴权 —— 同集群 token 通用，用户无需重新登录。
    ///
    /// - Parameter hostsString: `:` 分隔的 host 串。单个 host = 固定该节点。
    /// - Throws: `RoundRobinHostSelector.Error.emptyHostsString`。抛出时不
    ///   触碰现有连接，调用方可安全忽略。
    public func switchHosts(_ hostsString: String) throws {
        // 先构造再赋值：构造失败时现有 hostSelector 与在途连接原封不动。
        hostSelector = try RoundRobinHostSelector(hostsString: hostsString)
        userDisconnect = false
        reconnectAttempt = 0
        heartbeatToken?.cancel()
        startConnection()
    }
```

以及测试逃生口（放在私有属性区末尾，`nextMessageId` 之后）：

```swift
    /// 测试逃生口：让用例能对「当前在途的 transport」发事件。生产代码不用。
    var currentTransportForTesting: IMTransportConnection? { transport }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMClientTests`
Expected: 新增 5 个用例 PASS，`IMClientTests`/`RoundRobinHostSelectorTests` 既有用例不回归。
（`RoundRobinHostSelectorTests.test_singleHostAlwaysReturnsTheSameHost` 已存在，spec 里那条「单 host 恒返回」的测试要求无需新增。）

- [ ] **Step 5: 提交**

```bash
git add Sources/IMClient/IMClient.swift Tests/IMClientTests/IMClientTests.swift
git commit -m "feat(IMClient): 暴露 currentHost 并支持 switchHosts 运行时换节点"
```

---

## Task 3: TCP 建连耗时探测

**Files:**
- Create: `Sources/IMClient/HostLatencyProbe.swift`
- Test: `Tests/IMClientTests/HostLatencyProbeTests.swift`

**Interfaces:**
- Consumes: 无（不依赖 Task 1/2，可并行）。
- Produces:
  - `HostLatencyProbe`（`public enum`，纯命名空间）
  - `HostLatencyProbe.ProbeResult`：`Equatable` enum，`case latency(Int)` / `.timedOut` / `.unresolved` / `.unreachable`
  - `HostLatencyProbe.Handle`：`final class`，`public func cancel()`
  - `HostLatencyProbe.probeAll(hosts: [String], port: UInt16, timeout: TimeInterval = timeoutSeconds, onResult: @escaping (String, ProbeResult) -> Void) -> Handle`
  - `HostLatencyProbe.timeoutSeconds: TimeInterval`（= 2）

> **实现方式已在 2026-07-31 被实测推翻一次，务必读这段再动手。**
> 初版计划用 `NWConnection` 探测，实测发现 **`NWConnection` 遵守系统代理设置**：
> 在一台开了 `SOCKS 127.0.0.1:1089` 的 Mac 上，对不可路由的 `192.0.2.1:6789`
> 探测会在 15ms 得到 `.ready`——它连上的是本地代理，跟目标是否可达无关。
> 同机裸 BSD socket 对同一地址正确返回超时。
> 后果不是「测不准」而是「测错」：任何开代理或 VPN 的真机上，三个节点都会
> 显示成 ~1ms，用户据此选节点等于抓阄。
> 因此本 task **必须用非阻塞 BSD socket `connect()` + `poll()`**，与 Android
> `HostLatencyProbe.probeOnce()` 的 `Socket.connect(addr, 2000)` 是同一件事。
> 不要「优化」回 `NWConnection`。

- [ ] **Step 1: 写失败的测试**

创建 `Tests/IMClientTests/HostLatencyProbeTests.swift`：

```swift
import XCTest
import Network
@testable import IMClient

final class HostLatencyProbeTests: XCTestCase {
    /// 起一个真实的本地 TCP listener，返回它实际绑定到的端口。
    /// 用进程内 listener 而不是线上服务器：结果确定、不依赖外网、不受
    /// 被测机器的代理设置影响。
    private func startLocalListener() throws -> (listener: NWListener, port: UInt16) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        return (listener, listener.port!.rawValue)
    }

    func test_probeAll_localListener_reportsNonNegativeLatency() throws {
        let (listener, port) = try startLocalListener()
        defer { listener.cancel() }

        let done = expectation(description: "probe finished")
        var received: (String, HostLatencyProbe.ProbeResult)?
        _ = HostLatencyProbe.probeAll(hosts: ["127.0.0.1"], port: port) { host, result in
            received = (host, result)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(received?.0, "127.0.0.1")
        guard case .latency(let milliseconds)? = received?.1 else {
            return XCTFail("expected .latency, got \(String(describing: received?.1))")
        }
        XCTAssertGreaterThanOrEqual(milliseconds, 0)
    }

    /// 拿一个**确定无人占用**的本地端口：`bind()` 到端口 0 让内核分配一个空闲
    /// 端口，读出端口号后立刻 `close()` 释放。此后到该端口的连接会被内核以
    /// `ECONNREFUSED` 立即拒绝，探测必然拿到 `.unreachable`。
    ///
    /// 另外两个"看起来更自然"的做法都实测过，都不行：
    /// - **起 `NWListener` 再 `cancel()`**：`cancel()` 是异步的，从调用到内核真正
    ///   撤销监听之间有几毫秒窗口，落在窗口里的 connect 会意外成功——实测偶发
    ///   失败率 30%~70%。
    /// - **`bind()` 但不 `listen()`、也不 `close()`**：macOS 内核对这种"被占用但
    ///   无监听队列"的端口收到 SYN 时是**静默丢弃**而非回 RST，探测拿到的是
    ///   `.timedOut`——实测 100% 复现，是稳定的错误答案。
    ///
    /// 裸 `close()` 是同步的，没有窗口；实测连续 5 次全部稳定得到 `ECONNREFUSED`。
    private func reserveClosedPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw XCTSkip("socket() failed, errno=\(errno)") }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // 让内核分配一个空闲端口
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var bindResult: Int32 = -1
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                // 必须写全 `Darwin.bind`：`XCTestCase` 在 macOS 上继承自 `NSObject`，
                // 其 Cocoa Bindings 的 `bind(_:to:withKeyPath:options:)` 会遮蔽全局
                // 的 `bind`，裸写会编译失败。
                bindResult = Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw XCTSkip("bind() failed, errno=\(errno)")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var nameResult: Int32 = -1
        withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                nameResult = getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        close(descriptor) // 同步释放，端口随即无人占用
        guard nameResult == 0 else { throw XCTSkip("getsockname() failed, errno=\(errno)") }
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    /// 没有任何进程占用的本地端口 → 内核立刻回 RST，必须报 `.unreachable`，
    /// 不能报成耗时。这条是"假绿灯"的核心防线。
    func test_probeAll_closedLocalPort_reportsUnreachable() throws {
        let port = try reserveClosedPort()

        let done = expectation(description: "probe finished")
        var result: HostLatencyProbe.ProbeResult?
        _ = HostLatencyProbe.probeAll(hosts: ["127.0.0.1"], port: port) { _, probeResult in
            result = probeResult
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result, .unreachable)
    }

    /// 192.0.2.1 是 RFC 5737 的 TEST-NET-1，保证不可路由：连接既不会成功
    /// 也不会立刻被拒，正好走超时分支。
    ///
    /// 这条用例同时是"没走系统代理"的回归防线——若实现被改回
    /// `NWConnection`，在配了代理的机器上这里会拿到 `.latency` 而失败。
    func test_probeAll_unroutableAddress_timesOut() {
        let done = expectation(description: "probe finished")
        var result: HostLatencyProbe.ProbeResult?
        _ = HostLatencyProbe.probeAll(hosts: ["192.0.2.1"], port: 6789, timeout: 1) { _, probeResult in
            result = probeResult
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result, .timedOut)
    }

    func test_probeAll_unresolvableHostname_reportsUnresolved() {
        let done = expectation(description: "probe finished")
        var result: HostLatencyProbe.ProbeResult?
        _ = HostLatencyProbe.probeAll(
            hosts: ["no-such-host.invalid"],
            port: 6789,
            timeout: 3
        ) { _, probeResult in
            result = probeResult
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(result, .unresolved)
    }

    func test_cancel_suppressesTheCallback() {
        let didCallBack = expectation(description: "callback must not fire")
        didCallBack.isInverted = true
        let handle = HostLatencyProbe.probeAll(hosts: ["192.0.2.1"], port: 6789, timeout: 0.5) { _, _ in
            didCallBack.fulfill()
        }
        handle.cancel()

        wait(for: [didCallBack], timeout: 2)
    }

    func test_probeAll_reportsEachHostSeparately() throws {
        let (listener, port) = try startLocalListener()
        defer { listener.cancel() }

        let done = expectation(description: "both hosts reported")
        done.expectedFulfillmentCount = 2
        var reported: [String] = []
        _ = HostLatencyProbe.probeAll(hosts: ["127.0.0.1", "localhost"], port: port) { host, _ in
            reported.append(host)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(Set(reported), ["127.0.0.1", "localhost"])
    }

    func test_probeAll_deliversCallbacksOnTheMainQueue() throws {
        let (listener, port) = try startLocalListener()
        defer { listener.cancel() }

        let done = expectation(description: "probe finished")
        var wasMainQueue = false
        _ = HostLatencyProbe.probeAll(hosts: ["127.0.0.1"], port: port) { _, _ in
            wasMainQueue = Thread.isMainThread
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertTrue(wasMainQueue)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMClientTests.HostLatencyProbeTests`
Expected: 编译失败，`cannot find 'HostLatencyProbe' in scope`。

- [ ] **Step 3: 实现 `HostLatencyProbe.swift`**

创建 `Sources/IMClient/HostLatencyProbe.swift`：

```swift
import Foundation

/// 测「到 `host` + `port` 建立一条 TCP 连接要多久」。
///
/// 刻意用与 IM 完全相同的 host 和端口，避免出现「ICMP 通但 IM 端口不通」的
/// 假绿灯。探测连接一建立就立刻 `close()`，不发送任何协议数据。
///
/// **为什么是裸 BSD socket 而不是 `NWConnection`：** `NWConnection` 遵守系统
/// 代理设置。在配了 HTTP/SOCKS 代理或 VPN 的设备上，它连的是代理而不是目标
/// 节点，`.ready` 会在十几毫秒内到达且与目标是否可达无关——2026-07-31 实测：
/// 一台开了 `SOCKS 127.0.0.1:1089` 的 Mac 对不可路由的 `192.0.2.1:6789` 探测
/// 得到 `.ready`(15ms)，同机裸 socket 正确超时。那会让所有节点都显示成 ~1ms，
/// 是错误答案而不是慢答案。这里与 Android `HostLatencyProbe.probeOnce()` 的
/// `Socket.connect(new InetSocketAddress(host, port), 2000)` 保持同一实现方式。
///
/// **Threading contract:** 阻塞的 connect 跑在后台队列，结果一律投递回主队列，
/// 与 `IMClient` 的单队列约定一致；调用方必须在主队列调用 `probeAll` /
/// `Handle.cancel()`。`Handle.isCancelled` 只在主队列读写，因此无需加锁——
/// 与全仓库「无内部锁」的约定一致。
public enum HostLatencyProbe {
    public static let timeoutSeconds: TimeInterval = 2

    public enum ProbeResult: Equatable {
        /// 建连耗时，毫秒。
        case latency(Int)
        /// 超时窗口内未建立连接。
        case timedOut
        /// 域名无法解析。
        case unresolved
        /// 连接被拒绝或网络不可达。
        case unreachable
    }

    /// 一批在途探测。调用方必须在界面销毁时 `cancel()`，否则回调会打到
    /// 已销毁的 view 上。
    ///
    /// `cancel()` 不中断已经发出的 connect —— 那需要跨线程操作 fd，会把锁
    /// 引回来。阻塞的 connect 最多挂到 `timeout` 就自己结束，届时结果在
    /// 主队列上被这个标志丢弃，代价是一个短暂的空转线程，换来的是零锁。
    public final class Handle {
        fileprivate private(set) var isCancelled = false

        public func cancel() {
            isCancelled = true
        }
    }

    /// 并发探测多个 host，每个 host 出结果就回调一次（主队列，顺序不保证）。
    @discardableResult
    public static func probeAll(
        hosts: [String],
        port: UInt16,
        timeout: TimeInterval = timeoutSeconds,
        onResult: @escaping (String, ProbeResult) -> Void
    ) -> Handle {
        let handle = Handle()
        let timeoutMilliseconds = Int32(max(1, timeout * 1000))
        for host in hosts {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = probeOnce(host: host, port: port, timeoutMilliseconds: timeoutMilliseconds)
                DispatchQueue.main.async {
                    guard !handle.isCancelled else { return }
                    onResult(host, result)
                }
            }
        }
        return handle
    }

    /// 同步探测一个 host，阻塞调用线程，**不得在主队列调用**。
    static func probeOnce(host: String, port: UInt16, timeoutMilliseconds: Int32) -> ProbeResult {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var addressList: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &addressList) == 0,
              let address = addressList else { return .unresolved }
        defer { freeaddrinfo(addressList) }

        let descriptor = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
        guard descriptor >= 0 else { return .unreachable }
        defer { close(descriptor) }

        // 非阻塞 connect + poll：阻塞式 connect 的超时由内核决定（可达 75 秒），
        // 没法压到我们要的 2 秒。
        var flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return .unreachable }
        flags |= O_NONBLOCK
        guard fcntl(descriptor, F_SETFL, flags) >= 0 else { return .unreachable }

        let start = DispatchTime.now()
        if connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else { return .unreachable }
            var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptorSet, 1, timeoutMilliseconds)
            if ready == 0 { return .timedOut }
            guard ready > 0 else { return .unreachable }
            // poll 报可写只说明 connect 有了结论，成败要看 SO_ERROR ——
            // 被 RST 拒绝的连接同样会让 fd 变可写。
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else { return .unreachable }
        }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return .latency(Int(elapsedNanoseconds / 1_000_000))
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMClientTests.HostLatencyProbeTests 2>&1 | grep -E "Test Case|Test Suite|Executed|error:"`
Expected: 7 个用例全 PASS。

三条用例的预期结果不可动摇，它们各自守着一条真实的失败模式，**任何一条改成更宽松的断言都是缺陷**：

- `test_probeAll_closedLocalPort_reportsUnreachable` → `.unreachable`（守「端口无人监听不得报成耗时」）
- `test_probeAll_unroutableAddress_timesOut` → `.timedOut`（守「不可路由不得报成耗时」，同时是「没走系统代理」的回归防线）
- `test_probeAll_unresolvableHostname_reportsUnresolved` → `.unresolved`（守「域名解析失败要能和网络不可达区分开」）

若 `test_probeAll_unresolvableHostname_reportsUnresolved` 在你的网络下失败，先查 DNS 是否被劫持到了一个应答页（`dig no-such-host.invalid` 应返回 NXDOMAIN）。**不要**为了让它变绿而放宽断言。

- [ ] **Step 5: 手工核验数字合理（不进自动化用例）**

自动化用例只跑本地地址、不碰外网（外网用例会随网络抖动变红，不适合进 CI）。
真实节点的数字量级用下面这个一次性脚本核验，**它不进仓库**：

```bash
cat > /tmp/probe-check.swift <<'SWIFT'
import Foundation

func probeOnce(host: String, port: UInt16, timeoutMilliseconds: Int32) -> String {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                         ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                         ai_addr: nil, ai_next: nil)
    var addressList: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &addressList) == 0,
          let address = addressList else { return "unresolved" }
    defer { freeaddrinfo(addressList) }
    let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
    guard fd >= 0 else { return "unreachable" }
    defer { close(fd) }
    var flags = fcntl(fd, F_GETFL, 0)
    flags |= O_NONBLOCK
    _ = fcntl(fd, F_SETFL, flags)
    let start = DispatchTime.now()
    if connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) != 0 {
        guard errno == EINPROGRESS else { return "unreachable(errno=\(errno))" }
        var set = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&set, 1, timeoutMilliseconds)
        if ready == 0 { return "timedOut" }
        guard ready > 0 else { return "unreachable" }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
        if socketError != 0 { return "unreachable(so_error=\(socketError))" }
    }
    return "latency(\((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)ms)"
}

for host in ["192.0.2.1", "sh-backend-tcp.fsharechat.cn",
             "backend-tcp.fsharechat.cn", "backend-tcp-s2.fsharechat.cn"] {
    print("\(host) -> \(probeOnce(host: host, port: 6789, timeoutMilliseconds: 2000))")
}
SWIFT
swiftc -O /tmp/probe-check.swift -o /tmp/probe-check && /tmp/probe-check
```

期望：`192.0.2.1` 是 `timedOut`，三个生产节点都是几十到几百毫秒的 `latency`。
参考量级（2026-07-31 在开发机实测）：上海 ~33ms，主节点 ~219ms，备节点 S2 ~187ms。
**若三个节点都返回个位数毫秒**，说明你的实现又走上了系统代理，回 Step 3 检查。

- [ ] **Step 6: 提交**

```bash
git add Sources/IMClient/HostLatencyProbe.swift Tests/IMClientTests/HostLatencyProbeTests.swift
git commit -m "feat(IMClient): 新增 HostLatencyProbe 采集到 IM 端口的 TCP 建连耗时"
```

---

## Task 4: AppEnvironment 接线

**Files:**
- Modify: `Sources/AppCore/AppEnvironment.swift`（属性区 `:19-23`、`init` `:59-87`、`connectIfPossible()` `:111-117`）
- Test: `Tests/AppCoreTests/AppEnvironmentTests.swift`（追加）

**Interfaces:**
- Consumes: Task 1 的 `AppConfig.serverNodes` / `ServerNodeStore`；Task 2 的 `IMClient.currentHost` / `switchHosts(_:)`。
- Produces:
  - `AppEnvironment.serverNodeStore: ServerNodeStore`（`public let`）
  - `AppEnvironment.connectedHost: String?`（`public var`，只读计算）
  - `AppEnvironment.switchServerNode(pinnedHost: String?)`
  - `AppEnvironment.init` 新增参数 `serverNodeStore: ServerNodeStore = ServerNodeStore()`（放在 `deviceIdentifierProvider` 之后、`transportFactory` 之前）

- [ ] **Step 1: 写失败的测试**

在 `Tests/AppCoreTests/AppEnvironmentTests.swift` 类内追加：

```swift
    // MARK: - 节点切换

    /// 记录每次建连用的 host。`setUp()` 的 factory 丢弃 host 参数，这里要断言它。
    private func makeEnvironmentRecordingHosts(
        serverNodeStore: ServerNodeStore,
        onHost: @escaping (String) -> Void
    ) -> AppEnvironment {
        AppEnvironment(
            storage: storage,
            credentialsStore: credentialsStore,
            deviceIdentifierProvider: DeviceIdentifierProvider(defaults: UserDefaults(suiteName: "AppEnvironmentTests.\(UUID().uuidString)")!),
            serverNodeStore: serverNodeStore,
            transportFactory: { [unowned self] host, _ in
                onHost(host)
                return self.fakeTransport
            }
        )
    }

    private func makeIsolatedNodeStore() -> ServerNodeStore {
        ServerNodeStore(defaults: UserDefaults(suiteName: "AppEnvironmentTests.nodes.\(UUID().uuidString)")!)
    }

    func test_connectIfPossible_pinnedNode_connectsToThatHostOnly() {
        let nodeStore = makeIsolatedNodeStore()
        nodeStore.pin("backend-tcp-s2.fsharechat.cn")
        var hosts: [String] = []
        let environment = makeEnvironmentRecordingHosts(serverNodeStore: nodeStore) { hosts.append($0) }
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))

        XCTAssertTrue(environment.connectIfPossible())

        XCTAssertEqual(hosts, ["backend-tcp-s2.fsharechat.cn"])
        XCTAssertEqual(environment.connectedHost, "backend-tcp-s2.fsharechat.cn")
    }

    func test_connectIfPossible_noPin_connectsToTheFirstNodeInTheTable() {
        var hosts: [String] = []
        let environment = makeEnvironmentRecordingHosts(serverNodeStore: makeIsolatedNodeStore()) { hosts.append($0) }
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))

        environment.connectIfPossible()

        XCTAssertEqual(hosts, ["sh-backend-tcp.fsharechat.cn"])
    }

    func test_switchServerNode_persistsPinAndReconnectsToTheNewHost() {
        let nodeStore = makeIsolatedNodeStore()
        var hosts: [String] = []
        let environment = makeEnvironmentRecordingHosts(serverNodeStore: nodeStore) { hosts.append($0) }
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))
        environment.connectIfPossible()

        environment.switchServerNode(pinnedHost: "backend-tcp.fsharechat.cn")

        XCTAssertEqual(nodeStore.pinnedHost(nodes: AppConfig.production.serverNodes), "backend-tcp.fsharechat.cn")
        XCTAssertEqual(hosts, ["sh-backend-tcp.fsharechat.cn", "backend-tcp.fsharechat.cn"])
        XCTAssertEqual(environment.connectedHost, "backend-tcp.fsharechat.cn")
    }

    func test_switchServerNode_nilRestoresAutoRoundRobin() {
        let nodeStore = makeIsolatedNodeStore()
        nodeStore.pin("backend-tcp-s2.fsharechat.cn")
        var hosts: [String] = []
        let environment = makeEnvironmentRecordingHosts(serverNodeStore: nodeStore) { hosts.append($0) }
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))
        environment.connectIfPossible()

        environment.switchServerNode(pinnedHost: nil)

        XCTAssertNil(nodeStore.pinnedHost(nodes: AppConfig.production.serverNodes))
        // 恢复轮询后，新一轮从节点表首位开始
        XCTAssertEqual(hosts.last, "sh-backend-tcp.fsharechat.cn")
    }

    func test_switchServerNode_whileLoggedOut_onlyPersistsAndDoesNotCrash() {
        let nodeStore = makeIsolatedNodeStore()
        var hosts: [String] = []
        let environment = makeEnvironmentRecordingHosts(serverNodeStore: nodeStore) { hosts.append($0) }

        environment.switchServerNode(pinnedHost: "backend-tcp.fsharechat.cn")

        XCTAssertEqual(nodeStore.pinnedHost(nodes: AppConfig.production.serverNodes), "backend-tcp.fsharechat.cn")
        XCTAssertTrue(hosts.isEmpty)
        XCTAssertNil(environment.connectedHost)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AppCoreTests.AppEnvironmentTests`
Expected: 编译失败，`extra argument 'serverNodeStore' in call` / `has no member 'switchServerNode'`。

- [ ] **Step 3: 改 `AppEnvironment.swift`**

其一，在 `public let deviceIdentifierProvider` 之后加属性：

```swift
    /// 用户固定的 IM 节点。挂在这里而非塞进 `AppConfig`，因为它是**用户
    /// 选择**（可变、持久化），`AppConfig` 是编译期常量配置。
    public let serverNodeStore: ServerNodeStore
```

其二，`init` 签名在 `deviceIdentifierProvider` 之后插入参数，并在函数体里赋值：

```swift
        deviceIdentifierProvider: DeviceIdentifierProvider = DeviceIdentifierProvider(),
        serverNodeStore: ServerNodeStore = ServerNodeStore(),
```

```swift
        self.deviceIdentifierProvider = deviceIdentifierProvider
        self.serverNodeStore = serverNodeStore
```

其三，`connectIfPossible()` 里的 `hosts:` 改为读节点选择：

```swift
        let configuration = IMClientConfiguration(
            hosts: serverNodeStore.currentHostSpec(nodes: config.serverNodes),
            port: config.imPort,
```

其四，在 `ensureConnected()` 之后加两个成员：

```swift
    /// 本轮连接尝试选中的 host；未登录或尚未发起连接时为 nil。连接服务
    /// 弹窗用它显示「连接地址」，取不到时由 UI 按 pin 状态兜底。
    public var connectedHost: String? { imClient?.currentHost }

    /// 固定到某个节点（`pinnedHost` 非 nil）或恢复自动轮询（nil）。
    /// 先写持久化，再让在途连接立即切过去；未登录（`imClient` 为 nil）时
    /// 只写持久化，下次 `connectIfPossible()` 自然读到。
    public func switchServerNode(pinnedHost: String?) {
        if let pinnedHost {
            serverNodeStore.pin(pinnedHost)
        } else {
            serverNodeStore.unpin()
        }
        // 节点表是编译期常量，host 串不可能为空，`switchHosts` 的 throw
        // 到不了这里——与 `connectIfPossible()` 里对 `IMClient.init` 抛错的
        // 既有处理保持一致（那里也是 `try?`）。
        try? imClient?.switchHosts(serverNodeStore.currentHostSpec(nodes: config.serverNodes))
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AppCoreTests`
Expected: 新增 5 个用例 PASS，`AppEnvironmentTests` 既有用例不回归。

- [ ] **Step 5: 提交**

```bash
git add Sources/AppCore/AppEnvironment.swift Tests/AppCoreTests/AppEnvironmentTests.swift
git commit -m "feat(AppCore): AppEnvironment 接入 ServerNodeStore，暴露 connectedHost 与 switchServerNode"
```

---

## Task 5: 状态语义色与可点击的顶栏标题

**Files:**
- Modify: `App/Theme.swift`（`textOnAccent` 定义之后，`bubbleCornerRadius` 之前）
- Modify: `App/AppHeaderBar.swift`
- Modify: `App/MainTabBarController.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `Theme.statusOnline` / `Theme.statusConnecting` / `Theme.statusOffline`（均为 `UIColor`）
  - `AppHeaderBar.onTitleTapped: (() -> Void)?`
  - `MainTabBarController.onTitleTapped: (() -> Void)?`

本 task 无单元测试：`App` target 不在 SPM 里，没有对应测试目标，且改动是纯 UIKit 接线。验证靠编译 + 后续 task 的真机验收。

- [ ] **Step 1: 加状态色 token**

在 `App/Theme.swift` 的 `public static let textOnAccent = ...`（`:52`）之后插入：

```swift
    /// 连接状态语义色（连接服务弹窗的状态圆点与「连接状态」行）。
    /// 深色下用偏亮的绿/红，保证在 `popupCard`(#232430) 上仍有足够对比度；
    /// 浅色下取更深的同色系，配白底。刻意不复用 `accent`——它在深色是绿、
    /// 浅色是蓝，无法表达「连上/没连上」的语义。
    public static let statusOnline = dynamicColor(dark: 0x3DDC84, light: 0x2BA84A)
    public static let statusConnecting = dynamicColor(dark: 0x5B8DEF, light: 0x3E64E4)
    public static let statusOffline = dynamicColor(dark: 0xFF6B6B, light: 0xE53935)
```

- [ ] **Step 2: 让 `AppHeaderBar` 标题可点击**

在 `App/AppHeaderBar.swift` 的 `var onPlusTapped: (() -> Void)?`（`:11`）之后加：

```swift
    /// 点击标题的动作（弹出连接服务弹窗），由 `SceneDelegate` 注入。
    var onTitleTapped: (() -> Void)?
```

在 `init` 里 `titleLabel.translatesAutoresizingMaskIntoConstraints = false` 之前插入：

```swift
        // 手势只挂在 label 上、不挂整个顶栏：否则标题右侧那片空白也会
        // 变成可点区域，与 Android 版把监听挂在 Toolbar 标题 TextView 上
        // 而不是 Toolbar 本身的理由一致。
        titleLabel.isUserInteractionEnabled = true
        titleLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(titleTapped)))
```

在 `@objc private func plusTapped()` 之后加：

```swift
    @objc private func titleTapped() {
        onTitleTapped?()
    }
```

- [ ] **Step 3: `MainTabBarController` 透传**

在 `var onPlusTapped: (() -> Void)?`（`:25`）之后加：

```swift
    /// 顶栏标题的点击动作，由 `SceneDelegate` 注入。
    var onTitleTapped: (() -> Void)?
```

在 `setupHeaderBar()` 里 `headerBar.onPlusTapped = ...`（`:65`）之后加：

```swift
        headerBar.onTitleTapped = { [weak self] in self?.onTitleTapped?() }
```

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 提交**

```bash
git add App/Theme.swift App/AppHeaderBar.swift App/MainTabBarController.swift
git commit -m "feat(App): 顶栏标题可点击 + 连接状态语义色 token"
```

---

## Task 6: 状态 1「当前连接服务」弹窗

**Files:**
- Create: `App/ServerInfoCardView.swift`
- Create: `App/ServerInfoViewController.swift`
- Modify: `App/SceneDelegate.swift`（`makeMainTabBarController()` 的 `applyConnectionStatus` 附近 `:100-116`，以及属性区 `:19-22`）

**Interfaces:**
- Consumes: Task 1 的 `AppConfig.ServerNode`；Task 3 的 `HostLatencyProbe`；Task 4 的 `AppEnvironment.connectedHost` / `serverNodeStore` / `switchServerNode(pinnedHost:)`；Task 5 的 `Theme.status*` 与 `MainTabBarController.onTitleTapped`。
- Produces:
  - `ServerInfoCardView`：`init()`；`var onSwitchTapped: (() -> Void)?`；`var onCloseTapped: (() -> Void)?`；`func update(status: IMConnectionStatus, address: String, port: UInt16)`；`func updateLatency(_ result: HostLatencyProbe.ProbeResult?)`（`nil` = 探测中）
  - `ServerInfoViewController`：`init(nodes: [AppConfig.ServerNode], port: UInt16, pinnedHost: @escaping () -> String?, connectedHost: @escaping () -> String?, connectionStatus: @escaping () -> IMConnectionStatus, onSwitch: @escaping (String?) -> Void)`；`func refreshStatus(_ status: IMConnectionStatus)`
  - 供 Task 7 使用的内部方法 `ServerInfoViewController.showPickerState()`（Task 6 里先留成空实现）

- [ ] **Step 1: 写 `ServerInfoCardView`**

创建 `App/ServerInfoCardView.swift`：

```swift
// App/ServerInfoCardView.swift
import UIKit
import IMClient

/// 连接服务弹窗的状态 1：一张只读的信息卡片。
///
/// 纯展示——不知道 `AppEnvironment`、不发起探测、不持有任何业务对象，
/// 全部数据由 `ServerInfoViewController` 喂进来。
final class ServerInfoCardView: UIView {
    var onSwitchTapped: (() -> Void)?
    var onCloseTapped: (() -> Void)?

    private let statusDot = UIView()
    private let addressValueLabel = UILabel()
    private let portValueLabel = UILabel()
    private let statusValueLabel = UILabel()
    private let latencyValueLabel = UILabel()
    private let latencySpinner = UIActivityIndicatorView(style: .medium)

    init() {
        super.init(frame: .zero)

        let titleLabel = UILabel()
        titleLabel.text = "当前连接服务"
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary

        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), statusDot])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8

        // 「服务名称」是固定文案：节点身份由「连接地址」行体现，不在此重复。
        let nameRow = Self.makeRow(label: "服务名称", valueLabel: Self.makeValueLabel(text: "飞享IM 消息服务"))
        let addressRow = Self.makeRow(label: "连接地址", valueLabel: addressValueLabel)
        let portRow = Self.makeRow(label: "端口", valueLabel: portValueLabel)
        let statusRow = Self.makeRow(label: "连接状态", valueLabel: statusValueLabel)

        [addressValueLabel, portValueLabel, statusValueLabel, latencyValueLabel].forEach(Self.styleValueLabel)

        latencySpinner.hidesWhenStopped = true
        let latencyValueStack = UIStackView(arrangedSubviews: [latencySpinner, latencyValueLabel])
        latencyValueStack.axis = .horizontal
        latencyValueStack.spacing = 6
        latencyValueStack.alignment = .center
        let latencyRow = Self.makeRow(label: "延迟", valueView: latencyValueStack)

        let infoStack = UIStackView(arrangedSubviews: [
            nameRow, Self.makeHairline(),
            addressRow, Self.makeHairline(),
            portRow, Self.makeHairline(),
            statusRow, Self.makeHairline(),
            latencyRow,
        ])
        infoStack.axis = .vertical
        infoStack.spacing = 0

        let switchButton = Self.makeSecondaryButton(title: "切换连接地址")
        switchButton.addTarget(self, action: #selector(switchTapped), for: .touchUpInside)
        let closeButton = Self.makePrimaryButton(title: "关闭")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        let buttonRow = UIStackView(arrangedSubviews: [switchButton, closeButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually

        let root = UIStackView(arrangedSubviews: [titleRow, infoStack, buttonRow])
        root.axis = .vertical
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(status: IMConnectionStatus, address: String, port: UInt16) {
        addressValueLabel.text = address
        portValueLabel.text = "\(port)"
        switch status {
        case .connected:
            statusValueLabel.text = "已连接"
            statusValueLabel.textColor = Theme.statusOnline
            statusDot.backgroundColor = Theme.statusOnline
        case .connecting:
            statusValueLabel.text = "正在连接…"
            statusValueLabel.textColor = Theme.statusConnecting
            statusDot.backgroundColor = Theme.statusConnecting
        case .disconnected:
            statusValueLabel.text = "未连接"
            statusValueLabel.textColor = Theme.statusOffline
            statusDot.backgroundColor = Theme.statusOffline
        }
    }

    /// `nil` 表示探测进行中（显示转圈）。
    func updateLatency(_ result: HostLatencyProbe.ProbeResult?) {
        guard let result else {
            latencyValueLabel.text = nil
            latencySpinner.startAnimating()
            return
        }
        latencySpinner.stopAnimating()
        latencyValueLabel.text = ServerLatencyFormatter.text(for: result)
    }

    /// 未连接 / 无可探测目标时的占位显示。与「探测中」「有结果」是三种
    /// 互斥状态，所以单独开一个入口，而不是往 `ProbeResult` 里塞哨兵值。
    func showLatencyPlaceholder() {
        latencySpinner.stopAnimating()
        latencyValueLabel.text = ServerLatencyFormatter.placeholder
    }

    // MARK: - 构件

    private static func makeValueLabel(text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        styleValueLabel(label)
        return label
    }

    private static func styleValueLabel(_ label: UILabel) {
        label.font = .systemFont(ofSize: 15)
        label.textColor = Theme.textPrimary
        label.textAlignment = .right
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
    }

    private static func makeRow(label: String, valueLabel: UILabel) -> UIView {
        makeRow(label: label, valueView: valueLabel)
    }

    private static func makeRow(label: String, valueView: UIView) -> UIView {
        let nameLabel = UILabel()
        nameLabel.text = label
        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.textColor = Theme.textSecondary
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [nameLabel, valueView])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.distribution = .equalSpacing
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        return row
    }

    private static func makeHairline() -> UIView {
        let line = UIView()
        line.backgroundColor = Theme.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return line
    }

    private static func makePrimaryButton(title: String) -> UIButton {
        let button = makeButtonShell(title: title)
        button.backgroundColor = Theme.accent
        button.setTitleColor(Theme.textOnAccent, for: .normal)
        return button
    }

    private static func makeSecondaryButton(title: String) -> UIButton {
        let button = makeButtonShell(title: title)
        button.backgroundColor = Theme.backgroundSecondary
        button.setTitleColor(Theme.textPrimary, for: .normal)
        return button
    }

    private static func makeButtonShell(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.layer.cornerRadius = Theme.cardCornerRadius
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    @objc private func switchTapped() { onSwitchTapped?() }
    @objc private func closeTapped() { onCloseTapped?() }
}

/// 探测结果 → 用户可读文案。状态 1 和状态 2 共用，保证两处口径一致。
enum ServerLatencyFormatter {
    static func text(for result: HostLatencyProbe.ProbeResult) -> String {
        switch result {
        case .latency(let milliseconds): return "\(milliseconds)ms"
        case .timedOut: return "超时"
        case .unresolved: return "无法解析"
        case .unreachable: return "不可达"
        }
    }

    /// 未连接 / 无值时的占位。
    static let placeholder = "——"
}
```

- [ ] **Step 2: 写 `ServerInfoViewController`**

创建 `App/ServerInfoViewController.swift`：

```swift
// App/ServerInfoViewController.swift
import UIKit
import AppCore
import IMClient

/// 点顶栏标题弹出的连接服务弹窗。居中卡片 + 半透明遮罩，两个状态在同一张
/// 卡片内切换、不销毁重建（对齐 android-chat-pro 的 `ServerInfoDialog`）。
///
/// 依赖全部走闭包注入，照 `SceneDelegate` 现有的 wire 惯例——不把
/// `AppEnvironment` 递进 view 层，也不引单例。
final class ServerInfoViewController: UIViewController {
    private let nodes: [AppConfig.ServerNode]
    private let port: UInt16
    private let pinnedHost: () -> String?
    private let connectedHost: () -> String?
    private let connectionStatus: () -> IMConnectionStatus
    private let onSwitch: (String?) -> Void

    private let cardView = UIView()
    private let infoCard = ServerInfoCardView()
    /// 当前在途的探测。切状态或弹窗消失时必须 cancel，否则回调会打到已
    /// 销毁的 view 上。
    private var probeHandle: HostLatencyProbe.Handle?

    init(
        nodes: [AppConfig.ServerNode],
        port: UInt16,
        pinnedHost: @escaping () -> String?,
        connectedHost: @escaping () -> String?,
        connectionStatus: @escaping () -> IMConnectionStatus,
        onSwitch: @escaping (String?) -> Void
    ) {
        self.nodes = nodes
        self.port = port
        self.pinnedHost = pinnedHost
        self.connectedHost = connectedHost
        self.connectionStatus = connectionStatus
        self.onSwitch = onSwitch
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        probeHandle?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        cardView.backgroundColor = Theme.popupCard
        cardView.layer.cornerRadius = 16
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            cardView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.86).withPriority(.defaultHigh),
        ])

        infoCard.onCloseTapped = { [weak self] in self?.dismiss(animated: true) }
        infoCard.onSwitchTapped = { [weak self] in self?.showPickerState() }

        showInfoState(animated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        probeHandle?.cancel()
        probeHandle = nil
    }

    /// 连接状态变化时由 `SceneDelegate` 转发进来，让状态 1 与顶栏标题同步。
    func refreshStatus(_ status: IMConnectionStatus) {
        guard infoCard.superview != nil else { return }
        infoCard.update(status: status, address: displayAddress(), port: port)
    }

    // MARK: - 状态 1

    private func showInfoState(animated: Bool) {
        swapCardContent(to: infoCard, animated: animated)
        infoCard.update(status: connectionStatus(), address: displayAddress(), port: port)
        startInfoProbe()
    }

    /// 「连接地址」的取值：优先真实在连的 host；取不到时（未登录 / 尚未
    /// 发起连接）pin 了就显示 pin 的 host，没 pin 就显示「自动（集群轮询）」。
    private func displayAddress() -> String {
        if let host = connectedHost() { return host }
        return pinnedHost() ?? "自动（集群轮询）"
    }

    private func startInfoProbe() {
        probeHandle?.cancel()
        probeHandle = nil
        // 未连接时不探测：那一行本就该显示占位，跑一次注定失败的探测只是
        // 让用户多等 2 秒看到「超时」。
        guard connectionStatus() != .disconnected, let host = connectedHost() ?? pinnedHost() else {
            infoCard.showLatencyPlaceholder()
            return
        }
        infoCard.updateLatency(nil)
        probeHandle = HostLatencyProbe.probeAll(hosts: [host], port: port) { [weak self] _, result in
            self?.infoCard.updateLatency(result)
        }
    }

    // MARK: - 状态 2（Task 7 填充）

    func showPickerState() {
        // Task 7 实现
    }

    // MARK: - 卡片内容切换

    private func swapCardContent(to content: UIView, animated: Bool) {
        let install = { [weak self] in
            guard let self else { return }
            self.cardView.subviews.forEach { $0.removeFromSuperview() }
            content.translatesAutoresizingMaskIntoConstraints = false
            self.cardView.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: self.cardView.topAnchor),
                content.leadingAnchor.constraint(equalTo: self.cardView.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: self.cardView.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: self.cardView.bottomAnchor),
            ])
        }
        guard animated else { return install() }
        UIView.transition(with: cardView, duration: 0.2, options: .transitionCrossDissolve) {
            install()
            self.cardView.layoutIfNeeded()
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
```

- [ ] **Step 3: `SceneDelegate` 接线**

在 `App/SceneDelegate.swift` 的 `private weak var conversationListViewController: ConversationListViewController?`（`:22`）之后加：

```swift
    /// 在场的连接服务弹窗。连接状态变化时要同步刷新它的状态 1，
    /// 与顶栏标题同源。
    private weak var presentedServerInfoViewController: ServerInfoViewController?
```

在 `makeMainTabBarController()` 里 `tabBarController.onPlusTapped = { ... }` 那一段之后加：

```swift
        // 点顶栏标题弹出连接服务弹窗。依赖全部按值/闭包传入，弹窗不认识
        // AppEnvironment。
        let serverNodes = environment.config.serverNodes
        tabBarController.onTitleTapped = { [weak self, weak tabBarController] in
            guard let self, let tabBarController else { return }
            let serverInfoViewController = ServerInfoViewController(
                nodes: serverNodes,
                port: self.environment.config.imPort,
                pinnedHost: { [weak self] in self?.environment.serverNodeStore.pinnedHost(nodes: serverNodes) },
                connectedHost: { [weak self] in self?.environment.connectedHost },
                connectionStatus: { [weak self] in self?.environment.connectionStatus ?? .disconnected },
                onSwitch: { [weak self] host in self?.environment.switchServerNode(pinnedHost: host) }
            )
            self.presentedServerInfoViewController = serverInfoViewController
            tabBarController.present(serverInfoViewController, animated: true)
        }
```

把 `applyConnectionStatus`（`:105`）的捕获列表与函数体改为同时刷新弹窗：

```swift
        let applyConnectionStatus: (IMConnectionStatus) -> Void = { [weak self, weak tabBarController] status in
            switch status {
            case .connected: tabBarController?.headerTitle = "飞享IM"
            case .connecting: tabBarController?.headerTitle = "飞享IM(正在连接...)"
            case .disconnected: tabBarController?.headerTitle = "飞享IM(连接断开)"
            }
            self?.presentedServerInfoViewController?.refreshStatus(status)
        }
```

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 提交**

```bash
git add App/ServerInfoCardView.swift App/ServerInfoViewController.swift App/SceneDelegate.swift
git commit -m "feat(App): 点顶栏标题弹出「当前连接服务」信息卡片"
```

---

## Task 7: 状态 2「选择连接服务」与节点切换

**Files:**
- Create: `App/ServerNodePickerView.swift`
- Modify: `App/ServerInfoViewController.swift`（`showPickerState()` 与探测生命周期）

**Interfaces:**
- Consumes: Task 6 的 `ServerInfoViewController` / `ServerLatencyFormatter`；Task 3 的 `HostLatencyProbe`；Task 1 的 `AppConfig.ServerNode`。
- Produces:
  - `ServerNodePickerView`：`init(nodes: [AppConfig.ServerNode], selectedHost: String?)`；`var onBackTapped: (() -> Void)?`；`var onConfirm: ((String?) -> Void)?`（`nil` = 自动）；`func updateLatency(_ result: HostLatencyProbe.ProbeResult, forHost host: String)`

- [ ] **Step 1: 写 `ServerNodePickerView`**

创建 `App/ServerNodePickerView.swift`：

```swift
// App/ServerNodePickerView.swift
import UIKit
import AppCore
import IMClient

/// 连接服务弹窗的状态 2：节点单选列表。纯展示 + 本地选中态，确认由
/// `onConfirm` 交回 `ServerInfoViewController`。
final class ServerNodePickerView: UIView {
    var onBackTapped: (() -> Void)?
    /// 传 nil 表示「自动（集群轮询）」。
    var onConfirm: ((String?) -> Void)?

    /// 当前选中的 host，nil = 自动。
    private var selectedHost: String?
    /// host → 该行的 view，供延迟结果回填。「自动」行不在其中。
    private var rowsByHost: [String: NodeRow] = [:]
    private let autoRow: NodeRow

    init(nodes: [AppConfig.ServerNode], selectedHost: String?) {
        self.selectedHost = selectedHost
        autoRow = NodeRow(title: "自动（集群轮询）", subtitle: "按集群顺序轮询", showsLatency: false)
        super.init(frame: .zero)

        let titleLabel = UILabel()
        titleLabel.text = "选择连接服务"
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary

        let metricHintLabel = UILabel()
        metricHintLabel.text = "建连耗时"
        metricHintLabel.font = .systemFont(ofSize: 12)
        metricHintLabel.textColor = Theme.textSecondary

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), metricHintLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8

        var rowViews: [UIView] = [autoRow]
        autoRow.onTapped = { [weak self] in self?.select(host: nil) }
        for node in nodes {
            let row = NodeRow(title: node.name, subtitle: node.host, showsLatency: true)
            row.onTapped = { [weak self] in self?.select(host: node.host) }
            rowsByHost[node.host] = row
            rowViews.append(row)
        }

        let listStack = UIStackView(arrangedSubviews: rowViews)
        listStack.axis = .vertical
        listStack.spacing = 0

        let backButton = Self.makeButton(title: "返回", primary: false)
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        let confirmButton = Self.makeButton(title: "确定", primary: true)
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        let buttonRow = UIStackView(arrangedSubviews: [backButton, confirmButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually

        let root = UIStackView(arrangedSubviews: [titleRow, listStack, buttonRow])
        root.axis = .vertical
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])

        applySelection()
        rowsByHost.values.forEach { $0.showLatencySpinner() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateLatency(_ result: HostLatencyProbe.ProbeResult, forHost host: String) {
        rowsByHost[host]?.showLatency(ServerLatencyFormatter.text(for: result))
    }

    private func select(host: String?) {
        selectedHost = host
        applySelection()
    }

    private func applySelection() {
        autoRow.isSelected = selectedHost == nil
        for (host, row) in rowsByHost {
            row.isSelected = host == selectedHost
        }
    }

    @objc private func backTapped() { onBackTapped?() }
    @objc private func confirmTapped() { onConfirm?(selectedHost) }

    private static func makeButton(title: String, primary: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = primary ? Theme.accent : Theme.backgroundSecondary
        button.setTitleColor(primary ? Theme.textOnAccent : Theme.textPrimary, for: .normal)
        button.layer.cornerRadius = Theme.cardCornerRadius
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }
}

/// 单选列表的一行：radio + 标题 + 灰色小字 + 行尾建连耗时（或转圈）。
private final class NodeRow: UIControl {
    var onTapped: (() -> Void)?

    override var isSelected: Bool {
        didSet { radioImageView.image = Self.radioImage(selected: isSelected) }
    }

    private let radioImageView = UIImageView()
    private let latencyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(title: String, subtitle: String, showsLatency: Bool) {
        super.init(frame: .zero)

        radioImageView.tintColor = Theme.accent
        radioImageView.contentMode = .scaleAspectFit
        radioImageView.translatesAutoresizingMaskIntoConstraints = false
        radioImageView.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15)
        titleLabel.textColor = Theme.textPrimary

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = Theme.textSecondary
        subtitleLabel.adjustsFontSizeToFitWidth = true
        subtitleLabel.minimumScaleFactor = 0.7

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        latencyLabel.font = .systemFont(ofSize: 14)
        latencyLabel.textColor = Theme.textSecondary
        latencyLabel.textAlignment = .right
        latencyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        spinner.hidesWhenStopped = true

        let trailingStack = UIStackView(arrangedSubviews: [spinner, latencyLabel])
        trailingStack.axis = .horizontal
        trailingStack.spacing = 4
        trailingStack.alignment = .center
        trailingStack.isHidden = !showsLatency

        let row = UIStackView(arrangedSubviews: [radioImageView, textStack, UIView(), trailingStack])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        isSelected = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showLatencySpinner() {
        latencyLabel.text = nil
        spinner.startAnimating()
    }

    func showLatency(_ text: String) {
        spinner.stopAnimating()
        latencyLabel.text = text
    }

    @objc private func handleTap() { onTapped?() }

    private static func radioImage(selected: Bool) -> UIImage? {
        UIImage(systemName: selected ? "largecircle.fill.circle" : "circle")
    }
}
```

- [ ] **Step 2: 在 `ServerInfoViewController` 里实现状态 2**

把 Task 6 留的空实现替换掉，并加一个 picker 的持有字段。在属性区 `private var probeHandle: ...` 之后加：

```swift
    /// 状态 2 的 view。首次进入状态 2 时创建，之后复用——弹窗要求两个状态
    /// 互切而不销毁重建。
    private var pickerView: ServerNodePickerView?
```

把 `showPickerState()` 整个替换为：

```swift
    func showPickerState() {
        let picker = pickerView ?? makePickerView()
        pickerView = picker
        swapCardContent(to: picker, animated: true)
        startPickerProbe(picker: picker)
    }

    private func makePickerView() -> ServerNodePickerView {
        let picker = ServerNodePickerView(nodes: nodes, selectedHost: pinnedHost())
        picker.onBackTapped = { [weak self] in self?.showInfoState(animated: true) }
        picker.onConfirm = { [weak self] host in
            guard let self else { return }
            // 选中项与当前项相同：直接回状态 1，不触发一次没必要的重连。
            if host != self.pinnedHost() {
                self.onSwitch(host)
            }
            self.showInfoState(animated: true)
        }
        return picker
    }

    private func startPickerProbe(picker: ServerNodePickerView) {
        probeHandle?.cancel()
        probeHandle = HostLatencyProbe.probeAll(hosts: nodes.map(\.host), port: port) { [weak picker] host, result in
            picker?.updateLatency(result, forHost: host)
        }
    }
```

`showInfoState(animated:)` 已经在 `startInfoProbe()` 里先 `probeHandle?.cancel()`，所以从状态 2 回到状态 1 时那批并发探测会被丢弃，无需额外处理。

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 全量单测不回归**

Run: `swift test --filter AppCoreTests && swift test --filter IMClientTests`
Expected: 两个目标全 PASS。

- [ ] **Step 5: 真机装机，交给用户验收**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008120-001945391147401E ~/Library/Developer/Xcode/DerivedData/ios-chat-pro-*/Build/Products/Debug-iphoneos/App.app
```

请用户逐项验收（**不要自己跑模拟器截图判定通过**）：

- 依次切换三个节点，每次顶栏状态回到「已连接」且能正常收发消息
- 快速连续切换 5 次以上，确认不崩
- 切换后杀进程重启，确认仍连在所选节点
- 改回「自动」后确认恢复轮询（连接地址回到 `sh-backend-tcp.fsharechat.cn`）
- 飞行模式下打开弹窗，确认显示「未连接」+ `——` 且界面不卡
- 深色 / 浅色模式下两个状态各截图核对配色

- [ ] **Step 6: 用户验收通过后提交**

```bash
git add App/ServerNodePickerView.swift App/ServerInfoViewController.swift
git commit -m "feat(App): 连接服务弹窗支持选择并固定 IM 节点"
```

---

## Self-Review 记录

**Spec 覆盖：**

| spec 章节 | 落点 |
| --- | --- |
| 入口（标题可点击，手势挂 label 不挂顶栏） | Task 5 Step 2 |
| 状态 1 的 5 行信息 + 状态色块 + 双按钮 | Task 6 Step 1 |
| 状态 2 单选列表 + 「建连耗时」小字 + 双按钮 | Task 7 Step 1 |
| 两状态互切不销毁重建 | Task 7 Step 2（`pickerView` 复用 + `swapCardContent`） |
| 深浅色 | Task 5 Step 1 的 token + 全部 view 只用 `Theme.*` |
| 连接地址的取值 + 三级兜底 | Task 2（`currentHost`）+ Task 4（`connectedHost`）+ Task 6 的 `displayAddress()` |
| 延迟指标 = TCP 建连耗时 | Task 3 |
| 节点固定语义（单 host = pin，全量串 = 自动） | Task 1 的 `currentHostSpec` |
| 持久化 + 下次启动沿用 | Task 1 + Task 4 的 `connectIfPossible()` 改动 |
| 失效 pin 降级为自动 | Task 1 `pinnedHost(nodes:)` |
| `switchHosts` 落定顺序 | Task 2 Step 3 |
| 不自动回退 | 无代码——不实现回退即是该行为；Task 7 Step 5 的验收项覆盖 |
| 选中项 == 当前项不重连 | Task 7 Step 2 的 `onConfirm` |
| 探测结果四种文案 | Task 6 Step 1 的 `ServerLatencyFormatter` |
| 弹窗关闭后丢弃回调 | Task 6 的 `viewDidDisappear` + `deinit` |
| 未连接显示 `——` 且不探测 | Task 6 的 `showLatencyPlaceholder()` + `startInfoProbe()` 守卫 |
| 未登录时 `switchServerNode` 只写持久化 | Task 4（`imClient?` 可选链）+ 对应测试 |

**类型一致性核对：** `HostLatencyProbe.ProbeResult` 在 Task 3 定义，Task 6（`ServerLatencyFormatter.text(for:)`、`ServerInfoCardView.updateLatency(_:)`）与 Task 7（`ServerNodePickerView.updateLatency(_:forHost:)`）用的是同一个名字。`AppConfig.ServerNode` 在 Task 1 定义，Task 4/6/7 一致。`pinnedHost(nodes:)` 在 Task 1、Task 4、Task 6 的 `SceneDelegate` 接线处签名一致。`switchHosts(_:)` 在 Task 2 定义、Task 4 调用。`ServerLatencyFormatter` 在 Task 6 与 Task 7 共用，两处文案口径因此天然一致。

**外部 API 核对：** `ManualScheduler.fireNext()`（`Sources/IMClient/Scheduler.swift:36`）、`FakeTransportConnection.simulate(_:)`/`cancelCallCount`/`startCallCount`（`Tests/IMClientTests/Support/FakeTransportConnection.swift`）、`AppEnvironmentTests` 的 `storage`/`credentialsStore`/`fakeTransport` 字段——均为已存在的 API，计划中的调用与它们的真实签名一致。

**并行性：** Task 1 / 2 / 3 互不依赖，可并行。Task 4 依赖 1、2；Task 5 独立；Task 6 依赖 1、3、4、5；Task 7 依赖 6。
