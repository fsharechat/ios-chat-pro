import Foundation
import IMClient

/// Local duplicate of `IMClientTests`'s `FakeTransportConnection` —
/// `internal` types aren't visible across SPM test targets, so this test
/// target keeps its own minimal copy, implementing only what
/// `MessagingServiceTests` needs.
final class FakeTransportConnection: IMTransportConnection {
    var onEvent: ((IMTransportEvent) -> Void)?
    var onDataReceived: ((Data) -> Void)?

    private(set) var sentFrames: [Data] = []
    private var pendingCompletions: [(Result<Void, Error>) -> Void] = []

    func start() {}

    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        sentFrames.append(data)
        pendingCompletions.append(completion)
    }

    func cancel() {}

    func simulate(_ event: IMTransportEvent) {
        onEvent?(event)
    }

    func simulateReceivedData(_ data: Data) {
        onDataReceived?(data)
    }

    @discardableResult
    func completeOldestSend(_ result: Result<Void, Error> = .success(())) -> Bool {
        guard !pendingCompletions.isEmpty else { return false }
        pendingCompletions.removeFirst()(result)
        return true
    }
}
