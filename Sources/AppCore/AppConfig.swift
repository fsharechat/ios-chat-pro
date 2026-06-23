import Foundation

/// Server addresses. Defaults reuse the values already configured for the
/// existing Android client (`android-chat-pro`'s `Config.java`) — real,
/// currently-deployed addresses, not placeholders.
public struct AppConfig {
    public struct IceServer {
        public var urlString: String
        public var username: String
        public var credential: String

        public init(urlString: String, username: String, credential: String) {
            self.urlString = urlString
            self.username = username
            self.credential = credential
        }
    }

    public var apiBaseURL: URL
    public var imHosts: String
    public var imPort: UInt16
    public var iceServers: [IceServer]

    public init(apiBaseURL: URL, imHosts: String, imPort: UInt16, iceServers: [IceServer]) {
        self.apiBaseURL = apiBaseURL
        self.imHosts = imHosts
        self.imPort = imPort
        self.iceServers = iceServers
    }

    public static let production = AppConfig(
        apiBaseURL: URL(string: "https://backend-http.fsharechat.cn")!,
        imHosts: "backend-tcp.fsharechat.cn:backend-tcp-s2.fsharechat.cn",
        imPort: 6789,
        // Same TURN servers `android-chat-pro`'s `Config.java` already
        // points at in production — `chat-server-pro` plays no part in ICE
        // server distribution (see the Phase 3 design doc §3), so this is
        // the one place to change them later.
        iceServers: [
            IceServer(urlString: "turn:turn.fsharechat.cn:3478", username: "comsince", credential: "comsince"),
            IceServer(urlString: "turn:sh-turn.fsharechat.cn:3478", username: "comsince", credential: "comsince"),
        ]
    )
}
