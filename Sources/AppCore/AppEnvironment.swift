import Foundation
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
    public let config: AppConfig
    private let transportFactory: (String, UInt16) -> IMTransportConnection

    public private(set) var imClient: IMClient?
    public private(set) var messagingService: MessagingService?
    public private(set) var contactSyncService: ContactSyncService?
    public private(set) var groupSyncService: GroupSyncService?
    public private(set) var mediaUploadService: MediaUploadService?
    public private(set) var callManager: CallManager?
    /// Exposed separately from `callManager` because `CallViewController`
    /// needs the concrete `WebRTCClient` for its video renderers
    /// (`attachLocalRenderer`/`attachRemoteRenderer`) and mute/camera-switch
    /// controls — `CallManager` only sees it through the narrower
    /// `MediaEngine` protocol.
    public private(set) var webRTCClient: WebRTCClient?

    public init(
        config: AppConfig = .production,
        storage: IMStorage,
        credentialsStore: CredentialsStore = CredentialsStore(),
        deviceIdentifierProvider: DeviceIdentifierProvider = DeviceIdentifierProvider(),
        transportFactory: @escaping (String, UInt16) -> IMTransportConnection = { host, port in
            NWConnectionTransport(host: host, port: port)
        }
    ) {
        self.config = config
        self.storage = storage
        self.credentialsStore = credentialsStore
        self.deviceIdentifierProvider = deviceIdentifierProvider
        self.transportFactory = transportFactory
        credentialsStore.clearIfFreshInstall()
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
            hosts: config.imHosts,
            port: config.imPort,
            userId: credentials.userId,
            token: credentials.token,
            clientIdentifier: deviceIdentifierProvider.currentIdentifier()
        )
        // `IMClient.init` only throws if `config.imHosts` is malformed — a
        // fixed, already-verified value — so silently treating that as
        // "couldn't connect" rather than threading a dedicated error type
        // through this method is an accepted simplification for Phase 1.
        guard let client = try? IMClient(configuration: configuration, transportFactory: transportFactory) else { return false }

        let service = MessagingService(imClient: client, storage: storage)
        let connectAckHandler = ConnectAckHandler()
        let contactSync = ContactSyncService(imClient: client, storage: storage)
        let groupSync = GroupSyncService(imClient: client, storage: storage)
        service.onGroupNotificationMessage = { [weak groupSync] groupId in groupSync?.refreshGroup(targetId: groupId) }
        connectAckHandler.onSyncState = { [weak service, weak contactSync] _ in
            service?.pullMessagesSinceLastSync()
            contactSync?.syncFriendList()
            contactSync?.syncFriendRequests()
        }
        client.register(connectAckHandler)

        imClient = client
        messagingService = service
        contactSyncService = contactSync
        groupSyncService = groupSync
        mediaUploadService = MediaUploadService(imClient: client)
        let webRTC = WebRTCClient(iceServers: config.iceServers.map { IceServer(urlString: $0.urlString, username: $0.username, credential: $0.credential) })
        webRTCClient = webRTC
        callManager = CallManager(messagingService: service, storage: storage, mediaEngine: webRTC, myUserId: { client.userId })
        client.connect()
        return true
    }

    public func logOut() {
        imClient?.disconnect()
        imClient = nil
        messagingService = nil
        contactSyncService = nil
        groupSyncService = nil
        mediaUploadService = nil
        callManager = nil
        webRTCClient = nil
        credentialsStore.clear()
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
