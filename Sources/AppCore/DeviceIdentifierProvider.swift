import Foundation

/// Generates and persists a random per-install device id, used as
/// `IMClientConfiguration.clientIdentifier`. Mirrors Android's
/// `ClientService.getDeviceType`'s `mars_core_uid` persistence — iOS has no
/// hardware-identifier equivalent to Android ID, so this always generates a
/// fresh `UUID()` the first time, then persists and reuses it.
///
/// **No hyphens, deliberately:** this id is echoed back by the server as
/// the wire `bsId`, and `chat-server-pro`'s `PushUtil.pushMessageByBsId`
/// decides TCP-vs-WebSocket delivery by checking whether `bsId` contains a
/// `"-"` — a standard hyphenated `UUID().uuidString` would misclassify this
/// TCP client as a WebSocket one, silently misrouting every `PUB_ACK` sent
/// from a worker thread that doesn't already hold the connection's channel
/// context (friend list/message/friend-request pulls — but not
/// `CONNECT_ACK`/heartbeat, which are answered directly on the connection's
/// own I/O thread). Stripping the hyphens keeps a unique, stable id while
/// steering clear of that server-side check entirely.
///
/// **Threading contract:** safe to call from any queue — `UserDefaults`
/// serializes its own reads/writes internally, unlike most of this
/// codebase's no-internal-locking types.
public final class DeviceIdentifierProvider {
    private static let key = "AppCore.deviceIdentifier"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func currentIdentifier() -> String {
        if let existing = defaults.string(forKey: Self.key) {
            // Self-heals installs that persisted a hyphenated id before this
            // fix shipped, so they stop being misrouted on their very next
            // launch rather than only on a fresh install.
            guard existing.contains("-") else { return existing }
            let migrated = existing.replacingOccurrences(of: "-", with: "")
            defaults.set(migrated, forKey: Self.key)
            return migrated
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defaults.set(generated, forKey: Self.key)
        return generated
    }
}
