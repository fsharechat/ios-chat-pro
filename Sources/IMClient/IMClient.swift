import Foundation
import IMTransport

public enum IMConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
}

public struct IMClientConfiguration {
    public var hosts: String
    public var port: UInt16
    public var userId: String
    public var token: String
    public var clientIdentifier: String

    public init(hosts: String, port: UInt16, userId: String, token: String, clientIdentifier: String) {
        self.hosts = hosts
        self.port = port
        self.userId = userId
        self.token = token
        self.clientIdentifier = clientIdentifier
    }
}

enum LoginHandshakeError: Error, Equatable {
    case invalidTokenEncoding
    case malformedDecryptedToken
}

/// Owns the TCP connection lifecycle: connect, the AES login handshake,
/// adaptive heartbeat, and host-failover reconnect with backoff. Mirrors
/// `AbstractProtoService`'s control flow:
/// - `onEvent(.connected)` → `sendConnectMessage()` (Java: `onConnected()`)
/// - a `Signal.CONNECT_ACK` frame → reset reconnect counter, mark connected,
///   start the heartbeat loop (Java: `onConnected()`'s `reconnectNum = 0` +
///   `sendHeartbeat(...)`); note this never branches on the refusal
///   `SubSignal` codes, matching `ConnectAckMessageHandler.match()`, which
///   only checks the `Signal`
/// - `onEvent(.failed)`/`.cancelled` → report the failure to
///   `HeartbeatManager`, schedule a reconnect with backoff capped at 4
///   automatic attempts then stop (Java: `receiveException`'s
///   `reconnectNum <= 3` guard, checked *before* incrementing — so this is
///   shared by every failure source, including a `sendConnectMessage` token
///   decode error, not just transport failures)
/// - heartbeat send completion → `reportHeartbeatSendSuccessTime`/
///   `reportHeartbeatExceptionTime`, then (success only) reschedule via
///   `scheduleNextHeartbeatTimer`, whose *fired* action computes
///   `nextHeartbeatInterval()` for the **next** send — this two-step
///   "schedule with current, compute next on fire" split mirrors
///   `schedule()`/`sendHeartbeat()` in `AbstractProtoService.java` exactly;
///   collapsing it into one step would change the algorithm's timing.
///
/// **Threading contract:** no internal locking — all public methods
/// (`connect()`, `disconnect()`, `register(_:)`) and all transport/scheduler
/// callbacks must be invoked from the same queue. By convention this is the
/// main queue: `DispatchQueueScheduler` and `NWConnectionTransport` both
/// default their callback delivery to `.main`. This mirrors how most iOS
/// networking clients (e.g. `URLSession`'s default delegate queue) are
/// driven — callers don't need their own lock as long as they stick to one
/// queue. A caller needing background-queue operation must inject a
/// `Scheduler` and `transportFactory` that both deliver on that same queue.
public final class IMClient {
    public private(set) var connectionStatus: IMConnectionStatus = .disconnected {
        didSet { onConnectionStatusChange?(connectionStatus) }
    }
    public var onConnectionStatusChange: ((IMConnectionStatus) -> Void)?

    private static let maxAutomaticReconnectAttempts = 4

    private let configuration: IMClientConfiguration
    private let transportFactory: (String, UInt16) -> IMTransportConnection
    private let hostSelector: RoundRobinHostSelector
    private let scheduler: Scheduler
    private let heartbeatManager: HeartbeatManager
    private let handlerRegistry = MessageHandlerRegistry()
    private let frameDecoder = FrameDecoder()

    private var transport: IMTransportConnection?
    private var reconnectAttempt = 0
    private var userDisconnect = false
    private var heartbeatToken: SchedulerToken?
    private var reconnectToken: SchedulerToken?
    private var nextMessageId: UInt16 = 0

    public init(
        configuration: IMClientConfiguration,
        scheduler: Scheduler = DispatchQueueScheduler(),
        heartbeatManager: HeartbeatManager = HeartbeatManager(),
        transportFactory: @escaping (String, UInt16) -> IMTransportConnection = { host, port in
            NWConnectionTransport(host: host, port: port)
        }
    ) throws {
        self.configuration = configuration
        self.scheduler = scheduler
        self.heartbeatManager = heartbeatManager
        self.transportFactory = transportFactory
        hostSelector = try RoundRobinHostSelector(hostsString: configuration.hosts)
    }

    public func register(_ handler: MessageHandler) {
        handlerRegistry.register(handler)
    }

    /// The logged-in user's id, needed by `IMMessaging` to set `fromUser`
    /// on outgoing messages and to distinguish "my own message coming back
    /// through a pull" from a genuinely received one.
    public var userId: String { configuration.userId }

    public func connect() {
        userDisconnect = false
        startConnection()
    }

