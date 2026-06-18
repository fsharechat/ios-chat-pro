import Foundation
import IMClient
import IMStorage
import IMMessaging

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
        connectAckHandler.onSyncState = { [weak service] syncState in
            service?.pullMessagesSinceLastSync(syncState: syncState)
        }
        client.register(connectAckHandler)

        imClient = client
        messagingService = service
        client.connect()
        return true
    }

    public func logOut() {
        imClient?.disconnect()
        imClient = nil
        messagingService = nil
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
