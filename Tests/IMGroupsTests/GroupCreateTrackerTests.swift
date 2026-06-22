import XCTest
import IMClient
@testable import IMGroups

final class GroupCreateTrackerTests: XCTestCase {
    func test_track_thenResolveSuccess_invokesCompletionWithGroupId() {
        let scheduler = ManualScheduler()
        let tracker = GroupCreateTracker(scheduler: scheduler)
        var result: Result<String, GroupCreateTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        tracker.resolve(wireMessageId: 1, result: .success("g1"))

        XCTAssertEqual(result, .success("g1"))
    }

    func test_track_thenResolveFailure_invokesCompletionWithServerError() {
        let scheduler = ManualScheduler()
        let tracker = GroupCreateTracker(scheduler: scheduler)
        var result: Result<String, GroupCreateTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        tracker.resolve(wireMessageId: 1, result: .failure(.serverError(errorCode: 2)))

        XCTAssertEqual(result, .failure(.serverError(errorCode: 2)))
    }

    func test_timeoutFires_resolvesAsTimeout() {
        let scheduler = ManualScheduler()
        let tracker = GroupCreateTracker(scheduler: scheduler)
        var result: Result<String, GroupCreateTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        scheduler.fireNext()

        XCTAssertEqual(result, .failure(.timeout))
    }
}
