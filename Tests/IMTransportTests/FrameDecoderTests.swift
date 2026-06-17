import XCTest
@testable import IMTransport

final class FrameDecoderTests: XCTestCase {
    private func makeFrameBytes(signal: Signal, subSignal: SubSignal, messageId: UInt16, body: [UInt8]) -> Data {
        let header = Header(signal: signal, subSignal: subSignal, bodyLength: UInt32(body.count), messageId: messageId)
        return header.encode() + Data(body)
    }

    func test_singleCompleteFrameInOneChunk() {
        let decoder = FrameDecoder()
        let bytes = makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: [0x7b, 0x7d]) // "{}"

        let frames = decoder.feed(bytes)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].header.signal, .ping)
        XCTAssertEqual(frames[0].body, Data([0x7b, 0x7d]))
    }

    func test_frameSplitAcrossManyChunksByteByByte() {
        let decoder = FrameDecoder()
        let bytes = makeFrameBytes(signal: .connect, subSignal: .none, messageId: 2, body: Array("hello".utf8))

        var collected: [Frame] = []
        for byte in bytes {
            collected += decoder.feed(Data([byte]))
        }

        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(collected[0].header.signal, .connect)
        XCTAssertEqual(collected[0].body, Data("hello".utf8))
    }

    func test_multipleCompleteFramesInOneChunk() {
        let decoder = FrameDecoder()
        var combined = makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: [0x01])
        combined.append(makeFrameBytes(signal: .pubAck, subSignal: .ms, messageId: 2, body: [0x02, 0x03]))
        combined.append(makeFrameBytes(signal: .disconnect, subSignal: .none, messageId: 3, body: []))

        let frames = decoder.feed(combined)

        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].header.messageId, 1)
        XCTAssertEqual(frames[1].header.signal, .pubAck)
        XCTAssertEqual(frames[1].body, Data([0x02, 0x03]))
        XCTAssertEqual(frames[2].header.signal, .disconnect)
        XCTAssertEqual(frames[2].body, Data())
    }

    func test_partialHeaderThenRestArrivesLater() {
        let decoder = FrameDecoder()
        let bytes = makeFrameBytes(signal: .auth, subSignal: .none, messageId: 9, body: [0xaa, 0xbb, 0xcc])

        let firstChunkFrames = decoder.feed(bytes.prefix(4))
        XCTAssertEqual(firstChunkFrames.count, 0)

        let secondChunkFrames = decoder.feed(bytes.suffix(from: 4))
        XCTAssertEqual(secondChunkFrames.count, 1)
        XCTAssertEqual(secondChunkFrames[0].body, Data([0xaa, 0xbb, 0xcc]))
    }

    func test_completeHeaderButPartialBodyThenRest() {
        let decoder = FrameDecoder()
        let bytes = makeFrameBytes(signal: .push, subSignal: .none, messageId: 4, body: Array(0..<20))

        let firstChunkFrames = decoder.feed(bytes.prefix(Header.length + 5))
        XCTAssertEqual(firstChunkFrames.count, 0)

        let secondChunkFrames = decoder.feed(bytes.suffix(from: Header.length + 5))
        XCTAssertEqual(secondChunkFrames.count, 1)
        XCTAssertEqual(secondChunkFrames[0].body, Data(Array(0..<20)))
    }

    func test_invalidMagicByteDropsBufferRatherThanLoopingForever() {
        let decoder = FrameDecoder()
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])

        let frames = decoder.feed(garbage)

        XCTAssertEqual(frames.count, 0)
        // decoder must have discarded the garbage, not be stuck waiting on it forever
        let nextFrames = decoder.feed(makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: []))
        XCTAssertEqual(nextFrames.count, 1)
    }
}
