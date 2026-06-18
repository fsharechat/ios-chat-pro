import IMProto
import IMTransport

public struct ConnectAckSyncState: Equatable {
    public let messageHead: Int64
    public let friendHead: Int64
    public let friendRequestHead: Int64
    public let settingHead: Int64
    public let serverTime: Int64

    public init(messageHead: Int64, friendHead: Int64, friendRequestHead: Int64, settingHead: Int64, serverTime: Int64) {
        self.messageHead = messageHead
        self.friendHead = friendHead
        self.friendRequestHead = friendRequestHead
        self.settingHead = settingHead
        self.serverTime = serverTime
    }
}

/// Parses `Im_ConnectAckPayload` off a CONNECT_ACK frame and surfaces the
/// sync-state sequence numbers. Does not persist anything itself — Plan C
/// (`IMStorage`) owns turning these into the actual incremental-sync calls.
public final class ConnectAckHandler: MessageHandler {
    public var onSyncState: ((ConnectAckSyncState) -> Void)?

    public init() {}

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .connectAck
    }

    public func handle(frame: Frame) {
        guard let payload = try? Im_ConnectAckPayload(serializedBytes: frame.body) else { return }
        onSyncState?(ConnectAckSyncState(
            messageHead: payload.msgHead,
            friendHead: payload.friendHead,
            friendRequestHead: payload.friendRqHead,
            settingHead: payload.settingHead,
            serverTime: payload.serverTime
        ))
    }
}
