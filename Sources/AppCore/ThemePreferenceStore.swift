import Foundation

/// Manual theme choice (Phase 4 "设置/换肤"). Raw values are the on-disk
/// format — do not renumber existing cases.
public enum ThemeMode: Int, CaseIterable {
    case light = 0
    case dark = 1
    case system = 2
}

/// Persists the user's manual theme choice. `App`'s `SceneDelegate`/
/// `ThemeViewController` are the only readers/writers — `AppCore` itself
/// has no UIKit dependency, so the `ThemeMode` → `UIUserInterfaceStyle`
/// mapping lives in `App`.
///
/// **Threading contract:** safe to call from any queue — `UserDefaults`
/// serializes its own reads/writes internally, same as `DeviceIdentifierProvider`.
public final class ThemePreferenceStore {
    private static let key = "AppCore.themeMode"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var mode: ThemeMode {
        get {
            guard let stored = defaults.object(forKey: Self.key) as? Int else { return .system }
            return ThemeMode(rawValue: stored) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
