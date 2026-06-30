import IMClient
import IMTransport

/// Handles `PUB_ACK`/`MR` (subSignal 30) — the server's one-byte confirmation
/// that a recall request succeeded (errorCode == 0) or failed (errorCode != 0).
/// Mirrors `MessageSendAckHandler` but for recall: no messageUid/timestamp
/// in the response body, just a single error byte.
public final class RecallAckHandler: MessageHandler {
    /// Fired when an ack arrives. Arguments: wireMessageId, success (errorCode==0).
    var onAck: ((UInt16, Bool) -> Void)?

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .mr
    }

    public func handle(frame: Frame) {
        guard !frame.body.isEmpty else { return }
        let errorCode = frame.body[0]
        onAck?(frame.header.messageId, errorCode == 0)
    }
}
