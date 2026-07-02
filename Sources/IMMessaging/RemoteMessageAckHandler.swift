import Foundation
import IMClient
import IMTransport
import IMProto

/// Parses the `PUB_ACK`/`LRM` response to a remote-history request
/// (`MessagingService.loadRemoteMessages`). Like every `PUB_ACK` response,
/// the body is 1 byte error code followed by an `Im_PullMessageResult`
/// protobuf. The server returns messages in *descending* uid order (newest
/// first); this handler reverses them to ascending, exactly like Android's
/// `RemoteMessageHandler` does before handing them to the callback.
public final class RemoteMessageAckHandler: MessageHandler {
    /// Fired when a response arrives. Arguments: wireMessageId, messages in
    /// ascending order — `nil` when the server reported an error.
    var onResult: ((UInt16, [Im_Message]?) -> Void)?

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .lrm
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        guard errorCode == 0,
              let result = try? Im_PullMessageResult(serializedBytes: frame.body.dropFirst()) else {
            onResult?(frame.header.messageId, nil)
            return
        }
        onResult?(frame.header.messageId, result.message.reversed())
    }
}
