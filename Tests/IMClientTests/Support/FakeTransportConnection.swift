import Foundation
@testable import IMClient

/// Fully-controllable `IMTransportConnection` double. Records every `send`
/// call (without auto-completing it — tests decide when a send "succeeds"
/// by calling `completeOldestSend`), and exposes `simulate`/`simulateReceivedData`
/// to drive `IMClient`'s event handlers deterministically.
final class FakeTransportConnection: IMTransportConnection {
    var onEvent: ((IMTransportEvent) -> Void)?
    var onDataReceived: ((Data) -> Void)?

    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var sentFrames: [Data] = []
    private var pendingCompletions: [(Result<Void, Error>) -> Void] = []

    func start() {
        startCallCount += 1
    }

    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        sentFrames.append(data)
        pendingCompletions.append(completion)
    }

    func cancel() {
        cancelCallCount += 1
    }

    func simulate(_ event: IMTransportEvent) {
        onEvent?(event)
    }

    func simulateReceivedData(_ data: Data) {
        onDataReceived?(data)
    }

    /// Completes the oldest still-pending `send` call. Returns `false` if
    /// nothing is pending.
    @discardableResult
    func completeOldestSend(_ result: Result<Void, Error> = .success(())) -> Bool {
        guard !pendingCompletions.isEmpty else { return false }
        let completion = pendingCompletions.removeFirst()
        completion(result)
        return true
    }

    var pendingSendCount: Int { pendingCompletions.count }
}
