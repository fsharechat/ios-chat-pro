import Foundation
import Network

public enum IMTransportEvent {
    case connected
    case failed(Error)
    case cancelled
}

/// A raw byte-stream transport: connects, sends bytes, receives bytes.
/// Knows nothing about frames, signals, or the login handshake — that's
/// `IMClient`'s job. This separation is what makes `IMClient` testable
/// without a real socket (substitute `FakeTransportConnection`).
public protocol IMTransportConnection: AnyObject {
    var onEvent: ((IMTransportEvent) -> Void)? { get set }
    var onDataReceived: ((Data) -> Void)? { get set }
    func start()
    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void)
    func cancel()
}

/// Real transport, backed by `Network.framework`.
public final class NWConnectionTransport: IMTransportConnection {
    public var onEvent: ((IMTransportEvent) -> Void)?
    public var onDataReceived: ((Data) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "im.transport.nwconnection")

    public init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onEvent?(.connected)
                self?.receiveLoop()
            case .failed(let error):
                self?.onEvent?(.failed(error))
            case .cancelled:
                self?.onEvent?(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        })
    }

    public func cancel() {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onDataReceived?(data)
            }
            if let error {
                self.onEvent?(.failed(error))
                return
            }
            if isComplete {
                self.onEvent?(.cancelled)
                return
            }
            self.receiveLoop()
        }
    }
}
