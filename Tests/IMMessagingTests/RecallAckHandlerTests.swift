import XCTest
import IMClient
import IMTransport
@testable import IMMessaging

final class RecallAckHandlerTests: XCTestCase {
    private var handler: RecallAckHandler!

    override func setUp() {
        super.setUp()
        handler = RecallAckHandler()
    }

    func test_canHandle_onlyMatchesPubAckAndMR() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .mr))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .ms))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mr))
    }

    func test_handle_successBody_firesOnAckWithTrue() {
        var captured: (UInt16, Bool)?
        handler.onAck = { id, success in captured = (id, success) }

        let frame = Frame(
            header: Header(signal: .pubAck, subSignal: .mr, bodyLength: 1, messageId: 7),
            body: Data([0x00])
        )
        handler.handle(frame: frame)

        XCTAssertEqual(captured?.0, 7)
        XCTAssertEqual(captured?.1, true)
    }

    func test_handle_failureBody_firesOnAckWithFalse() {
        var captured: (UInt16, Bool)?
        handler.onAck = { id, success in captured = (id, success) }

        let frame = Frame(
            header: Header(signal: .pubAck, subSignal: .mr, bodyLength: 1, messageId: 7),
            body: Data([0x05])
        )
        handler.handle(frame: frame)

        XCTAssertEqual(captured?.0, 7)
        XCTAssertEqual(captured?.1, false)
    }

    func test_handle_emptyBody_doesNotCrash() {
        let frame = Frame(
            header: Header(signal: .pubAck, subSignal: .mr, bodyLength: 0, messageId: 1),
            body: Data()
        )
        handler.handle(frame: frame) // must not crash
    }
}
