import Foundation

/// Builds the on-the-wire bytes for a single message: header followed by body.
public enum FrameEncoder {
    public static func encode(signal: Signal, subSignal: SubSignal, messageId: UInt16, body: Data) -> Data {
        let header = Header(signal: signal, subSignal: subSignal, bodyLength: UInt32(body.count), messageId: messageId)
        return header.encode() + body
    }
}
