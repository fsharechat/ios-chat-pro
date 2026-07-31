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

    /// 一个可选的 IM 接入节点。`name` 是给用户看的中文名（连接服务弹窗的
    /// 单选列表用它），`host` 是实际连接地址。数组顺序即
    /// `RoundRobinHostSelector` 的轮询顺序，首位就是首选节点。
    public struct ServerNode: Equatable {
        public var name: String
        public var host: String

        public init(name: String, host: String) {
            self.name = name
            self.host = host
        }
    }

    public var apiBaseURL: URL
    public var serverNodes: [ServerNode]
    public var imPort: UInt16
    public var iceServers: [IceServer]

    /// 全部节点 host 的 `:` 拼接串——`RoundRobinHostSelector` 与
    /// `AboutViewController` 沿用的既有格式。由 `serverNodes` 派生而非
    /// 单独存储，避免节点表与拼接串两处失同步。
    public var imHosts: String { serverNodes.map(\.host).joined(separator: ":") }

    public init(apiBaseURL: URL, serverNodes: [ServerNode], imPort: UInt16, iceServers: [IceServer]) {
        self.apiBaseURL = apiBaseURL
        self.serverNodes = serverNodes
        self.imPort = imPort
        self.iceServers = iceServers
    }

    public static let production = AppConfig(
        apiBaseURL: URL(string: "https://backend-http.fsharechat.cn")!,
        serverNodes: [
            ServerNode(name: "上海节点", host: "sh-backend-tcp.fsharechat.cn"),
            ServerNode(name: "主节点", host: "backend-tcp.fsharechat.cn"),
            ServerNode(name: "备节点 S2", host: "backend-tcp-s2.fsharechat.cn"),
        ],
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
