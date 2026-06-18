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
        SecItemDelete(query as CFDictionary)
    }
}
