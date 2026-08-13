import Foundation
import Network
import IMClient
import IMStorage
import IMMessaging
import IMContacts
import IMMedia
import IMGroups
import IMCall

/// The app's dependency container: owns the long-lived `IMStorage`, and
/// constructs `IMClient`/`MessagingService`/`ConnectAckHandler` once
/// credentials are available.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue — by
/// convention the main queue.
public final class AppEnvironment {
    public let storage: IMStorage
    public let credentialsStore: CredentialsStore
    public let deviceIdentifierProvider: DeviceIdentifierProvider
    /// 用户固定的 IM 节点。挂在这里而非塞进 `AppConfig`，因为它是**用户
    /// 选择**（可变、持久化），`AppConfig` 是编译期常量配置。
    public let serverNodeStore: ServerNodeStore
    public let config: AppConfig
    private let transportFactory: (String, UInt16) -> IMTransportConnection

    public private(set) var imClient: IMClient?
    /// IM 连接状态变更中继，由 `SceneDelegate` 赋值。挂在 AppEnvironment 而非
    /// IMClient 上，因为退出重登会重建 IMClient，这个中继跨重建存活，
    /// `connectIfPossible()` 每次都会把新 client 的回调接到它上面。
    public var onConnectionStatusChange: ((IMConnectionStatus) -> Void)?
    /// 新消息提醒中继，由 `SceneDelegate` 赋值。挂在 AppEnvironment 而非
    /// MessagingService 上，理由与 `onConnectionStatusChange` 完全一致：
    /// 退出重登会重建 MessagingService，这个中继跨重建存活，
    /// `connectIfPossible()` 每次都会把新 service 的回调接到它上面。
    public var onIncomingMessageAlert: ((_ isMuted: Bool, _ isActiveConversation: Bool, _ isGroupNotification: Bool) -> Void)?
    /// 当前连接状态；未登录（imClient 为 nil）视为断开。UI 首次绑定时读它
    /// 拿初始值——`connectIfPossible()` 里 `connect()` 先于 UI 构建执行，
    /// 最初的 `.connecting` 事件发出时中继还没被赋值。
    public var connectionStatus: IMConnectionStatus { imClient?.connectionStatus ?? .disconnected }
    public private(set) var messagingService: MessagingService?
    public private(set) var contactSyncService: ContactSyncService?
    public private(set) var groupSyncService: GroupSyncService?
    public private(set) var userSettingSyncService: UserSettingSyncService?
    public private(set) var mediaUploadService: MediaUploadService?
    public private(set) var callManager: CallManager?
    /// Exposed separately from `callManager` because `CallViewController`
    /// needs the concrete `WebRTCClient` for its video renderers
    /// (`attachLocalRenderer`/`attachRemoteRenderer`) and mute/camera-switch
    /// controls — `CallManager` only sees it through the narrower
    /// `MediaEngine` protocol.
    public private(set) var webRTCClient: WebRTCClient?

    /// 监听系统网络路径：断网→有网的沿触发 `imClient?.reconnectIfNeeded()`。
    /// IMClient 的自动重连最多退避 4 次就停，且 TCP 静默断网不会有失败
    /// 回调——没有这个监听，网络恢复后连接永远不会自己回来。放在
    /// AppEnvironment 而非 IMClient 内部，是为了不给 IMClient 的单元测试
    /// 引入真实的系统网络依赖，也和 imClient 跨登出/重登的生命周期对齐。
    private let pathMonitor = NWPathMonitor()
    private var lastPathSatisfied: Bool?

