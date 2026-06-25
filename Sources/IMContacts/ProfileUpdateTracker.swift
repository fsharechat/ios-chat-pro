import IMClient

/// Correlates an outgoing `Signal.publish`/`.mmi` (modify my info) call to
/// its response by wire `messageId`. Like `FriendRequestActionTracker`,
/// `.mmi`'s ack is a bare "1 byte error code, no payload" response
/// (verified against the Android/server reference), so this resolves to
/// plain `Void` on success rather than a parsed payload.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ProfileUpdateTracker {
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

    /// Called by `ProfileUpdateHandler` when a `PUB_ACK`/`.mmi` frame
    /// arrives, or internally when the timeout fires. A no-op if
    /// `wireMessageId` isn't (or is no longer) tracked.
    public func resolve(wireMessageId: UInt16, result: Result<Void, TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
