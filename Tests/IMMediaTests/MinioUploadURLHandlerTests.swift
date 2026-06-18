import XCTest
import IMClient
import IMTransport
import IMProto
@testable import IMMedia

final class MinioUploadURLHandlerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: MinioUploadURLTracker!
    private var handler: MinioUploadURLHandler!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = MinioUploadURLTracker(scheduler: scheduler)
        handler = MinioUploadURLHandler(tracker: tracker)
    }

    private func makeFrame(errorCode: UInt8, domain: String = "", url: String = "") throws -> Frame {
        var result = Im_GetMinioUploadUrlResult()
        result.domain = domain
        result.url = url
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .gmurl, bodyLength: UInt32(body.count), messageId: 9), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndGMURL() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .gmurl))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .fp))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .gmurl))
    }

    func test_handle_successBody_resolvesTrackerWithResult() throws {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let frame = try makeFrame(errorCode: 0, domain: "https://media.example.com", url: "https://put.example.com/presigned")
        handler.handle(frame: frame)

        switch captured {
        case .success(let result):
            XCTAssertEqual(result.domain, "https://media.example.com")
            XCTAssertEqual(result.url, "https://put.example.com/presigned")
        default:
            XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_handle_nonZeroErrorCode_resolvesTrackerWithServerError() throws {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let frame = try makeFrame(errorCode: 6)
        handler.handle(frame: frame)

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .gmurl, bodyLength: 0, messageId: 9), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
