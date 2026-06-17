import Foundation

/// The fixed 10-byte frame header used by every message on the wire.
/// Byte-for-byte port of `com.comsince.github.push.Header`.
public struct Header: Equatable {
    public static let length = 10
    public static let magicByte: UInt8 = 0xf8
    public static let version: UInt8 = 2

    public let signal: Signal
    public let subSignal: SubSignal
    public let bodyLength: UInt32
    public let messageId: UInt16

    public init(signal: Signal, subSignal: SubSignal, bodyLength: UInt32, messageId: UInt16) {
        self.signal = signal
        self.subSignal = subSignal
        self.bodyLength = bodyLength
        self.messageId = messageId
    }

    public func encode() -> Data {
        var bytes = [UInt8](repeating: 0, count: Header.length)
        bytes[0] = Header.magicByte
        bytes[1] = Header.version
        bytes[2] = signal.rawValue
        bytes[3] = UInt8((bodyLength >> 24) & 0xff)
        bytes[4] = UInt8((bodyLength >> 16) & 0xff)
        bytes[5] = UInt8((bodyLength >> 8) & 0xff)
        bytes[6] = UInt8(bodyLength & 0xff)
        bytes[7] = subSignal.rawValue
        bytes[8] = UInt8((messageId >> 8) & 0xff)
        bytes[9] = UInt8(messageId & 0xff)
        return Data(bytes)
    }

    public static func decode(_ data: Data) -> Header? {
        guard data.count >= length else { return nil }
        let bytes = [UInt8](data.prefix(length))
        guard bytes[0] == magicByte else { return nil }
        guard let signal = Signal(rawValue: bytes[2] & 0x7f), signal != .none else { return nil }
        let subSignal = SubSignal(rawValue: bytes[7] & 0x7f) ?? .none
        let bodyLength = (UInt32(bytes[3]) << 24) | (UInt32(bytes[4]) << 16) | (UInt32(bytes[5]) << 8) | UInt32(bytes[6])
        let messageId = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        return Header(signal: signal, subSignal: subSignal, bodyLength: bodyLength, messageId: messageId)
    }
}
