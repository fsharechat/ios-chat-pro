import Foundation
import IMClient

/// Local duplicate of `IMClientTests`'s `FakeTransportConnection` —
/// `internal` types aren't visible across SPM test targets, so this test
/// target keeps its own minimal copy, implementing only what
/// `ContactSyncServiceTests` needs.
final class FakeTransportConnection: IMTransportConnection {
    var onEvent: ((IMTransportEvent) -> Void)?
    var onDataReceived: ((Data) -> Void)?

    private(set) var sentFrames: [Data] = []

    func start() {}
    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        sentFrames.append(data)
        completion(.success(()))
    }
    func cancel() {}

    func simulate(_ event: IMTransportEvent) { onEvent?(event) }
    func simulateReceivedData(_ data: Data) { onDataReceived?(data) }
}
