import XCTest
import IMClient
import IMProto
@testable import IMMedia

final class MinioUploadURLTrackerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: MinioUploadURLTracker!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = MinioUploadURLTracker(scheduler: scheduler)
    }

    private func makeResult(url: String) -> Im_GetMinioUploadUrlResult {
        var result = Im_GetMinioUploadUrlResult()
        result.domain = "https://media.example.com"
        result.url = url
        return result
    }

    func test_resolve_afterTrack_invokesCompletionWithSuccess() {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .success(makeResult(url: "https://put.example.com/presigned")))

        switch captured {
        case .success(let result): XCTAssertEqual(result.url, "https://put.example.com/presigned")
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_resolve_withFailure_invokesCompletionWithFailure() {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .failure(.serverError(errorCode: 6)))

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_resolve_unknownWireMessageId_doesNothingNoCrash() {
        tracker.resolve(wireMessageId: 42, result: .success(makeResult(url: "https://put.example.com/x"))) // no track() call first
    }

    func test_timeout_firesFailureWithTimeoutError_ifNoResponseArrives() {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
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

        tracker.resolve(wireMessageId: 7, result: .success(makeResult(url: "https://put.example.com/x")))
        XCTAssertEqual(completionCallCount, 1)

        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(completionCallCount, 1)
    }
}
