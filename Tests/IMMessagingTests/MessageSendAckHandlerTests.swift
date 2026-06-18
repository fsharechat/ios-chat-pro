import XCTest
import IMClient
import IMTransport
@testable import IMMessaging

final class MessageSendAckHandlerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: OutgoingMessageTracker!
    private var handler: MessageSendAckHandler!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = OutgoingMessageTracker(scheduler: scheduler)
        handler = MessageSendAckHandler(tracker: tracker)
    }

    private func bigEndianInt64Bytes(_ value: Int64) -> [UInt8] {
        let unsigned = UInt64(bitPattern: value)
        return (0..<8).map { UInt8((unsigned >> (8 * (7 - $0))) & 0xFF) }
    }

    func test_canHandle_onlyMatchesPubAckAndMS() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .ms))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .mp))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .ms))
    }

    func test_handle_successBody_resolvesTrackerWithAckedUidAndTimestamp() {
        var captured: OutgoingMessageTracker.SendResult?
        tracker.track(wireMessageId: 9, localMessageId: 555) { _, result in captured = result }

        var body: [UInt8] = [0x00] // error code 0 = success
        body += bigEndianInt64Bytes(123_456)
        body += bigEndianInt64Bytes(789)
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .ms, bodyLength: UInt32(body.count), messageId: 9), body: Data(body))

        handler.handle(frame: frame)

        switch captured {
        case .acked(let uid, let ts):
            XCTAssertEqual(uid, 123_456)
            XCTAssertEqual(ts, 789)
        default:
            XCTFail("expected .acked, got \(String(describing: captured))")
        }
    }

    func test_handle_failureBody_resolvesTrackerWithFailedErrorCode() {
        var captured: OutgoingMessageTracker.SendResult?
        tracker.track(wireMessageId: 9, localMessageId: 555) { _, result in captured = result }

        let frame = Frame(header: Header(signal: .pubAck, subSignal: .ms, bodyLength: 1, messageId: 9), body: Data([0x06]))

        handler.handle(frame: frame)

        switch captured {
        case .failed(let code): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failed, got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .ms, bodyLength: 0, messageId: 9), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
