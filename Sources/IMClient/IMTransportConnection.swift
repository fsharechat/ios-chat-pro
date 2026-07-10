import Foundation
import Network

public enum IMTransportEvent {
    case connected
    case failed(Error)
    case cancelled
    /// 当前发不出也收不到，但系统仍在等待路径恢复：建连阶段进入
    /// `NWConnection.State.waiting`（如无网络时），或已建立的连接
    /// viability 变为 false（如走出 Wi-Fi 覆盖）。TCP 断网既不会立刻
    /// `.failed` 也不会 `.cancelled`——没有这个事件，`IMClient` 会一直
    /// 误以为连接健康（见 `IMClient` 的宽限定时器）。
    case notViable
    /// 与 `notViable` 对应的恢复信号：viability 回到 true。
    case viable
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
    /// Queue all `Network.framework` callbacks (state updates, receive,
    /// send completion) are delivered on. Defaults to `.main` to match
    /// `DispatchQueueScheduler`'s default and `IMClient`'s single-queue-caller
    /// contract (see `IMClient`'s doc comment) — most callers will drive
    /// `IMClient` from main, so this avoids a real cross-queue race without
    /// requiring `IMClient` to do its own internal locking.
    private let queue: DispatchQueue

    public init(host: String, port: UInt16, callbackQueue: DispatchQueue = .main) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        queue = callbackQueue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] NWConnection state -> \(state)")
            switch state {
            case .ready:
                self?.onEvent?(.connected)
                self?.receiveLoop()
            case .waiting:
                self?.onEvent?(.notViable)
            case .failed(let error):
                self?.onEvent?(.failed(error))
            case .cancelled:
                self?.onEvent?(.cancelled)
            default:
                break
            }
        }
        connection.viabilityUpdateHandler = { [weak self] isViable in
            print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] NWConnection viability -> \(isViable)")
            self?.onEvent?(isViable ? .viable : .notViable)
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
        print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] receiveLoop: arming connection.receive()")
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] receive callback fired but self is nil")
                return
            }
            print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] NWConnectionTransport.receive callback: bytes=\(data?.count ?? -1) isComplete=\(isComplete) error=\(String(describing: error))")
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
            print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] receiveLoop: about to re-arm")
            self.receiveLoop()
        }
        print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] receiveLoop: connection.receive() call returned (registration done)")
    }
}
