import Foundation

/// Mirrors `java.util.Random#nextInt(int)`'s contract: a value in `[0, upperBound)`.
/// `mutating` because the real system source advances PRNG state; the test
/// double below also needs to advance an index, so both conform the same way.
public protocol RandomSource {
    mutating func nextInt(upperBound: Int) -> Int
}

public struct SystemRandomSource: RandomSource {
    public init() {}
    public mutating func nextInt(upperBound: Int) -> Int {
        Int.random(in: 0..<upperBound)
    }
}

/// Byte-for-byte port of `cn.wildfirechat.proto.HeartbeatManager`'s adaptive
/// heartbeat-interval algorithm. All durations are milliseconds (`Int64`),
/// matching the Java `long` arithmetic exactly.
public final class HeartbeatManager {
    public static let oneStepInterval: Int64 = 5_000
    public static let minHeartbeatInterval: Int64 = 30_000
    private static let middleHeartbeatInterval: Int64 = 45_000

    private var currentMaxHeartbeatInterval: Int64 = HeartbeatManager.minHeartbeatInterval
    private var currentHeartbeatInterval: Int64 = HeartbeatManager.minHeartbeatInterval
    private var currentScheduleTime: Int64 = 0
    private var currentSendSuccessTime: Int64 = 0
    private var currentExceptionTime: Int64 = 0
    private var upSearchingMaxInterval = true
    private var currentHeartbeatSuccessNum = 0
    private var disableUpSearchingMaxInterval = false
    private var currentHeartbeatIntervalSuccessNum = 0
    private var tempHeartbeatInterval: Int64 = 0

    private var random: RandomSource
    private let isNightModeProvider: () -> Bool

    public init(
        random: RandomSource = SystemRandomSource(),
        isNightModeProvider: @escaping () -> Bool = HeartbeatManager.systemIsNightMode
    ) {
        self.random = random
        self.isNightModeProvider = isNightModeProvider
    }

    /// Test seam: lets tests construct specific intermediate states directly
    /// (e.g. "interval already at the day ceiling") instead of driving dozens
    /// of `nextHeartbeatInterval()` calls through the public API to reach them.
    public func setStateForTesting(
        currentHeartbeatInterval: Int64,
        currentMaxHeartbeatInterval: Int64,
        upSearchingMaxInterval: Bool,
        currentHeartbeatIntervalSuccessNum: Int
    ) {
        self.currentHeartbeatInterval = currentHeartbeatInterval
        self.currentMaxHeartbeatInterval = currentMaxHeartbeatInterval
        self.upSearchingMaxInterval = upSearchingMaxInterval
        self.currentHeartbeatIntervalSuccessNum = currentHeartbeatIntervalSuccessNum
    }

