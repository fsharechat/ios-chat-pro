import XCTest
import IMClient
import IMTransport
import IMProto
@testable import IMMessaging

final class NotifyMessageHandlerTests: XCTestCase {
    func test_canHandle_onlyMatchesPublishAndMN() {
        let handler = NotifyMessageHandler()
        XCTAssertTrue(handler.canHandle(signal: .publish, subSignal: .mn))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mp))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .mn))
    }

    func test_handle_invokesOnNotify_withHeadMinusOneAndType() throws {
        let handler = NotifyMessageHandler()
        var captured: (Int64, Int32)?
        handler.onNotify = { head, type in captured = (head, type) }

        var notify = Im_NotifyMessage()
        notify.head = 100
        notify.type = 1
        let body = try notify.serializedData()
        let frame = Frame(header: Header(signal: .publish, subSignal: .mn, bodyLength: UInt32(body.count), messageId: 1), body: body)

        handler.handle(frame: frame)

        XCTAssertEqual(captured?.0, 99)
        XCTAssertEqual(captured?.1, 1)
    }

    func test_handle_malformedBody_doesNotCrashAndDoesNotInvokeCallback() {
        let handler = NotifyMessageHandler()
        var invoked = false
        handler.onNotify = { _, _ in invoked = true }

        handler.handle(frame: Frame(header: Header(signal: .publish, subSignal: .mn, bodyLength: 2, messageId: 1), body: Data([0xFF, 0xFF])))

        XCTAssertFalse(invoked)
    }
}
