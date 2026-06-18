import IMClient
import IMProto

/// Correlates an outgoing `Signal.PUBLISH`/`SubSignal.GMURL` request to its
/// response by the wire `messageId` `IMClient.sendFrame` returned — same
/// shape as `IMMessaging`'s `OutgoingMessageTracker`. Schedules a
/// 5-second timeout (matching the same constant used elsewhere in this
/// codebase for `PUB_ACK` waits) that resolves as `.timeout` if no response
/// arrives in time.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class MinioUploadURLTracker {
    public enum TrackerError: Error, Equatable {
        case serverError(errorCode: Int32)
        case malformedResponse
        case timeout
    }

    private final class Pending {
        let completion: (Result<Im_GetMinioUploadUrlResult, TrackerError>) -> Void
        var timeoutToken: SchedulerToken?

        init(completion: @escaping (Result<Im_GetMinioUploadUrlResult, TrackerError>) -> Void) {
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, completion: @escaping (Result<Im_GetMinioUploadUrlResult, TrackerError>) -> Void) {
        let entry = Pending(completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failure(.timeout))
        }
        pending[wireMessageId] = entry
    }

    /// Called by `MinioUploadURLHandler` when a `PUB_ACK`/`GMURL` frame
    /// arrives, or internally when the timeout fires. A no-op if
    /// `wireMessageId` isn't (or is no longer) tracked.
    public func resolve(wireMessageId: UInt16, result: Result<Im_GetMinioUploadUrlResult, TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
