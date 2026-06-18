import Foundation

/// Generates and persists a random per-install device id, used as
/// `IMClientConfiguration.clientIdentifier`. Mirrors Android's
/// `ClientService.getDeviceType`'s `mars_core_uid` persistence — iOS has no
/// hardware-identifier equivalent to Android ID, so this always generates a
/// fresh `UUID()` the first time, then persists and reuses it.
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
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Self.key)
        return generated
    }
}