    public init(
        config: AppConfig = .production,
        storage: IMStorage,
        credentialsStore: CredentialsStore = CredentialsStore(),
        deviceIdentifierProvider: DeviceIdentifierProvider = DeviceIdentifierProvider(),
        serverNodeStore: ServerNodeStore = ServerNodeStore(),
        transportFactory: @escaping (String, UInt16) -> IMTransportConnection = { host, port in
            NWConnectionTransport(host: host, port: port)
        }
    ) {
        self.config = config
        self.storage = storage
        self.credentialsStore = credentialsStore
        self.deviceIdentifierProvider = deviceIdentifierProvider
        self.serverNodeStore = serverNodeStore
        self.transportFactory = transportFactory
        credentialsStore.clearIfFreshInstall()
        // start(queue: .main) 让回调直接落在主队列，符合本类的单队列约定。
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let wasSatisfied = self.lastPathSatisfied
            self.lastPathSatisfied = satisfied
            // 只在"断网→有网"的沿触发：启动时的首个回调只记基线，
            // satisfied→satisfied 的路径抖动（如 Wi-Fi/蜂窝切换）不打扰
            // 在途连接——接口切换导致的旧连接失效由 viability 宽限路径兜底。
            guard satisfied, wasSatisfied == false else { return }
            self.imClient?.reconnectIfNeeded()
        }
        pathMonitor.start(queue: .main)
    }

    /// 回到前台时调用（`SceneDelegate.sceneWillEnterForeground`）：未连接
    /// 则立即重连（并重置 4 次退避计数），已连接则发一次心跳探活。iOS
    /// 后台 TCP 几乎必死，这是回前台最快的校验/恢复手段。未登录时 no-op。
    public func ensureConnected() {
        imClient?.reconnectIfNeeded()
    }

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

    /// Reads `credentialsStore`; if credentials exist, (re)constructs
    /// `IMClient`/`MessagingService`, wires the sync-state-driven catch-up
    /// pull (`ConnectAckHandler.onSyncState` →
    /// `MessagingService.pullMessagesSinceLastSync`), and calls `connect()`.
    /// Returns `false` if no credentials are stored — the caller should
    /// show the login screen in that case. Idempotent: calling this again
    /// after already connecting does nothing and returns `true`, since
    /// `LoginViewModel` already persisted credentials before invoking its
    /// `onLoginSucceeded` callback — the app-launch path and the post-login
    /// path both just call this same method.
    @discardableResult
    public func connectIfPossible() -> Bool {
        guard imClient == nil else { return true }
        guard let credentials = credentialsStore.load() else { return false }

        let configuration = IMClientConfiguration(
            hosts: serverNodeStore.currentHostSpec(nodes: config.serverNodes),
            port: config.imPort,
            userId: credentials.userId,
            token: credentials.token,
            clientIdentifier: deviceIdentifierProvider.currentIdentifier()
        )
        // `IMClient.init` 只在 host 串为空时抛错，而
        // `ServerNodeStore.currentHostSpec(nodes:)` 造不出空串：节点表非空 ⇒
        // 返回的 spec 必非空——`pinnedHost(nodes:)` 会拿节点表校验存下来的 pin，
        // 失效的 pin 直接降级成全量拼接串。所以把 throw 静默当成「连不上」、
        // 而不是给这个方法引一套专门的错误类型，是 Phase 1 认可的简化。
        guard let client = try? IMClient(configuration: configuration, transportFactory: transportFactory) else { return false }

        let service = MessagingService(imClient: client, storage: storage)
        let connectAckHandler = ConnectAckHandler()
        let contactSync = ContactSyncService(imClient: client, storage: storage)
        let groupSync = GroupSyncService(imClient: client, storage: storage)
        let userSettingSync = UserSettingSyncService(imClient: client, storage: storage)
        userSettingSync.onSavedGroupsResolved = { [weak groupSync] groupIds in
            for groupId in groupIds { groupSync?.refreshGroup(targetId: groupId) }
        }
        service.onGroupNotificationMessage = { [weak groupSync] groupId in groupSync?.refreshGroup(targetId: groupId) }
        service.onIncomingMessageAlert = { [weak self] isMuted, isActiveConversation, isGroupNotification in
            self?.onIncomingMessageAlert?(isMuted, isActiveConversation, isGroupNotification)
        }
        connectAckHandler.onSyncState = { [weak service, weak contactSync, weak userSettingSync, storage, userId = credentials.userId] state in
            // 服务端有设置且比本地新才拉。settingHead 为 0 表示服务端确实没有任何设置。
            let localSettingHead = (try? storage.syncState.get().settingHead) ?? 0
            if AppEnvironment.shouldPullUserSettings(serverSettingHead: state.settingHead, localSettingHead: localSettingHead) {
                userSettingSync?.syncUserSettings()
            }
            service?.pullMessagesSinceLastSync()
            contactSync?.syncFriendList()
            contactSync?.syncFriendRequests()
            contactSync?.fetchUserInfo(uids: [userId], forceRefresh: false)
        }
        client.register(connectAckHandler)
        client.onConnectionStatusChange = { [weak self] status in
            self?.onConnectionStatusChange?(status)
        }

        imClient = client
        messagingService = service
        contactSyncService = contactSync
        groupSyncService = groupSync
        userSettingSyncService = userSettingSync
        mediaUploadService = MediaUploadService(imClient: client)
        let webRTC = WebRTCClient(iceServers: config.iceServers.map { IceServer(urlString: $0.urlString, username: $0.username, credential: $0.credential) })
        webRTCClient = webRTC
        // `nowMillis` 用本机时间加上 `client.serverTimeDeltaMillis` 校正设备
        // 时钟漂移,对应 Android `AVEngineKit` 的 `serverDeltaTime` 用法 ——
        // 若设备时钟快 ≥90 秒且不校正,`CallManager` 的 90 秒来电新鲜度判断
        // 会让所有来电都被当成"过期"而永不弹窗(见 IMClient.serverTimeDeltaMillis
        // 的文档)。与上面 `myUserId` 一致地强捕获 `client`(局部 let,同一份
        // 引用已存在 `imClient` 里,不构成新的引用环)。
        callManager = CallManager(messagingService: service, storage: storage, mediaEngine: webRTC, myUserId: { client.userId }, myDeviceId: { client.clientIdentifier }, nowMillis: {
            Int64(Date().timeIntervalSince1970 * 1000) + client.serverTimeDeltaMillis
        })
        client.connect()
        return true
    }

    public func logOut() {
        imClient?.disconnect()
        imClient = nil
        messagingService = nil
        contactSyncService = nil
        groupSyncService = nil
        userSettingSyncService = nil
        mediaUploadService = nil
        callManager = nil
        webRTCClient = nil
        credentialsStore.clear()
        // Matches Android's `SqliteDatabaseStore.stop()` scope exactly
        // (see `IMStorage.clearSessionData()`'s doc comment) — `try?`
        // because logout must still proceed (disconnect/clear credentials
        // already happened above) even if this fails, e.g. disk full.
        try? storage.clearSessionData()
    }

    /// 决定 `connectIfPossible()` 收到 `CONNECT_ACK` 后是否要发 UG 拉用户设置。
    /// 服务端有设置且比本地新才拉；`serverSettingHead == 0` 且本地也是 0
    /// 表示服务端确实没有任何设置，不算「比本地新」。抽成独立函数是因为这是
    /// 整个恢复路径唯一的开关——写反或改成 `>=`/`!=` 会让 UG 静默永不发出，
    /// 而调用点原来嵌在一个大闭包里测不到。
    public static func shouldPullUserSettings(serverSettingHead: Int64, localSettingHead: Int64) -> Bool {
        serverSettingHead > localSettingHead
    }

    /// The on-disk path for `IMStorage`'s SQLite file: `<Application
    /// Support>/im.sqlite`, creating the parent directory if it doesn't
    /// exist yet (a fresh install has no Application Support directory).
    public static func defaultDatabasePath() -> String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("im.sqlite").path
    }
}
