import IMClient

/// Correlates an outgoing `.gpgm` (pull group member) request to the
/// `groupId` it was asking about. Unlike every other tracker in this
/// codebase, there's no completion callback — `Im_PullGroupMemberResult`
/// has no `target`/group-id field of its own (confirmed by reading
/// `PullGroupMemberResult` in `FSCMessage.proto`: `repeated GroupMember
/// member = 1;`, nothing else), so `GroupMemberSyncHandler` needs *some*
/// way to know which group the returned members belong to — this tracker
/// is that correlation, not a request/response result carrier.
/// `GroupSyncService.refreshMembers` is fire-and-forget by design (see its
/// doc comment), so a timed-out entry is just dropped, never reported as a
/// failure to anyone.
public final class GroupMemberSyncTracker {
    private final class Pending {
        let groupId: String
        var timeoutToken: SchedulerToken?
        init(groupId: String) {
            self.groupId = groupId
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, groupId: String) {
        let entry = Pending(groupId: groupId)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.pending.removeValue(forKey: wireMessageId)
        }
        pending[wireMessageId] = entry
    }

    @discardableResult
    public func resolve(wireMessageId: UInt16) -> String? {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return nil }
        entry.timeoutToken?.cancel()
        return entry.groupId
    }
}
