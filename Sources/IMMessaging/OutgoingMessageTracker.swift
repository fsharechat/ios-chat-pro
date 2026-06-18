import IMClient

/// Correlates an outgoing `Signal.PUBLISH`/`SubSignal.MS` send to its ack by
/// the wire `messageId` `IMClient.sendFrame` returned — mirrors
/// `AbstractProtoService`'s `requestMap`. Schedules a 5-second timeout
/// (matching the Android `sendMsTimer` constant) that resolves as `.failed`
/// if no ack arrives in time.
public final class OutgoingMessageTracker {
    public enum SendResult {
        case acked(messageUid: Int64, timestamp: Int64)
        case failed(errorCode: Int32?)
    }

    private final class Pending {
        let localMessageId: Int64
        let completion: (Int64, SendResult) -> Void
        var timeoutToken: SchedulerToken?

        init(localMessageId: Int64, completion: @escaping (Int64, SendResult) -> Void) {
            self.localMessageId = localMessageId
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    /// Registers a pending send. `completion` receives the same
    /// `localMessageId` passed in here, so callers don't need a second
    /// lookup to know which local row to update.
    public func track(wireMessageId: UInt16, localMessageId: Int64, completion: @escaping (Int64, SendResult) -> Void) {
        let entry = Pending(localMessageId: localMessageId, completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failed(errorCode: nil))
        }
        pending[wireMessageId] = entry
    }

    /// Called by `MessageSendAckHandler` when a `PUB_ACK`/`MS` frame
    /// arrives, or internally when the timeout fires. A no-op if
    /// `wireMessageId` isn't (or is no longer) tracked.
    public func resolve(wireMessageId: UInt16, result: SendResult) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(entry.localMessageId, result)
    }
}
