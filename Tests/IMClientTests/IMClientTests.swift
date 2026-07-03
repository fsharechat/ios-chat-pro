import XCTest
@testable import IMClient
import IMTransport
import IMProto

final class IMClientTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var scheduler: ManualScheduler!
    private var client: IMClient!

    override func setUp() {
        super.setUp()
        fakeTransport = FakeTransportConnection()
        scheduler = ManualScheduler()
        let configuration = IMClientConfiguration(
            hosts: "host-a:host-b",
            port: 6789,
            userId: "u1",
            token: makeTestToken(),
            clientIdentifier: "device-1"
        )
        client = try! IMClient(
            configuration: configuration,
            scheduler: scheduler,
            heartbeatManager: HeartbeatManager(),
            transportFactory: { [unowned self] _, _ in self.fakeTransport }
        )
    }

    /// Builds a token exactly like `/login` would return: AES-encrypt
    /// (with `WireCrypto.defaultKey`, the same key used for `AESDecrypt(token, "", false)`)
    /// the string `"<base64 password>|<secret>|ignored"`, base64-encode the ciphertext.
    private func makeTestToken(password: String = "password", secret: String = "mySecretKey12345") -> String {
        let passwordBase64 = Data(password.utf8).base64EncodedString()
        let plaintext = Data("\(passwordBase64)|\(secret)|ignored".utf8)
        let ciphertext = try! WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey)
        return ciphertext.base64EncodedString()
    }

    private func makeConnectAckFrameBytes(messageId: UInt16 = 1) -> Data {
        var payload = Im_ConnectAckPayload()
        payload.msgHead = 100
        let body = try! payload.serializedData()
        return FrameEncoder.encode(signal: .connectAck, subSignal: .none, messageId: messageId, body: body)
    }

    func test_connect_startsTransportAndDoesNothingElseUntilConnected() {
        client.connect()
        XCTAssertEqual(fakeTransport.startCallCount, 1)
        XCTAssertTrue(fakeTransport.sentFrames.isEmpty)
    }

    func test_onTransportConnected_sendsConnectFrameWithDecryptedCredentials() throws {
        client.connect()

        fakeTransport.simulate(.connected)

        XCTAssertEqual(fakeTransport.sentFrames.count, 1)
        let frame = try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames[0]).first)
        XCTAssertEqual(frame.header.signal, .connect)

        let json = try JSONSerialization.jsonObject(with: frame.body) as? [String: Any]
        XCTAssertEqual(json?["userName"] as? String, "u1")
        XCTAssertEqual(json?["clientIdentifier"] as? String, "device-1")

        // The password field is the base64 of AES-encrypting the raw "password"
        // bytes with the secret-derived key — verify it decrypts back correctly,
        // exactly as the server would.
        let passwordCiphertext = try XCTUnwrap(Data(base64Encoded: json?["password"] as? String ?? ""))
        let decryptedPassword = try WireCrypto.decrypt(passwordCiphertext, key: WireCrypto.key(fromSecret: "mySecretKey12345"))
        XCTAssertEqual(decryptedPassword, Data("password".utf8))
    }

    func test_receivingConnectAck_transitionsToConnectedAndSendsFirstHeartbeatAfterConnectSendCompletes() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend() // CONNECT message send completes

        var statuses: [IMConnectionStatus] = []
        client.onConnectionStatusChange = { statuses.append($0) }
        fakeTransport.simulateReceivedData(makeConnectAckFrameBytes())

        XCTAssertEqual(statuses, [.connected])
        XCTAssertEqual(fakeTransport.sentFrames.count, 2) // CONNECT + first heartbeat PING
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty) // heartbeat timer not scheduled until the PING's own send completes

        fakeTransport.completeOldestSend() // heartbeat PING send completes
        XCTAssertEqual(scheduler.scheduledDelays, [30]) // HeartbeatManager.minHeartbeatInterval (30_000ms) = 30s
    }

    func test_transportFailure_schedulesReconnectWithIncreasingBackoff_thenStopsAfterFourAttempts() {
        client.connect()

        for _ in 1...4 {
            fakeTransport.simulate(.failed(NSError(domain: "test", code: 1)))
        }
        XCTAssertEqual(scheduler.scheduledDelays, [2, 4, 6, 8])

        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1))) // 5th failure
        XCTAssertEqual(scheduler.scheduledDelays, [2, 4, 6, 8]) // unchanged — no further automatic reconnect
    }

    func test_firingScheduledReconnect_startsANewConnectionAttempt() {
        client.connect()
        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1)))
        XCTAssertEqual(fakeTransport.startCallCount, 1)

        XCTAssertTrue(scheduler.fireNext())

        XCTAssertEqual(fakeTransport.startCallCount, 2)
    }

    func test_successfulConnectAck_resetsReconnectBackoffCounter() {
        client.connect()
        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1))) // 1st failure: schedules a 2s reconnect
        scheduler.fireNext() // fires it, calling startConnection() again
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()
        fakeTransport.simulateReceivedData(makeConnectAckFrameBytes()) // success resets the counter

        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1))) // next failure should restart backoff from 2s

        XCTAssertEqual(scheduler.scheduledDelays.last, 2)
    }

    func test_disconnect_cancelsTransportAndSuppressesFurtherReconnects() {
        client.connect()
        fakeTransport.simulate(.connected)

        client.disconnect()

        XCTAssertEqual(fakeTransport.cancelCallCount, 1)
        let delaysBeforeFailureAfterDisconnect = scheduler.scheduledDelays.count
        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1)))
        XCTAssertEqual(scheduler.scheduledDelays.count, delaysBeforeFailureAfterDisconnect) // no reconnect scheduled post-disconnect
    }

    func test_registeredHandler_receivesNonConnectAckFramesToo() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()

        final class CapturingHandler: MessageHandler {
            var captured: Frame?
            func canHandle(signal: Signal, subSignal: SubSignal) -> Bool { signal == .push }
            func handle(frame: Frame) { captured = frame }
        }
        let handler = CapturingHandler()
        client.register(handler)

        let pushFrame = FrameEncoder.encode(signal: .push, subSignal: .none, messageId: 9, body: Data("hi".utf8))
        fakeTransport.simulateReceivedData(pushFrame)

        XCTAssertEqual(handler.captured?.body, Data("hi".utf8))
    }

    // MARK: - serverTimeDeltaMillis (Fix 2: 90s 来电新鲜度需要服务器时间校正)

    func test_serverTimeDeltaMillis_defaultsToZeroBeforeAnyConnectAck() {
        XCTAssertEqual(client.serverTimeDeltaMillis, 0)
    }

    func test_receivingConnectAckWithServerTime_computesDeltaAgainstLocalClock() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()

        // 模拟设备时钟慢了 2 分钟:server_time 比本机当前时间超前 120s。
        let localNow = Int64(Date().timeIntervalSince1970 * 1000)
        var payload = Im_ConnectAckPayload()
        payload.msgHead = 100
        payload.serverTime = localNow + 120_000
        let body = try! payload.serializedData()
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .connectAck, subSignal: .none, messageId: 1, body: body))

        // 允许测试执行耗时带来的少量误差。
        XCTAssertTrue(abs(client.serverTimeDeltaMillis - 120_000) < 5_000, "delta was \(client.serverTimeDeltaMillis)")
    }

    func test_receivingConnectAckWithoutServerTime_leavesDeltaAtZero() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()

        fakeTransport.simulateReceivedData(makeConnectAckFrameBytes()) // server_time 未设置(=0)

        XCTAssertEqual(client.serverTimeDeltaMillis, 0)
    }
}
