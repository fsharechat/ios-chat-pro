import Foundation

/// Builds the personal-QR-code payload string — matches Android's
/// `WfcScheme.QR_CODE_PREFIX_USER + uid` exactly, so a future scan-to-add-
/// friend feature on either platform can parse either's generated code.
public enum QRCodeContent {
    public static func userQRCodeString(uid: String) -> String {
        "wildfirechat://user/\(uid)"
    }
}
