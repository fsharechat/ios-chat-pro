import Foundation

/// Server addresses. Defaults reuse the values already configured for the
/// existing Android client (`android-chat-pro`'s `Config.java`) — real,
/// currently-deployed addresses, not placeholders.
public struct AppConfig {
    public var apiBaseURL: URL
    public var imHosts: String
    public var imPort: UInt16

    public init(apiBaseURL: URL, imHosts: String, imPort: UInt16) {
        self.apiBaseURL = apiBaseURL
        self.imHosts = imHosts
        self.imPort = imPort
    }

    public static let production = AppConfig(
        apiBaseURL: URL(string: "https://backend-http.fsharechat.cn")!,
        imHosts: "backend-tcp.fsharechat.cn:backend-tcp-s2.fsharechat.cn",
        imPort: 6789
    )
}
