import IMClient
import IMTransport

/// Parses the `PUB_ACK`/`MS` response to a sent message and resolves the
/// matching `OutgoingMessageTracker` entry. The body is **not** protobuf —
/// it's a hand-rolled binary format: 1 byte error code, then (only if
/// `errorCode == 0`) 8 bytes big-endian `Int64` `messageUid` + 8 bytes
/// big-endian `Int64` `timestamp`.
public final class MessageSendAckHandler: MessageHandler {
    private let tracker: OutgoingMessageTracker

    public init(tracker: OutgoingMessageTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .ms
    }

    public func handle(frame: Frame) {
        guard !frame.body.isEmpty else { return }
        let bytes = [UInt8](frame.body)
        let errorCode = bytes[0]
        if errorCode == 0, bytes.count >= 17 {
            let messageUid = Self.readBigEndianInt64(bytes, at: 1)
            let timestamp = Self.readBigEndianInt64(bytes, at: 9)
            tracker.resolve(wireMessageId: frame.header.messageId, result: .acked(messageUid: messageUid, timestamp: timestamp))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failed(errorCode: Int32(errorCode)))
        }
    }

    private static func readBigEndianInt64(_ bytes: [UInt8], at offset: Int) -> Int64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return Int64(bitPattern: value)
    }
}
