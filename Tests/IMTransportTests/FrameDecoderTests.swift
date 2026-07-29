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

    func test_partialBodyReportsProgressWithItsAlreadyKnownHeader() {
        let decoder = FrameDecoder()
        var progress: [(Header, Int)] = []
        decoder.onPartialFrameProgress = { progress.append(($0, $1)) }
        let bytes = makeFrameBytes(signal: .pubAck, subSignal: .lrm, messageId: 161, body: Array(repeating: 0xab, count: 100))

        _ = decoder.feed(bytes.prefix(Header.length + 30))
        _ = decoder.feed(bytes[(Header.length + 30)..<(Header.length + 70)])

        // 帧头一到,signal/subSignal/messageId 就已可用——上层正是靠这个把
        // 进度归属到自己发出的那一笔请求上。
        XCTAssertEqual(progress.map(\.1), [30, 70])
        XCTAssertEqual(progress.map(\.0.messageId), [161, 161])
        XCTAssertEqual(progress.map(\.0.subSignal), [.lrm, .lrm])
    }

    func test_completeFrameReportsNoPartialProgress() {
        let decoder = FrameDecoder()
        var progressCallCount = 0
        decoder.onPartialFrameProgress = { _, _ in progressCallCount += 1 }

        _ = decoder.feed(makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: [0x01]))

        XCTAssertEqual(progressCallCount, 0)
    }

    func test_resetDiscardsHalfReceivedFrameSoNextStreamDecodesCleanly() {
        let decoder = FrameDecoder()
        let cutOff = makeFrameBytes(signal: .pubAck, subSignal: .lrm, messageId: 7, body: Array(repeating: 0xcd, count: 50))
        _ = decoder.feed(cutOff.prefix(Header.length + 20)) // 连接在这里断了,半帧留在 buffer 里

        decoder.reset()

        // 没有 reset 的话,残留的 20 字节会被顶到新帧前面,把新字节流整个错位。
        let frames = decoder.feed(makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: [0x02]))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].body, Data([0x02]))
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

    func test_feedingEmptyDataReturnsNoFramesAndPreservesState() {
        let decoder = FrameDecoder()
        let bytes = makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: [0x01])

        let firstHalf = decoder.feed(bytes.prefix(3))
        XCTAssertEqual(firstHalf.count, 0)

        let emptyFeedFrames = decoder.feed(Data())
        XCTAssertEqual(emptyFeedFrames.count, 0)

        let rest = decoder.feed(bytes.suffix(from: 3))
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest[0].body, Data([0x01]))
    }

    func test_twoFramesSplitByteByByteAcrossTheirSharedBoundary() {
        let decoder = FrameDecoder()
        var combined = makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: [0xaa])
        combined.append(makeFrameBytes(signal: .pubAck, subSignal: .ms, messageId: 2, body: [0xbb, 0xcc]))

        var collected: [Frame] = []
        for byte in combined {
            collected += decoder.feed(Data([byte]))
        }

        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected[0].header.signal, .ping)
        XCTAssertEqual(collected[0].body, Data([0xaa]))
        XCTAssertEqual(collected[1].header.signal, .pubAck)
        XCTAssertEqual(collected[1].body, Data([0xbb, 0xcc]))
    }
}