    public func disconnect() {
        userDisconnect = true
        heartbeatToken?.cancel()
        reconnectToken?.cancel()
        transport?.onEvent = nil
        transport?.onDataReceived = nil
        transport?.cancel()
        transport = nil
        connectionStatus = .disconnected
    }

    private func startConnection() {
        guard !userDisconnect else { return }
        connectionStatus = .connecting
        let host = hostSelector.nextHost()
        let newTransport = transportFactory(host, configuration.port)
        newTransport.onEvent = { [weak self] event in self?.handleTransportEvent(event) }
        newTransport.onDataReceived = { [weak self] data in self?.handleReceivedData(data) }
        transport = newTransport
        newTransport.start()
    }

    private func handleTransportEvent(_ event: IMTransportEvent) {
        switch event {
        case .connected:
            sendConnectMessage()
        case .failed, .cancelled:
            heartbeatManager.reportHeartbeatExceptionTime(nowMillis())
            heartbeatToken?.cancel()
            connectionStatus = .disconnected
            scheduleReconnectIfNeeded()
        }
    }

    private func scheduleReconnectIfNeeded() {
        guard !userDisconnect, reconnectAttempt <= Self.maxAutomaticReconnectAttempts - 1 else { return }
        reconnectAttempt += 1
        let delaySeconds = TimeInterval(reconnectAttempt) * 2
        reconnectToken = scheduler.scheduleOnce(after: delaySeconds) { [weak self] in
            self?.startConnection()
        }
    }

    private func sendConnectMessage() {
        guard !userDisconnect else { return }
        do {
            guard let tokenData = Data(base64Encoded: configuration.token) else {
                throw LoginHandshakeError.invalidTokenEncoding
            }
            let decryptedToken = try WireCrypto.decrypt(tokenData, key: WireCrypto.defaultKey)
            guard let tokenString = String(data: decryptedToken, encoding: .utf8) else {
                throw LoginHandshakeError.malformedDecryptedToken
            }
            let parts = tokenString.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let passwordBytes = Data(base64Encoded: parts[0]) else {
                throw LoginHandshakeError.malformedDecryptedToken
            }
            let secretKey = WireCrypto.key(fromSecret: parts[1])
            let encryptedPassword = try WireCrypto.encrypt(passwordBytes, key: secretKey)
            let connectMessage = ConnectMessage(
                userName: configuration.userId,
                password: encryptedPassword.base64EncodedString(),
                clientIdentifier: configuration.clientIdentifier
            )
            let body = try connectMessage.encodedJSONData()
            sendFrame(signal: .connect, subSignal: .none, body: body)
        } catch {
            handleTransportEvent(.failed(error))
        }
    }

    /// Encodes and sends one frame, returning the wire `messageId` it was
    /// allocated. Public so `IMMessaging` (Plan D) can send business
    /// messages and correlate their acks by this id, exactly like
    /// `AbstractProtoService`'s `requestMap` does in the Android reference.
    @discardableResult
    public func sendFrame(
        signal: Signal,
        subSignal: SubSignal,
        body: Data,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) -> UInt16 {
        nextMessageId = nextMessageId &+ 1
        let messageId = nextMessageId
        let bytes = FrameEncoder.encode(signal: signal, subSignal: subSignal, messageId: messageId, body: body)
        transport?.send(bytes, completion: completion)
        return messageId
    }

    private func handleReceivedData(_ data: Data) {
        for frame in frameDecoder.feed(data) {
            print("[DEBUG-FP] recv signal=\(frame.header.signal) subSignal=\(frame.header.subSignal) bodyLength=\(frame.header.bodyLength) messageId=\(frame.header.messageId)")
            if frame.header.signal == .connectAck {
                handleConnectAck()
            }
            handlerRegistry.dispatch(frame)
        }
    }

    private func handleConnectAck() {
        reconnectAttempt = 0
        reconnectToken?.cancel()
        connectionStatus = .connected
        sendHeartbeat(interval: heartbeatManager.currentHeartInterval())
    }

    private func sendHeartbeat(interval: Int64) {
        let body = Data("{\"interval\":\(interval)}".utf8)
        sendFrame(signal: .ping, subSignal: .none, body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.heartbeatManager.reportHeartbeatSendSuccessTime(self.nowMillis())
                self.scheduleNextHeartbeatTimer()
            case .failure:
                self.heartbeatManager.reportHeartbeatExceptionTime(self.nowMillis())
            }
        }
    }

    private func scheduleNextHeartbeatTimer() {
        heartbeatManager.reportHeartbeatScheduleTime(nowMillis())
        heartbeatToken?.cancel()
        let delaySeconds = TimeInterval(heartbeatManager.currentHeartInterval()) / 1000
        heartbeatToken = scheduler.scheduleOnce(after: delaySeconds) { [weak self] in
            guard let self else { return }
            self.sendHeartbeat(interval: self.heartbeatManager.nextHeartbeatInterval())
        }
    }

    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
