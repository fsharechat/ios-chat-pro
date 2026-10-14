import XCTest
import IMClient
import IMProto
import IMTransport
@testable import IMMessaging

final class SpeechToTextAckHandlerTests: XCTestCase {
    private var handler: SpeechToTextAckHandler!
    private var captured: (UInt16, String?)?

    override func setUp() {
        super.setUp()
        handler = SpeechToTextAckHandler()
        captured = nil
        handler.onResult = { [weak self] id, text in self?.captured = (id, text) }
    }

    private func frame(_ body: Data) -> Frame {
        Frame(header: Header(signal: .pubAck, subSignal: .asr, bodyLength: UInt32(body.count), messageId: 9), body: body)
    }

    func test_canHandle_onlyPubAckAsr() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .asr))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .asr))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .mr))
    }

    func test_success_parsesText() throws {
        var result = Im_SpeechToTextResult()
        result.text = "你好"
        handler.handle(frame: frame(Data([0x00]) + (try result.serializedData())))

        XCTAssertEqual(captured?.0, 9)
        XCTAssertEqual(captured?.1, "你好")
    }

    func test_success_emptyText() throws {
        var result = Im_SpeechToTextResult()
        result.text = ""
        handler.handle(frame: frame(Data([0x00]) + (try result.serializedData())))

        XCTAssertEqual(captured?.1, "")
    }

    func test_errorCode_yieldsNil() {
        handler.handle(frame: frame(Data([0xF8])))

        XCTAssertEqual(captured?.0, 9)
        XCTAssertNil(captured?.1 ?? nil)
    }

    func test_emptyBody_doesNotCrash() {
        handler.handle(frame: frame(Data()))
        XCTAssertNil(captured)
    }
}
