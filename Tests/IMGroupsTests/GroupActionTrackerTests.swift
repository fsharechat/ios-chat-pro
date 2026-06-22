import XCTest
import IMClient
@testable import IMGroups

final class GroupActionTrackerTests: XCTestCase {
    func test_track_thenResolveSuccess_invokesCompletionWithSuccess() {
        let scheduler = ManualScheduler()
        let tracker = GroupActionTracker(scheduler: scheduler)
        var result: Result<Void, GroupActionTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        tracker.resolve(wireMessageId: 1, result: .success(()))

        switch result {
        case .success: break
        default: XCTFail("expected success, got \(String(describing: result))")
        }
    }

    func test_track_thenResolveFailure_invokesCompletionWithServerError() {
        let scheduler = ManualScheduler()
        let tracker = GroupActionTracker(scheduler: scheduler)
        var result: Result<Void, GroupActionTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        tracker.resolve(wireMessageId: 1, result: .failure(.serverError(errorCode: 5)))

        switch result {
        case .failure(.serverError(errorCode: 5)): break
        default: XCTFail("expected serverError(5), got \(String(describing: result))")
        }
    }

    func test_timeoutFires_resolvesAsTimeout() {
        let scheduler = ManualScheduler()
        let tracker = GroupActionTracker(scheduler: scheduler)
        var result: Result<Void, GroupActionTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        scheduler.fireNext()

        switch result {
        case .failure(.timeout): break
        default: XCTFail("expected timeout, got \(String(describing: result))")
        }
    }

    func test_resolve_forUntrackedId_isNoOp() {
        let scheduler = ManualScheduler()
        let tracker = GroupActionTracker(scheduler: scheduler)
        tracker.resolve(wireMessageId: 99, result: .success(())) // must not crash
    }
}
