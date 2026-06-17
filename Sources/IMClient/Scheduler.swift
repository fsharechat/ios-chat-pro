import Foundation

public protocol SchedulerToken {
    func cancel()
}

public protocol Scheduler {
    @discardableResult
    func scheduleOnce(after delay: TimeInterval, _ action: @escaping () -> Void) -> SchedulerToken
}

/// Real, production scheduler backed by `DispatchQueue.asyncAfter`.
public final class DispatchQueueScheduler: Scheduler {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func scheduleOnce(after delay: TimeInterval, _ action: @escaping () -> Void) -> SchedulerToken {
        let workItem = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return DispatchWorkItemToken(workItem: workItem)
    }

    private final class DispatchWorkItemToken: SchedulerToken {
        private let workItem: DispatchWorkItem
        init(workItem: DispatchWorkItem) { self.workItem = workItem }
        func cancel() { workItem.cancel() }
    }
}

/// Test double: records every scheduled delay (for assertions) and only
/// runs an action when the test explicitly calls `fireNext()` — no real
/// time, no flakiness, full control over ordering.
public final class ManualScheduler: Scheduler {
    private struct Pending {
        let id: Int
        let delay: TimeInterval
        let action: () -> Void
    }

    private final class Token: SchedulerToken {
        let id: Int
        weak var owner: ManualScheduler?
        init(id: Int, owner: ManualScheduler) {
            self.id = id
            self.owner = owner
        }
        func cancel() { owner?.cancelPending(id: id) }
    }

    private var pendingByInsertionOrder: [Pending] = []
    private var nextId = 0
    /// Every delay ever passed to `scheduleOnce`, in call order — including
    /// ones that were later cancelled or already fired. Useful for
    /// asserting "what sequence of delays did the code under test request."
    public private(set) var scheduledDelays: [TimeInterval] = []

    public init() {}

    public func scheduleOnce(after delay: TimeInterval, _ action: @escaping () -> Void) -> SchedulerToken {
        let id = nextId
        nextId += 1
        pendingByInsertionOrder.append(Pending(id: id, delay: delay, action: action))
        scheduledDelays.append(delay)
        return Token(id: id, owner: self)
    }

    private func cancelPending(id: Int) {
        pendingByInsertionOrder.removeAll { $0.id == id }
    }

    /// Runs and removes the oldest still-pending action. Returns `false`
    /// (and does nothing) if nothing is pending.
    @discardableResult
    public func fireNext() -> Bool {
        guard !pendingByInsertionOrder.isEmpty else { return false }
        let next = pendingByInsertionOrder.removeFirst()
        next.action()
        return true
    }

    public var pendingCount: Int { pendingByInsertionOrder.count }
}
