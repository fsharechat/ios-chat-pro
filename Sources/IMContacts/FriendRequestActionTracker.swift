import IMClient

/// Correlates an outgoing `Signal.publish`/`.far` (send request) or `.fhr`
/// (accept request) call to its response by wire `messageId`. Both
/// requests get a bare "1 byte error code, no payload" response, so this
/// tracker (unlike `UserSearchTracker`/`MinioUploadURLTracker`) resolves
/// to plain `Void` on success rather than a parsed payload — and has no
/// `.malformedResponse` case, since there is no payload to fail to parse.
/// `IMClient.sendFrame`'s `nextMessageId` is a single incrementing counter
/// shared across every outgoing frame, so one tracker safely serves both
/// `.far` and `.fhr` calls without messageId collisions.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class FriendRequestActionTracker {
    public enum TrackerError: Error, Equatable {
        case serverError(errorCode: Int32)
        case timeout
    }

    private final class Pending {
        let completion: (Result<Void, TrackerError>) -> Void
        var timeoutToken: SchedulerToken?

        init(completion: @escaping (Result<Void, TrackerError>) -> Void) {
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, completion: @escaping (Result<Void, TrackerError>) -> Void) {
        let entry = Pending(completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failure(.timeout))
        }
        pending[wireMessageId] = entry
    }

    /// Called by `FriendRequestActionHandler` when a `PUB_ACK`/`FAR`/`FHR`
    /// frame arrives, or internally when the timeout fires. A no-op if
    /// `wireMessageId` isn't (or is no longer) tracked.
    public func resolve(wireMessageId: UInt16, result: Result<Void, TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
