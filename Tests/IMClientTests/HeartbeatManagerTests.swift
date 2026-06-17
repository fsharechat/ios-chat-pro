import XCTest
@testable import IMClient

private struct FixedRandomSource: RandomSource {
    let values: [Int]
    private var index = 0
    init(_ values: [Int]) { self.values = values }
    mutating func nextInt(upperBound: Int) -> Int {
        let value = values[index % values.count]
        index += 1
        return value
    }
}

final class HeartbeatManagerTests: XCTestCase {
    func test_initialInterval_isMinHeartbeatInterval() {
        let manager = HeartbeatManager()
        XCTAssertEqual(manager.currentHeartInterval(), 30_000)
    }

    func test_reportException_equalValueProbeFailure_subtractsOneStep() {
        let manager = HeartbeatManager(isNightModeProvider: { false })
        manager.reportHeartbeatScheduleTime(1_000)
        // exceptionTime - scheduleTime == currentMaxHeartbeatInterval (30_000) exactly => diff 0 => absDiff(0) < 2*step(10_000)
        manager.reportHeartbeatExceptionTime(1_000 + 30_000)

        XCTAssertEqual(manager.currentHeartInterval(), 25_000) // 30_000 - ONE_STEP_INTERVAL(5_000)
    }

    func test_reportException_midRangeAbsDiff_subtractsHalfTheDiff() {
        let manager = HeartbeatManager(isNightModeProvider: { false })
        // scheduleTime must be non-zero: both `currentScheduleTime` and `currentSendSuccessTime`
        // default to 0, and the Java guards treat 0 as "never scheduled" (`currentScheduleTime != 0`).
        // Passing literal 0 here would make reportHeartbeatExceptionTime's adjustment block a silent
        // no-op — every test below uses a non-zero schedule time for the same reason.
        manager.reportHeartbeatScheduleTime(1_000)
        // interval = 46_000 - 1_000 = 45_000; diff = 45_000-30_000=15_000; absDiff=15_000 is in [2*5000,4*5000)=[10_000,20_000), so this lands in the "subtract absDiff/2" branch.
        manager.reportHeartbeatExceptionTime(1_000 + 45_000)

        XCTAssertEqual(manager.currentHeartInterval(), 30_000 - 15_000 / 2) // 22_500
    }

    func test_reportException_largeAbsDiff_disablesUpSearchingAndSubtractsFourSteps() {
        let manager = HeartbeatManager(isNightModeProvider: { false })
        manager.reportHeartbeatScheduleTime(1_000)
        // interval = 100_000; diff = 100_000 - 30_000 = 70_000, which is >= 12*5_000=60_000
        // => disableUpSearchingMaxInterval=true, subtract 4*step=20_000 => 30_000-20_000=10_000,
        // which is then floor-clamped back up to MIN_HEARTBEAT_INTERVAL since 10_000 < 15_000.
        // (The intermediate 10_000 is never observable through the public API — only the final,
        // fully-clamped value is — so there is exactly one assertion here, not two.)
        manager.reportHeartbeatExceptionTime(1_000 + 100_000)

        XCTAssertEqual(manager.currentHeartInterval(), HeartbeatManager.minHeartbeatInterval) // 30_000
    }

    func test_reportException_resultBelowFifteenSeconds_resetsToMinInterval() {
        let manager = HeartbeatManager(isNightModeProvider: { false })
        manager.reportHeartbeatScheduleTime(1_000)
        manager.reportHeartbeatExceptionTime(1_000 + 100_000) // same large-abs-diff path as above: drives currentMaxHeartbeatInterval to 10_000, below the 15_000 floor

        XCTAssertEqual(manager.currentHeartInterval(), HeartbeatManager.minHeartbeatInterval)
    }

