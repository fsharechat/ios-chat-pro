import XCTest
import IMClient
import IMTransport
@testable import IMContacts

final class ProfileUpdateHandlerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: ProfileUpdateTracker!
    private var handler: ProfileUpdateHandler!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = ProfileUpdateTracker(scheduler: scheduler)
        handler = ProfileUpdateHandler(tracker: tracker)
    }

    private func makeFrame(errorCode: UInt8) -> Frame {
        Frame(header: Header(signal: .pubAck, subSignal: .mmi, bodyLength: 1, messageId: 9), body: Data([errorCode]))
    }

    func test_canHandle_matchesPubAckMMI_butNothingElse() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .mmi))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .us))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mmi))
    }

    func test_handle_successBody_resolvesTrackerWithSuccess() {
        var captured: Result<Void, ProfileUpdateTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(errorCode: 0))

        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_handle_nonZeroErrorCode_resolvesTrackerWithServerError() {
        var captured: Result<Void, ProfileUpdateTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(errorCode: 6))

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .mmi, bodyLength: 0, messageId: 9), body: Data()))
    }
}
