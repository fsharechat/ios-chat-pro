import Foundation
import Security

public struct Credentials: Equatable {
    public let userId: String
    public let token: String

    public init(userId: String, token: String) {
        self.userId = userId
        self.token = token
    }
}

/// Keychain-backed storage for the logged-in `userId`/`token` pair. Stored
/// as a single `kSecClassGenericPassword` item (the password payload is
/// `"\(userId)|\(token)"` — `userId`s never contain `"|"` per
/// `chat-server-pro`'s mobile/email-derived id format, so this is an
/// unambiguous, good-enough encoding without reaching for JSON).
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue — by
/// convention the main queue (unlike `DeviceIdentifierProvider`'s
/// `UserDefaults` backing, `SecItem*` Keychain calls are not internally
/// thread-safe across concurrent callers).
public final class CredentialsStore {
    private let service: String
    private static let account = "credentials"

    public init(service: String = "com.fshare.ios-chat-pro.credentials") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func save(_ credentials: Credentials) {
        let payload = Data("\(credentials.userId)|\(credentials.token)".utf8)
        // Status codes intentionally not checked: a rare Keychain-quota/
        // permission failure would silently no-op rather than surface an
        // error — accepted for Phase 1 since there's no logging facility
        // yet, the same accepted gap documented in `ReceiveMessageHandler`'s
        // persist method and `MessagingService`'s send method.
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = payload
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public func load() -> Credentials? {
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let payload = String(data: data, encoding: .utf8) else {
            return nil
        }
        let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return Credentials(userId: parts[0], token: parts[1])
    }

    public func clear() {
        // Status code intentionally not checked — same accepted gap as in `save()` above.
        SecItemDelete(query as CFDictionary)
    }

    private static let hasLaunchedKey = "AppCore.CredentialsStore.hasLaunchedBefore"

    /// Keychain items outlive app deletion on iOS — only `UserDefaults` and
    /// the app's container (including `IMStorage`'s sqlite file) are wiped
    /// on uninstall. Without this, a fresh install would silently reuse a
    /// previous install's leftover token and skip straight past the login
    /// screen. `hasLaunchedKey` lives in `UserDefaults`, so it reads back
    /// `false` exactly once per install — the first launch after install —
    /// at which point any stale Keychain credentials are cleared before
    /// anything else gets a chance to read them.
    public func clearIfFreshInstall(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.hasLaunchedKey) else { return }
        clear()
        defaults.set(true, forKey: Self.hasLaunchedKey)
    }
}
