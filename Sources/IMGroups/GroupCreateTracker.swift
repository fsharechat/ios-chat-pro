import IMClient

/// Correlates an outgoing `.gc` (create group) request to its response by
/// wire `messageId` — same shape as `IMContacts`'s `UserSearchTracker`. The
/// success payload is the server-assigned group id string;
/// `GroupCreateHandler` decodes it from the raw ack bytes before resolving
/// this tracker.
public final class GroupCreateTracker {
    public enum TrackerError: Error, Equatable {
        case serverError(errorCode: Int32)
        case malformedResponse
        case timeout
    }

    private final class Pending {
        let completion: (Result<String, TrackerError>) -> Void
        var timeoutToken: SchedulerToken?

        init(completion: @escaping (Result<String, TrackerError>) -> Void) {
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, completion: @escaping (Result<String, TrackerError>) -> Void) {
        let entry = Pending(completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failure(.timeout))
        }
        pending[wireMessageId] = entry
    }

    public func resolve(wireMessageId: UInt16, result: Result<String, TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
