import XCTest
import IMClient
import IMTransport
import Foundation
@testable import IMGroups

final class GroupCreateHandlerTests: XCTestCase {
    private var tracker: GroupCreateTracker!
    private var handler: GroupCreateHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tracker = GroupCreateTracker(scheduler: ManualScheduler())
        handler = GroupCreateHandler(tracker: tracker)
    }

    func test_canHandle_onlyMatchesPubAckAndGC() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .gc))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .gam))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .gc))
    }

    func test_handle_zeroErrorCode_resolvesWithGroupIdDecodedFromRawUTF8Bytes() {
        var result: Result<String, GroupCreateTracker.TrackerError>?
        tracker.track(wireMessageId: 1) { result = $0 }
        let body = Data([0x00]) + Data("g12345".utf8)

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gc, bodyLength: UInt32(body.count), messageId: 1), body: body))

        XCTAssertEqual(result, .success("g12345"))
    }

    func test_handle_nonZeroErrorCode_resolvesServerError() {
        var result: Result<String, GroupCreateTracker.TrackerError>?
        tracker.track(wireMessageId: 1) { result = $0 }

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gc, bodyLength: 1, messageId: 1), body: Data([0x01])))

        XCTAssertEqual(result, .failure(.serverError(errorCode: 1)))
    }

    func test_handle_zeroErrorCodeButEmptyTrailingBytes_resolvesMalformedResponse() {
        var result: Result<String, GroupCreateTracker.TrackerError>?
        tracker.track(wireMessageId: 1) { result = $0 }

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gc, bodyLength: 1, messageId: 1), body: Data([0x00])))

        XCTAssertEqual(result, .failure(.malformedResponse))
    }

    func test_handle_zeroErrorCodeButNonUTF8TrailingBytes_resolvesMalformedResponse() {
        var result: Result<String, GroupCreateTracker.TrackerError>?
        tracker.track(wireMessageId: 1) { result = $0 }
        let body = Data([0x00, 0xFF, 0xFE]) // 0x00 = success error code, 0xFF/0xFE = invalid UTF-8 trailing bytes

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gc, bodyLength: UInt32(body.count), messageId: 1), body: body))

        XCTAssertEqual(result, .failure(.malformedResponse))
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gc, bodyLength: 0, messageId: 1), body: Data()))
    }
}
