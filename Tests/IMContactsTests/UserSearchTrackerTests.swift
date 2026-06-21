import XCTest
import IMClient
@testable import IMContacts

final class UserSearchTrackerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: UserSearchTracker!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = UserSearchTracker(scheduler: scheduler)
    }

    func test_resolve_afterTrack_invokesCompletionWithSuccess() {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .success(["u1", "u2"]))

        switch captured {
        case .success(let uids): XCTAssertEqual(uids, ["u1", "u2"])
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_resolve_withFailure_invokesCompletionWithFailure() {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .failure(.serverError(errorCode: 6)))

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_resolve_unknownWireMessageId_doesNothingNoCrash() {
        tracker.resolve(wireMessageId: 42, result: .success(["u1"])) // no track() call first
    }

    func test_timeout_firesFailureWithTimeoutError_ifNoResponseArrives() {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        XCTAssertEqual(scheduler.scheduledDelays, [5])
        XCTAssertTrue(scheduler.fireNext())

        switch captured {
        case .failure(.timeout): break
        default: XCTFail("expected .failure(.timeout), got \(String(describing: captured))")
        }
    }

    func test_resolve_beforeTimeoutFires_cancelsTheTimeout() {
        var completionCallCount = 0
        tracker.track(wireMessageId: 7) { _ in completionCallCount += 1 }

        tracker.resolve(wireMessageId: 7, result: .success(["u1"]))
        XCTAssertEqual(completionCallCount, 1)

        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(completionCallCount, 1)
    }
}
