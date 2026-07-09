import Foundation

/// Builds and parses QR-code payload strings — matches Android's
/// `WfcScheme.QR_CODE_PREFIX_*` exactly, so codes generated on either
/// platform scan correctly on the other.
public enum QRCodeContent {
    public enum ParsedQRCode: Equatable {
        case user(uid: String)
        case group(groupId: String)
    }

    private static let userPrefix = "wildfirechat://user/"
    private static let groupPrefix = "wildfirechat://group/"
    /// iOS releases before 2026-07 generated group codes as `group:<id>`.
    private static let legacyGroupPrefix = "group:"

    public static func userQRCodeString(uid: String) -> String {
        userPrefix + uid
    }

    public static func groupQRCodeString(groupId: String) -> String {
        groupPrefix + groupId
    }

    /// Returns nil for unrecognized content (pcsession/channel codes, plain
    /// text, …) — callers surface the raw string instead.
    public static func parse(_ raw: String) -> ParsedQRCode? {
        if let uid = value(of: raw, after: userPrefix) {
            return .user(uid: uid)
        }
        if let groupId = value(of: raw, after: groupPrefix) ?? value(of: raw, after: legacyGroupPrefix) {
            return .group(groupId: groupId)
        }
        return nil
    }

    private static func value(of raw: String, after prefix: String) -> String? {
        guard raw.hasPrefix(prefix) else { return nil }
        let value = String(raw.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}
