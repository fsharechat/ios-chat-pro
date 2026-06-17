import Foundation

/// Port of `cn.wildfirechat.proto.model.ConnectMessage` — the JSON body sent
/// with `Signal.CONNECT`. `willTopic`/`willMessage` are always empty in the
/// observed Android call site (`sendConnectMessage()` never sets them) but
/// are kept as real fields, not dropped, since the server's deserializer
/// may expect the key to be present.
public struct ConnectMessage: Encodable {
    public var clientIdentifier: String
    public var willTopic: String
    public var willMessage: String
    public var userName: String
    public var password: String

    public init(userName: String, password: String, clientIdentifier: String, willTopic: String = "", willMessage: String = "") {
        self.userName = userName
        self.password = password
        self.clientIdentifier = clientIdentifier
        self.willTopic = willTopic
        self.willMessage = willMessage
    }

    public func encodedJSONData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
