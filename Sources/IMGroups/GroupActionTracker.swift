import IMClient

/// Correlates an outgoing group-action request (`.gam`/`.gkm`/`.gmi`/`.gq`/
/// `.gd`) to its response by wire `messageId`. Every one of these gets a
/// bare "1 byte error code, no payload" response (confirmed by reading
/// `AddGroupMember`/`KickoffGroupMember`/`ModifyGroupInfoHandler`/
/// `QuitGroupHandler`/`DismissGroupHandler` in `chat-server-pro`: none of
/// them ever write to `ackPayload`), so this tracker resolves to plain
/// `Void` on success — exact mirror of `IMContacts`'s
/// `FriendRequestActionTracker`.
public final class GroupActionTracker {
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

    public func resolve(wireMessageId: UInt16, result: Result<Void, TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
