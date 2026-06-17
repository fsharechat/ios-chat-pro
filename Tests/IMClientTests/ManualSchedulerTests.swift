import XCTest
@testable import IMClient

final class ManualSchedulerTests: XCTestCase {
    func test_scheduleOnce_recordsDelayButDoesNotFireImmediately() {
        let scheduler = ManualScheduler()
        var fired = false

        _ = scheduler.scheduleOnce(after: 5) { fired = true }

        XCTAssertFalse(fired)
        XCTAssertEqual(scheduler.scheduledDelays, [5])
    }

    func test_fireNext_runsTheOldestPendingActionOnce() {
        let scheduler = ManualScheduler()
        var order: [Int] = []

        _ = scheduler.scheduleOnce(after: 1) { order.append(1) }
        _ = scheduler.scheduleOnce(after: 2) { order.append(2) }

        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(order, [1])

        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(order, [1, 2])

        XCTAssertFalse(scheduler.fireNext()) // nothing left
    }

    func test_cancellingTokenPreventsItFromFiring() {
        let scheduler = ManualScheduler()
        var fired = false

        let token = scheduler.scheduleOnce(after: 1) { fired = true }
        token.cancel()

        XCTAssertFalse(scheduler.fireNext())
        XCTAssertFalse(fired)
    }
}
