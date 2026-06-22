import XCTest
import IMClient
import IMTransport
@testable import IMContacts

final class FriendRequestActionHandlerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: FriendRequestActionTracker!
    private var handler: FriendRequestActionHandler!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = FriendRequestActionTracker(scheduler: scheduler)
        handler = FriendRequestActionHandler(tracker: tracker)
    }

    private func makeFrame(subSignal: SubSignal, errorCode: UInt8) -> Frame {
        Frame(header: Header(signal: .pubAck, subSignal: subSignal, bodyLength: 1, messageId: 9), body: Data([errorCode]))
    }

    func test_canHandle_matchesPubAckFARAndFHR_butNothingElse() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .far))
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .fhr))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .us))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .far))
    }

    func test_handle_farSuccessBody_resolvesTrackerWithSuccess() {
        var captured: Result<Void, FriendRequestActionTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(subSignal: .far, errorCode: 0))

        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_handle_fhrSuccessBody_resolvesTrackerWithSuccess() {
        var captured: Result<Void, FriendRequestActionTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(subSignal: .fhr, errorCode: 0))

        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_handle_nonZeroErrorCode_resolvesTrackerWithServerError() {
        var captured: Result<Void, FriendRequestActionTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(subSignal: .far, errorCode: 6))

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .far, bodyLength: 0, messageId: 9), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