    func test_reportException_resultAboveDayMax_clampsToDayMax() throws {
        let manager = HeartbeatManager(
            random: FixedRandomSource([0]),
            isNightModeProvider: { false }
        )
        manager.reportHeartbeatScheduleTime(1_000)
        // interval = 90_000; diff = interval - currentMaxHeartbeatInterval(30_000) = 60_000, which is
        // in (0, 90_000) so recalculateMaxHeartbeatInterval's adjustment runs (note: the guard checks
        // `diff`, the *gap from the current max*, not `interval` directly). Since upSearchingMaxInterval
        // is still true (the default), currentMaxHeartbeatInterval is set to `interval` (90_000) and then
        // immediately clamped down to the day ceiling (60_000) because 90_000 > maxHeartBeatInterval().
        manager.reportHeartbeatSendSuccessTime(1_000 + 90_000)

        // currentHeartInterval() reads currentHeartbeatInterval/tempHeartbeatInterval, neither of which
        // recalculateMaxHeartbeatInterval() touches directly — only nextHeartbeatInterval() (or
        // reportHeartbeatExceptionTime) syncs currentHeartbeatInterval from currentMaxHeartbeatInterval.
        // upSearchingMaxInterval is still true and currentHeartbeatIntervalSuccessNum is still 0, so this
        // call takes the else-branch, syncs currentHeartbeatInterval = currentMaxHeartbeatInterval (60_000),
        // then immediately falls into the "at or above max" branch (60_000 >= maxHeartBeatInterval()=60_000)
        // and returns a jittered value — with FixedRandomSource([0]), randomInt=0, so the jitter is exactly 60_000.
        let result = manager.nextHeartbeatInterval()
        XCTAssertEqual(result, 60_000)
        XCTAssertEqual(manager.currentHeartInterval(), 60_000)
    }

    func test_nextHeartbeatInterval_upSearchingIncrementsAfterEnoughConsecutiveCalls() {
        let manager = HeartbeatManager(isNightModeProvider: { false })
        // currentHeartbeatInterval starts at 30_000, ONE_STEP_INTERVAL=5_000 => maxSuccessTime=6.
        // The else-branch increments currentHeartbeatIntervalSuccessNum each call; only once it exceeds
        // maxSuccessTime(6) does the up-searching branch fire and add one step. That takes 7 calls
        // landing on the else-branch (successNum 1..7) before the 8th call sees successNum(7) > 6.
        var lastInterval: Int64 = 0
        for _ in 0..<7 {
            lastInterval = manager.nextHeartbeatInterval()
        }
        XCTAssertEqual(lastInterval, 30_000) // still at the base interval through the 7th call

        let eighthInterval = manager.nextHeartbeatInterval()
        XCTAssertEqual(eighthInterval, 35_000) // stepped up by ONE_STEP_INTERVAL
    }

    func test_nextHeartbeatInterval_atOrAboveMax_returnsRandomJitterNearMax() {
        let manager = HeartbeatManager(
            random: FixedRandomSource([2]), // pick index 2 of [0, 60_000/5_000=12) => randomInt=2
            isNightModeProvider: { false }
        )
        // Force currentHeartbeatInterval to the day max (60_000) via the internal test seam, rather than
        // driving dozens of calls through the public API just to reach this corner of the state space.
        manager.setStateForTesting(currentHeartbeatInterval: 60_000, currentMaxHeartbeatInterval: 60_000, upSearchingMaxInterval: true, currentHeartbeatIntervalSuccessNum: 0)

        let interval = manager.nextHeartbeatInterval()

        // maxHeartBeatInterval()=60_000, randomInt=2 => 60_000 - 2*5_000 = 50_000
        XCTAssertEqual(interval, 50_000)
    }

    func test_nightMode_usesTwoMinuteCeilingInsteadOfOneMinute() {
        let manager = HeartbeatManager(isNightModeProvider: { true })
        manager.setStateForTesting(currentHeartbeatInterval: 130_000, currentMaxHeartbeatInterval: 130_000, upSearchingMaxInterval: false, currentHeartbeatIntervalSuccessNum: 0)
        manager.reportHeartbeatScheduleTime(0)
        manager.reportHeartbeatExceptionTime(1) // any failure path re-clamps against maxHeartBeatInterval()

        XCTAssertEqual(manager.currentHeartInterval(), 120_000) // night ceiling, not the 60_000 day ceiling
    }
}
