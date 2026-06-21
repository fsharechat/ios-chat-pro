import IMClient

/// Correlates an outgoing `Signal.publish`/`SubSignal.us` search request to
/// its response by the wire `messageId` `IMClient.sendFrame` returned —
/// same shape as `IMMedia`'s `MinioUploadURLTracker`. The success payload
/// is the matched `[uid]` list, not the raw protobuf: `UserSearchHandler`
/// upserts each `Im_User` into `UserStore` itself before resolving this
/// tracker.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class UserSearchTracker {
    public enum TrackerError: Error, Equatable {
        case serverError(errorCode: Int32)
        case malformedResponse
        case timeout
    }

    private final class Pending {
        let completion: (Result<[String], TrackerError>) -> Void
        var timeoutToken: SchedulerToken?

        init(completion: @escaping (Result<[String], TrackerError>) -> Void) {
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, completion: @escaping (Result<[String], TrackerError>) -> Void) {
        let entry = Pending(completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failure(.timeout))
        }
        pending[wireMessageId] = entry
    }

    /// Called by `UserSearchHandler` when a `PUB_ACK`/`US` frame
    /// arrives, or internally when the timeout fires. A no-op if
    /// `wireMessageId` isn't (or is no longer) tracked.
    public func resolve(wireMessageId: UInt16, result: Result<[String], TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
