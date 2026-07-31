import XCTest
import Network
import Foundation
@testable import IMClient

final class HostLatencyProbeTests: XCTestCase {
    /// 起一个真实的本地 TCP listener，返回它实际绑定到的端口。
    /// 用进程内 listener 而不是线上服务器：结果确定、不依赖外网、不受
    /// 被测机器的代理设置影响。
    private func startLocalListener() throws -> (listener: NWListener, port: UInt16) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        return (listener, listener.port!.rawValue)
    }

    func test_probeAll_localListener_reportsNonNegativeLatency() throws {
        let (listener, port) = try startLocalListener()
        defer { listener.cancel() }

        let done = expectation(description: "probe finished")
        var received: (String, HostLatencyProbe.ProbeResult)?
        _ = HostLatencyProbe.probeAll(hosts: ["127.0.0.1"], port: port) { host, result in
            received = (host, result)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(received?.0, "127.0.0.1")
        guard case .latency(let milliseconds)? = received?.1 else {
            return XCTFail("expected .latency, got \(String(describing: received?.1))")
        }
        XCTAssertGreaterThanOrEqual(milliseconds, 0)
    }

    /// 拿一个**确定无人占用**的本地端口：`bind()` 到端口 0 让内核分配一个空闲
    /// 端口，读出端口号后立刻 `close()` 释放。此后到该端口的连接会被内核以
    /// `ECONNREFUSED` 立即拒绝，探测必然拿到 `.unreachable`。
    ///
    /// 另外两个"看起来更自然"的做法都实测过，都不行：
    /// - **起 `NWListener` 再 `cancel()`**：`cancel()` 是异步的，从调用到内核真正
    ///   撤销监听之间有几毫秒窗口，落在窗口里的 connect 会意外成功——实测偶发
    ///   失败率 30%~70%。
    /// - **`bind()` 但不 `listen()`、也不 `close()`**：macOS 内核对这种"被占用但
    ///   无监听队列"的端口收到 SYN 时是**静默丢弃**而非回 RST，探测拿到的是
    ///   `.timedOut`——实测 100% 复现，是稳定的错误答案。
    ///
    /// 裸 `close()` 是同步的，没有窗口；实测连续 5 次全部稳定得到 `ECONNREFUSED`。
    private func reserveClosedPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw XCTSkip("socket() failed, errno=\(errno)") }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // 让内核分配一个空闲端口
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var bindResult: Int32 = -1
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                // 必须写全 `Darwin.bind`：`XCTestCase` 在 macOS 上继承自 `NSObject`，
                // 其 Cocoa Bindings 的 `bind(_:to:withKeyPath:options:)` 会遮蔽全局
                // 的 `bind`，裸写会编译失败。
                bindResult = Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw XCTSkip("bind() failed, errno=\(errno)")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var nameResult: Int32 = -1
        withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                nameResult = getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        close(descriptor) // 同步释放，端口随即无人占用
        guard nameResult == 0 else { throw XCTSkip("getsockname() failed, errno=\(errno)") }
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    /// 没有任何进程占用的本地端口 → 内核立刻回 RST，必须报 `.unreachable`，
    /// 不能报成耗时。这条是"假绿灯"的核心防线。
    func test_probeAll_closedLocalPort_reportsUnreachable() throws {
        let port = try reserveClosedPort()

        let done = expectation(description: "probe finished")
        var result: HostLatencyProbe.ProbeResult?
        _ = HostLatencyProbe.probeAll(hosts: ["127.0.0.1"], port: port) { _, probeResult in
            result = probeResult
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result, .unreachable)
    }

    /// 192.0.2.1 是 RFC 5737 的 TEST-NET-1，保证不可路由：连接既不会成功
    /// 也不会立刻被拒，正好走超时分支。
    ///
    /// 这条用例同时是"没走系统代理"的回归防线——若实现被改回
    /// `NWConnection`，在配了代理的机器上这里会拿到 `.latency` 而失败。
    func test_probeAll_unroutableAddress_timesOut() {
        let done = expectation(description: "probe finished")
        var result: HostLatencyProbe.ProbeResult?
        _ = HostLatencyProbe.probeAll(hosts: ["192.0.2.1"], port: 6789, timeout: 1) { _, probeResult in
            result = probeResult
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result, .timedOut)
    }

    func test_probeAll_unresolvableHostname_reportsUnresolved() {
        let done = expectation(description: "probe finished")
        var result: HostLatencyProbe.ProbeResult?
        _ = HostLatencyProbe.probeAll(
            hosts: ["no-such-host.invalid"],
            port: 6789,
            timeout: 3
        ) { _, probeResult in
            result = probeResult
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(result, .unresolved)
    }

    func test_cancel_suppressesTheCallback() {
        let didCallBack = expectation(description: "callback must not fire")
        didCallBack.isInverted = true
        let handle = HostLatencyProbe.probeAll(hosts: ["192.0.2.1"], port: 6789, timeout: 0.5) { _, _ in
            didCallBack.fulfill()
        }
        handle.cancel()

        wait(for: [didCallBack], timeout: 2)
    }

    func test_probeAll_reportsEachHostSeparately() throws {
        let (listener, port) = try startLocalListener()
        defer { listener.cancel() }

        let done = expectation(description: "both hosts reported")
        done.expectedFulfillmentCount = 2
        var reported: [String] = []
        _ = HostLatencyProbe.probeAll(hosts: ["127.0.0.1", "localhost"], port: port) { host, _ in
            reported.append(host)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(Set(reported), ["127.0.0.1", "localhost"])
    }

    /// 构造一个指向 `127.0.0.1:port` 的 `ResolvedAddress`。
    ///
    /// 多地址遍历的三条不变量以前是靠「`localhost` 在本机恰好解析成 ::1 + 127.0.0.1」
    /// 来触发的，换台机器解析顺序一变就整片 `XCTSkip`——覆盖率静默归零而不是报红。
    /// 改成直接注入地址数组后，三条不变量与 DNS 环境彻底解耦。
    private func loopbackAddress(port: UInt16) -> HostLatencyProbe.ResolvedAddress {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var storage = sockaddr_storage()
        memcpy(&storage, &address, MemoryLayout<sockaddr_in>.size)
        return HostLatencyProbe.ResolvedAddress(
            family: AF_INET,
            socketType: SOCK_STREAM,
            protocolNumber: IPPROTO_TCP,
            storage: storage,
            length: socklen_t(MemoryLayout<sockaddr_in>.size)
        )
    }

    /// 指向不可路由的 TEST-NET-1（RFC 5737），连接必然挂到超时。
    private func unroutableAddress(port: UInt16) -> HostLatencyProbe.ResolvedAddress {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("192.0.2.1")
        var storage = sockaddr_storage()
        memcpy(&storage, &address, MemoryLayout<sockaddr_in>.size)
        return HostLatencyProbe.ResolvedAddress(
            family: AF_INET,
            socketType: SOCK_STREAM,
            protocolNumber: IPPROTO_TCP,
            storage: storage,
            length: socklen_t(MemoryLayout<sockaddr_in>.size)
        )
    }

    /// 头节点不通时必须继续试后面的地址。只试头节点的旧实现会报
    /// `.unreachable`——App 明明连得上却显示不可达，正是设计文档划的红线。
    func test_probeOnce_addresses_fallsThroughFirstFailureToTheReachableOne() throws {
        let (listener, listeningPort) = try startLocalListener()
        defer { listener.cancel() }
        let closedPort = try reserveClosedPort()

        let result = HostLatencyProbe.probeOnce(
            addresses: [loopbackAddress(port: closedPort), loopbackAddress(port: listeningPort)],
            timeoutMilliseconds: 2000
        )

        guard case .latency(let milliseconds) = result else {
            return XCTFail("expected .latency, got \(result)")
        }
        XCTAssertGreaterThanOrEqual(milliseconds, 0)
    }

    /// 已经连通就不该再试后面的地址——否则「第一个通、第二个超时」会白等。
    func test_probeOnce_addresses_stopsAtTheFirstReachableAddress() throws {
        let (listener, listeningPort) = try startLocalListener()
        defer { listener.cancel() }

        let start = Date()
        let result = HostLatencyProbe.probeOnce(
            addresses: [loopbackAddress(port: listeningPort), unroutableAddress(port: 6789)],
            timeoutMilliseconds: 2000
        )
        let elapsed = Date().timeIntervalSince(start)

        guard case .latency = result else {
            return XCTFail("expected .latency, got \(result)")
        }
        // 若没有提前 return，第二个地址会把这里拖到 2 秒。
        XCTAssertLessThan(elapsed, 0.5)
    }

    /// 全部失败时返回**最后一次**的失败结果，而不是被中途某个地址覆盖。
    ///
    /// 这里刻意让最后一个地址走 `.timedOut`、前一个走 `.unreachable`：两者都
    /// 不等于 `probeOnce` 内部 `lastResult` 的初值，所以「循环没跑」「返回值
    /// 写死」都会让这条用例报红。
    func test_probeOnce_addresses_keepsTheLastFailureKind() throws {
        let closedPort = try reserveClosedPort()

        let result = HostLatencyProbe.probeOnce(
            addresses: [loopbackAddress(port: closedPort), unroutableAddress(port: 6789)],
            timeoutMilliseconds: 1000
        )

        XCTAssertEqual(result, .timedOut)
    }

    /// 反过来：全部地址都被**快速拒绝**时，结果必须是 `.unreachable`。
    ///
    /// 两个地址都用无人占用的本地端口——它们各自被内核立刻 RST，不吃预算，
    /// 所以循环能真正跑完两轮。`.unreachable` 不等于 `lastResult` 的初值
    /// `.timedOut`，因此「循环一次没跑」会让这条报红。与上一条合起来，两个
    /// 方向都锁死了。
    ///
    /// 注意不能写成 `[unroutable, closed]`：不可路由地址会吃满整个预算，
    /// 循环随即因超预算 break，根本轮不到第二个地址——那是共享预算的正确
    /// 行为，不是缺陷。
    func test_probeOnce_addresses_allRefusedFastYieldsUnreachable() throws {
        let firstClosedPort = try reserveClosedPort()
        let secondClosedPort = try reserveClosedPort()

        let result = HostLatencyProbe.probeOnce(
            addresses: [loopbackAddress(port: firstClosedPort), loopbackAddress(port: secondClosedPort)],
            timeoutMilliseconds: 800
        )

        XCTAssertEqual(result, .unreachable)
    }

    /// `timeoutMilliseconds` 是**总**预算，不是每个地址一份。
    /// 三个都会超时的地址、总预算 600ms —— 每地址一份的实现会跑满 1.8 秒。
    func test_probeOnce_addresses_sharesOneTimeoutBudgetAcrossAllAddresses() {
        let addresses = [
            unroutableAddress(port: 6789),
            unroutableAddress(port: 6790),
            unroutableAddress(port: 6791),
        ]

        let start = Date()
        let result = HostLatencyProbe.probeOnce(addresses: addresses, timeoutMilliseconds: 600)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result, .timedOut)
        // 总预算 0.6s，留足调度余量；每地址一份的实现在这里是 ~1.8s。
        XCTAssertLessThan(elapsed, 1.2)
    }

    func test_probeOnce_emptyAddressList_reportsUnresolved() {
        XCTAssertEqual(HostLatencyProbe.probeOnce(addresses: [], timeoutMilliseconds: 500), .unresolved)
    }

    /// `resolve` 对无法解析的域名返回 nil，`probeOnce(host:)` 据此报 `.unresolved`。
    func test_resolve_unresolvableHostnameReturnsNil() {
        XCTAssertNil(HostLatencyProbe.resolve(host: "no-such-host.invalid", port: 6789))
    }

    /// `resolve` 对 IPv4 字面量恰好给出一个可用地址，且字段被完整拷贝。
    func test_resolve_ipv4LiteralYieldsOneUsableAddress() throws {
        let addresses = try XCTUnwrap(HostLatencyProbe.resolve(host: "127.0.0.1", port: 6789))

        XCTAssertEqual(addresses.count, 1)
        XCTAssertEqual(addresses[0].family, AF_INET)
        XCTAssertEqual(addresses[0].length, socklen_t(MemoryLayout<sockaddr_in>.size))
    }

    func test_probeAll_deliversCallbacksOnTheMainQueue() throws {
        let (listener, port) = try startLocalListener()
        defer { listener.cancel() }

        let done = expectation(description: "probe finished")
        var wasMainQueue = false
        _ = HostLatencyProbe.probeAll(hosts: ["127.0.0.1"], port: port) { _, _ in
            wasMainQueue = Thread.isMainThread
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertTrue(wasMainQueue)
    }
}