    public static func systemIsNightMode() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 22 || hour < 6
    }

    private func maxHeartBeatInterval() -> Int64 {
        isNightModeProvider() ? 120_000 : 60_000
    }

    public func currentHeartInterval() -> Int64 {
        tempHeartbeatInterval > 0 ? tempHeartbeatInterval : currentHeartbeatInterval
    }

    public func reportHeartbeatExceptionTime(_ exceptionTime: Int64) {
        currentExceptionTime = exceptionTime
        if currentExceptionTime != 0, currentScheduleTime != 0, currentExceptionTime > currentScheduleTime {
            let interval = currentExceptionTime - currentScheduleTime
            let diff = interval - currentMaxHeartbeatInterval
            let absDiff = abs(diff)
            // Java source has `if (absDiff >= 0)` here, which is always true
            // since abs() never returns negative — preserved unconditionally
            // rather than "fixed" by removing the pointless check.
            currentHeartbeatSuccessNum = 0
            tempHeartbeatInterval = 0
            upSearchingMaxInterval = false
            if absDiff < 2 * Self.oneStepInterval {
                currentMaxHeartbeatInterval -= Self.oneStepInterval
            } else if absDiff < 4 * Self.oneStepInterval {
                currentMaxHeartbeatInterval -= absDiff / 2
            } else if absDiff < 12 * Self.oneStepInterval {
                currentMaxHeartbeatInterval -= 2 * Self.oneStepInterval
            } else {
                disableUpSearchingMaxInterval = true
                currentMaxHeartbeatInterval -= 4 * Self.oneStepInterval
            }
        }
        if currentMaxHeartbeatInterval < 15_000 {
            currentMaxHeartbeatInterval = Self.minHeartbeatInterval
        }
        if currentMaxHeartbeatInterval > maxHeartBeatInterval() {
            currentMaxHeartbeatInterval = maxHeartBeatInterval()
        }
        currentHeartbeatInterval = currentMaxHeartbeatInterval
    }

    public func reportHeartbeatScheduleTime(_ time: Int64) {
        currentScheduleTime = time
    }

    public func reportHeartbeatSendSuccessTime(_ time: Int64) {
        currentSendSuccessTime = time
        recalculateMaxHeartbeatInterval()
    }

    public func nextHeartbeatInterval() -> Int64 {
        let maxSuccessTime = currentHeartbeatInterval / Self.oneStepInterval
        if upSearchingMaxInterval, currentHeartbeatIntervalSuccessNum > Int(maxSuccessTime) {
            currentHeartbeatInterval += Self.oneStepInterval
            currentHeartbeatIntervalSuccessNum = 0
            tempHeartbeatInterval = 0
        } else {
            if currentHeartbeatInterval > Self.middleHeartbeatInterval {
                let randomInt = random.nextInt(upperBound: Int(maxSuccessTime))
                if randomInt % 2 == 1 {
                    tempHeartbeatInterval = currentHeartbeatInterval - Int64(randomInt) * Self.oneStepInterval
                    if tempHeartbeatInterval > maxHeartBeatInterval() {
                        tempHeartbeatInterval = Self.middleHeartbeatInterval
                    }
                    if tempHeartbeatInterval < 0 {
                        tempHeartbeatInterval = Self.minHeartbeatInterval
                    }
                    return tempHeartbeatInterval
                }
            }
            tempHeartbeatInterval = 0
            currentHeartbeatIntervalSuccessNum += 1
            currentHeartbeatInterval = currentMaxHeartbeatInterval
        }
        if currentHeartbeatInterval >= maxHeartBeatInterval() {
            let randomInt = random.nextInt(upperBound: Int(maxHeartBeatInterval() / Self.oneStepInterval))
            tempHeartbeatInterval = maxHeartBeatInterval() - Int64(randomInt) * Self.oneStepInterval
            if tempHeartbeatInterval < 0 {
                tempHeartbeatInterval = Self.minHeartbeatInterval
            }
            return tempHeartbeatInterval
        }
        return currentHeartbeatInterval
    }

    private func recalculateMaxHeartbeatInterval() {
        guard currentSendSuccessTime != 0, currentScheduleTime != 0 else { return }
        let interval = currentSendSuccessTime - currentScheduleTime
        let diff = interval - currentMaxHeartbeatInterval
        guard diff > 0, diff < 90_000 else { return }
        if upSearchingMaxInterval {
            currentMaxHeartbeatInterval = interval
            if interval > maxHeartBeatInterval() {
                currentMaxHeartbeatInterval = maxHeartBeatInterval()
            }
        }
        if !upSearchingMaxInterval {
            currentHeartbeatSuccessNum += 1
            if currentHeartbeatSuccessNum > 3, !disableUpSearchingMaxInterval {
                upSearchingMaxInterval = true
            }
        }
        if !upSearchingMaxInterval, disableUpSearchingMaxInterval {
            if currentMaxHeartbeatInterval < Self.middleHeartbeatInterval || currentHeartbeatSuccessNum > 20 {
                disableUpSearchingMaxInterval = false
                currentHeartbeatSuccessNum = 0
            }
        }
    }
}
