import XCTest
@testable import IMTransport

final class HeaderTests: XCTestCase {
    func test_encodeProducesExactByteLayout() {
        let header = Header(signal: .connect, subSignal: .none, bodyLength: 42, messageId: 7)
        let bytes = [UInt8](header.encode())

        XCTAssertEqual(bytes, [
            0xf8,       // magic
            0x02,       // version
            0x06,       // Signal.connect ordinal
            0x00, 0x00, 0x00, 0x2a, // bodyLength = 42, big-endian
            0x00,       // SubSignal.none ordinal
            0x00, 0x07, // messageId = 7, big-endian
        ])
    }

    func test_decodeIsInverseOfEncode() {
        let original = Header(signal: .publish, subSignal: .ms, bodyLength: 1234, messageId: 65000)
        let decoded = Header.decode(original.encode())

        XCTAssertEqual(decoded, original)
    }

    func test_messageIdAtUpperBound() {
        let header = Header(signal: .ping, subSignal: .none, bodyLength: 0, messageId: 65535)
        let bytes = [UInt8](header.encode())
        XCTAssertEqual(bytes[8], 0xff)
        XCTAssertEqual(bytes[9], 0xff)
        XCTAssertEqual(Header.decode(header.encode())?.messageId, 65535)
    }

    func test_decodeRejectsWrongMagicByte() {
        var bytes = [UInt8](Header(signal: .ping, subSignal: .none, bodyLength: 0, messageId: 1).encode())
        bytes[0] = 0x00
        XCTAssertNil(Header.decode(Data(bytes)))
    }

    func test_decodeRejectsTooShortData() {
        XCTAssertNil(Header.decode(Data([0xf8, 0x02, 0x06])))
    }

    func test_decodeRejectsNoneSignal() {
        var bytes = [UInt8](Header(signal: .ping, subSignal: .none, bodyLength: 0, messageId: 1).encode())
        bytes[2] = Signal.none.rawValue
        XCTAssertNil(Header.decode(Data(bytes)))
    }
}
