import XCTest
import IMClient
@testable import IMMessaging

final class OutgoingMessageTrackerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: OutgoingMessageTracker!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = OutgoingMessageTracker(scheduler: scheduler)
    }

    func test_resolve_afterTrack_invokesCompletionWithLocalMessageIdAndResult() {
        var captured: (Int64, OutgoingMessageTracker.SendResult)?
        tracker.track(wireMessageId: 7, localMessageId: 999) { localId, result in
            captured = (localId, result)
        }

        tracker.resolve(wireMessageId: 7, result: .acked(messageUid: 123, timestamp: 456))

        XCTAssertEqual(captured?.0, 999)
        switch captured?.1 {
        case .acked(let uid, let ts): XCTAssertEqual(uid, 123); XCTAssertEqual(ts, 456)
        default: XCTFail("expected .acked")
        }
    }

    func test_resolve_unknownWireMessageId_doesNothingNoCrash() {
        tracker.resolve(wireMessageId: 42, result: .acked(messageUid: 1, timestamp: 1)) // no track() call first — must not crash
    }

    func test_timeout_firesFailedCompletion_ifNoAckArrives() {
        var captured: OutgoingMessageTracker.SendResult?
        tracker.track(wireMessageId: 7, localMessageId: 999) { _, result in captured = result }

        XCTAssertEqual(scheduler.scheduledDelays, [5])
        XCTAssertTrue(scheduler.fireNext()) // simulates the 5s timeout firing

        switch captured {
        case .failed: break
        default: XCTFail("expected .failed")
        }
    }

    func test_resolve_beforeTimeoutFires_cancelsTheTimeout() {
        var completionCallCount = 0
        tracker.track(wireMessageId: 7, localMessageId: 999) { _, _ in completionCallCount += 1 }

        tracker.resolve(wireMessageId: 7, result: .acked(messageUid: 1, timestamp: 1))
        XCTAssertEqual(completionCallCount, 1)

        XCTAssertFalse(scheduler.fireNext()) // the timeout was cancelled, nothing left to fire
        XCTAssertEqual(completionCallCount, 1) // still only called once
    }
}
