import XCTest
import IMClient
import IMTransport
@testable import IMMessaging

final class StreamingAiHandlerTests: XCTestCase {
    private func saiFrame(json: String) -> Frame {
        let body = Data(json.utf8)
        return Frame(header: Header(signal: .publish, subSignal: .sai, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    func test_canHandle_onlyMatchesPublishAndSAI() {
        let handler = StreamingAiHandler()
        XCTAssertTrue(handler.canHandle(signal: .publish, subSignal: .sai))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mn))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .sai))
    }

    func test_handle_parsesAllFourFields() {
        let handler = StreamingAiHandler()
        var captured: (String, String, Bool, String)?
        handler.onSaiToken = { captured = ($0, $1, $2, $3) }

        handler.handle(frame: saiFrame(json: #"{"i":"s1","d":"你好","f":false,"t":"agent"}"#))

        XCTAssertEqual(captured?.0, "s1")
        XCTAssertEqual(captured?.1, "你好")
        XCTAssertEqual(captured?.2, false)
        XCTAssertEqual(captured?.3, "agent")
    }

    func test_handle_doneTrue_isForwarded() {
        let handler = StreamingAiHandler()
        var capturedDone: Bool?
        handler.onSaiToken = { (_, _, done, _) in capturedDone = done }

        handler.handle(frame: saiFrame(json: #"{"i":"s1","d":"","f":true,"t":"agent"}"#))

        XCTAssertEqual(capturedDone, true)
    }

    func test_handle_missingField_isSilentlyDropped() {
        let handler = StreamingAiHandler()
        var invoked = false
        handler.onSaiToken = { _, _, _, _ in invoked = true }

        handler.handle(frame: saiFrame(json: #"{"i":"s1","d":"x","f":false}"#))

        XCTAssertFalse(invoked)
    }

    func test_handle_nonJSONBody_isSilentlyDropped() {
        let handler = StreamingAiHandler()
        var invoked = false
        handler.onSaiToken = { _, _, _, _ in invoked = true }

        handler.handle(frame: Frame(header: Header(signal: .publish, subSignal: .sai, bodyLength: 2, messageId: 1), body: Data([0xFF, 0xFE])))

        XCTAssertFalse(invoked)
    }
}
