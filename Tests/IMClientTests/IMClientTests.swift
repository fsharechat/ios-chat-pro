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
        // [15] 是 transport ready 时排上的握手超时定时器(收到 ACK 时已取消,
        // 但 scheduledDelays 记录的是"曾被请求过的"全部延时)。心跳定时器
        // 要等 PING 自己的 send 完成才排。
        XCTAssertEqual(scheduler.scheduledDelays, [15])

        fakeTransport.completeOldestSend() // heartbeat PING send completes
        XCTAssertEqual(scheduler.scheduledDelays, [15, 30]) // HeartbeatManager.minHeartbeatInterval (30_000ms) = 30s
    }

    func test_transportFailure_schedulesReconnectWithIncreasingBackoff_thenStopsAfterFourAttempts() {
        client.connect()

        // 每一轮:失败 → 排上退避 → 定时器触发(重连,回到 .connecting)。
        for _ in 1...4 {
            fakeTransport.simulate(.failed(NSError(domain: "test", code: 1)))
            XCTAssertTrue(scheduler.fireNext())
        }
        XCTAssertEqual(scheduler.scheduledDelays, [2, 4, 6, 8])

        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1))) // 5th failure
        XCTAssertEqual(scheduler.scheduledDelays, [2, 4, 6, 8]) // unchanged — no further automatic reconnect
    }

    /// 一次断开在 `NWConnection` 上会双发失败事件(receive completion 的
    /// error 一次、stateUpdateHandler 转 .failed/.cancelled 又一次)。若每个
    /// 事件都排一轮重连,两条定时器会先后各起一条 socket,它们的字节交织进
    /// 同一个 FrameDecoder 后 CONNECT_ACK 会被整批丢弃 —— 状态永远停在
    /// .connecting。退避必须按"重连轮次"而非"失败事件个数"推进。
    func test_duplicateFailureEventsForSameDisconnect_scheduleOnlyOneReconnect() {
        client.connect()

        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1)))
        fakeTransport.simulate(.cancelled) // 同一次断开的第二个事件
        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1)))

        XCTAssertEqual(scheduler.scheduledDelays, [2])
        XCTAssertTrue(scheduler.fireNext())
        XCTAssertFalse(scheduler.fireNext()) // 没有第二条重连定时器在队列里
        XCTAssertEqual(fakeTransport.startCallCount, 2) // 只重连了一次
    }

    /// 新一轮连接开始前必须摘掉上一条 transport 的回调并 cancel,否则旧
    /// socket 迟到的字节会和新连接的字节交织进同一个 FrameDecoder,把流
    /// 解码错位。用每轮发新实例的工厂才能观察到这一点(默认的
    /// `transportFactory` 每次返回同一个 fake)。
    func test_startingNewConnection_detachesAndCancelsThePreviousTransport() {
        var transports: [FakeTransportConnection] = []
        let scheduler = ManualScheduler()
        let client = try! IMClient(
            configuration: IMClientConfiguration(hosts: "host-a", port: 6789, userId: "u1", token: makeTestToken(), clientIdentifier: "device-1"),
            scheduler: scheduler,
            heartbeatManager: HeartbeatManager(),
            transportFactory: { _, _ in
                let transport = FakeTransportConnection()
                transports.append(transport)
                return transport
            }
        )

        client.connect()
        let first = transports[0]
        first.simulate(.connected)
        first.completeOldestSend()
        first.simulate(.cancelled)
        scheduler.fireNext() // 退避重连 → startConnection()

        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(first.cancelCallCount, 1) // 旧 transport 被 cancel
        XCTAssertNil(first.onEvent) // 回调已摘,迟到的事件打不到 IMClient
        XCTAssertNil(first.onDataReceived)

        // 旧 socket 的迟到字节不再进入解码流:即便它送来一个完整的
        // CONNECT_ACK,状态也不该被它改写。
        var statuses: [IMConnectionStatus] = []
        client.onConnectionStatusChange = { statuses.append($0) }
        first.simulateReceivedData(makeConnectAckFrameBytes())
        XCTAssertTrue(statuses.isEmpty)
    }

    // MARK: - 握手超时(TCP ready 但 CONNECT_ACK 不来)

    func test_transportReadyButNoConnectAck_cancelsConnectionAfterHandshakeTimeout() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend() // CONNECT 已发出

        XCTAssertEqual(scheduler.scheduledDelays, [15]) // 握手超时定时器
        XCTAssertTrue(scheduler.fireNext())

        XCTAssertEqual(fakeTransport.cancelCallCount, 1)

        // cancel 的 .cancelled 事件走统一的断开 + 退避重连路径。
        var statuses: [IMConnectionStatus] = []
        client.onConnectionStatusChange = { statuses.append($0) }
        fakeTransport.simulate(.cancelled)
        XCTAssertEqual(statuses, [.disconnected])
        XCTAssertEqual(scheduler.scheduledDelays.last, 2)
    }

    func test_connectAck_cancelsHandshakeTimeout() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()
        fakeTransport.simulateReceivedData(makeConnectAckFrameBytes())
        fakeTransport.completeOldestSend() // 心跳 PING

        // 队列里只剩心跳定时器;握手超时定时器已取消,不会误杀活连接。
        while scheduler.fireNext() {}
        XCTAssertEqual(fakeTransport.cancelCallCount, 0)
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

    // MARK: - 大响应的流式进度与跨连接的解码器状态

    func test_partiallyReceivedFrame_reportsProgressWithHeaderAndByteCount() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()

        var progress: [(Header, Int)] = []
        client.onIncomingFrameProgress = { progress.append(($0, $1)) }

        let bigFrame = FrameEncoder.encode(signal: .pubAck, subSignal: .lrm, messageId: 161, body: Data(repeating: 0xab, count: 500))
        fakeTransport.simulateReceivedData(bigFrame.prefix(Header.length + 200))

        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.0.messageId, 161)
        XCTAssertEqual(progress.first?.0.subSignal, .lrm)
        XCTAssertEqual(progress.first?.1, 200)
    }

    /// 大响应收到一半时断线,残留的半帧不能污染重连后的新字节流。
    func test_reconnect_afterFrameCutOffMidBody_decodesNewStreamCleanly() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()

        final class CapturingHandler: MessageHandler {
            var captured: [Frame] = []
            func canHandle(signal: Signal, subSignal: SubSignal) -> Bool { signal == .push }
            func handle(frame: Frame) { captured.append(frame) }
        }
        let handler = CapturingHandler()
        client.register(handler)

        let cutOff = FrameEncoder.encode(signal: .pubAck, subSignal: .lrm, messageId: 161, body: Data(repeating: 0xab, count: 500))
        fakeTransport.simulateReceivedData(cutOff.prefix(Header.length + 200))

        fakeTransport.simulate(.cancelled)
        scheduler.fireNext() // 退避重连
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()

        let pushFrame = FrameEncoder.encode(signal: .push, subSignal: .none, messageId: 9, body: Data("hi".utf8))
        fakeTransport.simulateReceivedData(pushFrame)

        XCTAssertEqual(handler.captured.count, 1)
        XCTAssertEqual(handler.captured.first?.body, Data("hi".utf8))
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

    // MARK: - viability 宽限(TCP 静默断网既不 failed 也不 cancelled)

    /// 走到 connected 状态的公共前置:connect → transport ready → CONNECT
    /// 发送完成 → 收到 CONNECT_ACK → 心跳 PING 发送完成(心跳定时器已排入)。
    private func driveToConnected() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend() // CONNECT
        fakeTransport.simulateReceivedData(makeConnectAckFrameBytes())
        fakeTransport.completeOldestSend() // 心跳 PING
    }

    func test_notViable_startsGraceTimer_whichCancelsTransportOnFire() {
        driveToConnected()
        let delaysBefore = scheduler.scheduledDelays // [30] 心跳定时器

        fakeTransport.simulate(.notViable)
        XCTAssertEqual(scheduler.scheduledDelays, delaysBefore + [10])

        XCTAssertTrue(scheduler.fireNext()) // 先入队的心跳定时器(发出一个 PING)
        XCTAssertTrue(scheduler.fireNext()) // 宽限定时器到点,仍未恢复
        XCTAssertEqual(fakeTransport.cancelCallCount, 1)

        // 真实 NWConnection 在 cancel 后会回调 .cancelled;fake 不自动回调,
        // 手动模拟,验证走的是统一断开 + 退避重连路径。
        var statuses: [IMConnectionStatus] = []
        client.onConnectionStatusChange = { statuses.append($0) }
        fakeTransport.simulate(.cancelled)
        XCTAssertEqual(statuses.first, .disconnected)
        XCTAssertEqual(scheduler.scheduledDelays.last, 2) // 第一次退避重连已排上
    }

    func test_notViable_thenViable_cancelsGraceTimerWithoutKillingConnection() {
        driveToConnected()

        fakeTransport.simulate(.notViable)
        fakeTransport.simulate(.viable)

        // 把队列里所有还能 fire 的定时器都触发(心跳会 fire;已取消的宽限
        // 定时器不会),transport 不应被 cancel。
        while scheduler.fireNext() {}
        XCTAssertEqual(fakeTransport.cancelCallCount, 0)
    }

    func test_repeatedNotViable_schedulesOnlyOneGraceTimer() {
        driveToConnected()
        let delaysBefore = scheduler.scheduledDelays

        fakeTransport.simulate(.notViable)
        fakeTransport.simulate(.notViable)

        XCTAssertEqual(scheduler.scheduledDelays, delaysBefore + [10])
    }

    // MARK: - 心跳失败走统一失败路径

    func test_heartbeatSendFailure_cancelsTransportInsteadOfSilentlyStoppingHeartbeatLoop() {
        client.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend() // CONNECT
        fakeTransport.simulateReceivedData(makeConnectAckFrameBytes())

        let delaysBefore = scheduler.scheduledDelays // [15] 握手超时(已随 ACK 取消)
        fakeTransport.completeOldestSend(.failure(NSError(domain: "test", code: 1))) // 心跳 PING 发送失败

        XCTAssertEqual(fakeTransport.cancelCallCount, 1)
        XCTAssertEqual(scheduler.scheduledDelays, delaysBefore) // 不再排下一次心跳,等重连成功后重启
    }

    // MARK: - reconnectIfNeeded(网络恢复 / 回前台)

    func test_reconnectIfNeeded_afterReconnectAttemptsExhausted_reconnectsImmediatelyAndResetsBackoff() {
        client.connect()
        for _ in 1...4 {
            fakeTransport.simulate(.failed(NSError(domain: "test", code: 1)))
            scheduler.fireNext()
        }
        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1))) // 第 5 次:不再自动重连
        XCTAssertEqual(scheduler.scheduledDelays, [2, 4, 6, 8]) // 4 次耗尽,自动重连已放弃
        let startsBefore = fakeTransport.startCallCount

        client.reconnectIfNeeded()

        XCTAssertEqual(fakeTransport.startCallCount, startsBefore + 1) // 立即重连,不等退避
        fakeTransport.simulate(.failed(NSError(domain: "test", code: 1)))
        XCTAssertEqual(scheduler.scheduledDelays.last, 2) // 退避计数已重置,从 2s 重来
    }

    func test_reconnectIfNeeded_whileConnected_sendsProbeHeartbeatOnly() {
        driveToConnected()
        let framesBefore = fakeTransport.sentFrames.count
        let startsBefore = fakeTransport.startCallCount

        client.reconnectIfNeeded()

        XCTAssertEqual(fakeTransport.startCallCount, startsBefore) // 不重建连接
        XCTAssertEqual(fakeTransport.sentFrames.count, framesBefore + 1) // 多发一个探活 PING
        XCTAssertEqual(fakeTransport.cancelCallCount, 0)
    }

    func test_reconnectIfNeeded_afterUserDisconnect_doesNothing() {
        client.connect()
        client.disconnect()
        let startsBefore = fakeTransport.startCallCount

        client.reconnectIfNeeded()

        XCTAssertEqual(fakeTransport.startCallCount, startsBefore)
    }

    // MARK: - switchHosts

    /// 自建 client：`setUp()` 的 factory 不记录 host，这里要断言选中的 host。
    private func makeRecordingClient(
        hosts: String,
        transports: [FakeTransportConnection],
        recordedHosts: @escaping (String) -> Void
    ) throws -> IMClient {
        var index = 0
        let configuration = IMClientConfiguration(
            hosts: hosts,
            port: 6789,
            userId: "u1",
            token: makeTestToken(),
            clientIdentifier: "device-1"
        )
        return try IMClient(
            configuration: configuration,
            scheduler: scheduler,
            heartbeatManager: HeartbeatManager(),
            transportFactory: { host, _ in
                recordedHosts(host)
                let transport = transports[min(index, transports.count - 1)]
                index += 1
                return transport
            }
        )
    }

    func test_currentHost_isNilBeforeConnectingThenTracksSelectedHost() throws {
        var hosts: [String] = []
        let client = try makeRecordingClient(
            hosts: "host-a:host-b",
            transports: [FakeTransportConnection(), FakeTransportConnection()],
            recordedHosts: { hosts.append($0) }
        )
        XCTAssertNil(client.currentHost)

        client.connect()

        XCTAssertEqual(client.currentHost, "host-a")
        XCTAssertEqual(hosts, ["host-a"])
    }

    func test_switchHosts_cancelsOldTransportAndConnectsToNewHost() throws {
        let oldTransport = FakeTransportConnection()
        let newTransport = FakeTransportConnection()
        var hosts: [String] = []
        let client = try makeRecordingClient(
            hosts: "host-a:host-b",
            transports: [oldTransport, newTransport],
            recordedHosts: { hosts.append($0) }
        )
        client.connect()
        XCTAssertEqual(oldTransport.cancelCallCount, 0)

        try client.switchHosts("pinned-host")

        XCTAssertEqual(oldTransport.cancelCallCount, 1)
        XCTAssertEqual(newTransport.startCallCount, 1)
        XCTAssertEqual(hosts, ["host-a", "pinned-host"])
        XCTAssertEqual(client.currentHost, "pinned-host")
        XCTAssertEqual(client.connectionStatus, .connecting)
    }

    /// 切节点会拆掉一条**活着的** socket，但状态是 `.connected → .connecting`，
    /// 不经过 `.disconnected` 沿。若不手动补一次通知，`IMMessaging` 挂在
    /// `onDisconnected` 上的「把在途远程请求判失败」就不会跑，用户会看着
    /// 菊花空转到各自的超时窗口耗尽。
    func test_switchHosts_notifiesDisconnectedSoInFlightRequestsFailFast() throws {
        let oldTransport = FakeTransportConnection()
        let client = try makeRecordingClient(
            hosts: "host-a",
            transports: [oldTransport, FakeTransportConnection()],
            recordedHosts: { _ in }
        )
        var disconnectedCount = 0
        client.onDisconnected = { disconnectedCount += 1 }
        client.connect()
        oldTransport.simulate(.connected)
        oldTransport.simulateReceivedData(makeConnectAckFrameBytes())
        XCTAssertEqual(client.connectionStatus, .connected)
        XCTAssertEqual(disconnectedCount, 0)

        try client.switchHosts("pinned-host")

        XCTAssertEqual(disconnectedCount, 1)
        // 顶栏不能闪「连接断开」：状态直接进 `.connecting`。
        XCTAssertEqual(client.connectionStatus, .connecting)
    }

    func test_switchHosts_doesNotNotifyDisconnectedWhenItThrows() throws {
        let client = try makeRecordingClient(
            hosts: "host-a",
            transports: [FakeTransportConnection()],
            recordedHosts: { _ in }
        )
        var disconnectedCount = 0
        client.onDisconnected = { disconnectedCount += 1 }
        client.connect()

        XCTAssertThrowsError(try client.switchHosts(""))

        XCTAssertEqual(disconnectedCount, 0)
    }

    func test_switchHosts_singleHostIsUsedForEveryReconnect() throws {
        var hosts: [String] = []
        let client = try makeRecordingClient(
            hosts: "host-a:host-b",
            transports: [FakeTransportConnection(), FakeTransportConnection(), FakeTransportConnection()],
            recordedHosts: { hosts.append($0) }
        )
        client.connect()

        try client.switchHosts("pinned-host")
        // 再发起一次连接，确认单 host 仍只返回它（退避重连路径由
        // `test_switchHosts_resetsBackoffSoAutomaticReconnectsStartOver` 覆盖）
        client.connect()

        XCTAssertEqual(hosts, ["host-a", "pinned-host", "pinned-host"])
    }

    func test_switchHosts_resetsBackoffSoAutomaticReconnectsStartOver() throws {
        var hosts: [String] = []
        let transports = (0..<8).map { _ in FakeTransportConnection() }
        let client = try makeRecordingClient(
            hosts: "host-a",
            transports: transports,
            recordedHosts: { hosts.append($0) }
        )
        client.connect()
        // 耗尽 4 次自动重连额度（`maxAutomaticReconnectAttempts` = 4）
        for _ in 0..<4 {
            (client.currentTransportForTesting as? FakeTransportConnection)?.simulate(.failed(URLError(.timedOut)))
            XCTAssertTrue(scheduler.fireNext())
        }
        // 初次 connect 1 次 + 4 次退避重连
        XCTAssertEqual(hosts.count, 5)

        try client.switchHosts("pinned-host")
        (client.currentTransportForTesting as? FakeTransportConnection)?.simulate(.failed(URLError(.timedOut)))

        // 切换后额度归零，这次失败仍能排到一次自动重连（额度未归零时
        // `scheduleReconnectIfNeeded` 会直接 return，fireNext 就返回 false）
        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(hosts.count, 7)
        XCTAssertEqual(hosts.last, "pinned-host")
    }

    func test_switchHosts_emptyStringThrowsAndLeavesExistingConnectionAlone() throws {
        let transport = FakeTransportConnection()
        let client = try makeRecordingClient(
            hosts: "host-a",
            transports: [transport],
            recordedHosts: { _ in }
        )
        client.connect()

        XCTAssertThrowsError(try client.switchHosts("")) { error in
            XCTAssertEqual(error as? RoundRobinHostSelector.Error, .emptyHostsString)
        }
        XCTAssertEqual(transport.cancelCallCount, 0)
        XCTAssertEqual(client.currentHost, "host-a")
    }
}
