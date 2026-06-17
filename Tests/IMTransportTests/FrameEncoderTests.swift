import XCTest
@testable import IMTransport

final class FrameEncoderTests: XCTestCase {
    func test_encodeThenDecodeRoundTripsThroughFrameDecoder() {
        let body = Data("{\"interval\":30000}".utf8)
        let wireBytes = FrameEncoder.encode(signal: .ping, subSignal: .none, messageId: 17, body: body)

        let decoder = FrameDecoder()
        let frames = decoder.feed(wireBytes)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].header.signal, .ping)
        XCTAssertEqual(frames[0].header.subSignal, .none)
        XCTAssertEqual(frames[0].header.messageId, 17)
        XCTAssertEqual(frames[0].body, body)
    }

    func test_encodedByteCountIsHeaderLengthPlusBodyLength() {
        let body = Data([1, 2, 3, 4, 5])
        let wireBytes = FrameEncoder.encode(signal: .publish, subSignal: .ms, messageId: 1, body: body)
        XCTAssertEqual(wireBytes.count, Header.length + body.count)
    }
}
