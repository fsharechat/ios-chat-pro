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

    /// 只监听 IPv4 `127.0.0.1` 的裸 socket listener，返回它绑定到的端口。
    /// 与 `startLocalListener()` 的区别：那个用 `NWListener(on: .any)`，是双栈；
    /// 这里刻意只占 IPv4，好让 `localhost` 的 IPv6 地址（`::1`）必然被拒。
    private func startIPv4OnlyListener() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw XCTSkip("socket() failed, errno=\(errno)") }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var bindResult: Int32 = -1
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bindResult = Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw XCTSkip("bind()/listen() failed, errno=\(errno)")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var nameResult: Int32 = -1
        withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                nameResult = getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            close(descriptor)
            throw XCTSkip("getsockname() failed, errno=\(errno)")
        }
        return (descriptor, UInt16(bigEndian: boundAddress.sin_port))
    }

    /// `getaddrinfo` 为 `host` 解析出的地址族序列，用来确认本机的解析顺序
    /// 确实是「IPv6 在前」——否则这条用例根本走不到 `ai_next` 分支。
    private func resolvedAddressFamilies(host: String, port: UInt16) -> [Int32] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var addressList: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &addressList) == 0 else { return [] }
        defer { freeaddrinfo(addressList) }
        var families: [Int32] = []
        var next = addressList
        while let address = next {
            families.append(address.pointee.ai_family)
            next = address.pointee.ai_next
        }
        return families
    }

    /// 多地址遍历：`localhost` 解析出 `::1` 和 `127.0.0.1` 两条，而 listener
    /// 只占 IPv4，于是头节点 `::1` 必被拒。只试头节点的旧实现会报
    /// `.unreachable`（App 明明连得上却显示不可达——设计文档的红线）；
    /// 遍历 `ai_next` 后必须落到 `127.0.0.1` 上拿到耗时。
    func test_probeAll_multipleResolvedAddresses_fallsThroughToTheReachableOne() throws {
        let (descriptor, port) = try startIPv4OnlyListener()
        defer { close(descriptor) }

        let families = resolvedAddressFamilies(host: "localhost", port: port)
        guard families.count >= 2, families.first == AF_INET6 else {
            throw XCTSkip("本机 localhost 未解析成「IPv6 在前 + 多地址」(\(families))，无法构造该分支")
        }

        let done = expectation(description: "probe finished")
        var result: HostLatencyProbe.ProbeResult?
        _ = HostLatencyProbe.probeAll(hosts: ["localhost"], port: port) { _, probeResult in
            result = probeResult
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        guard case .latency(let milliseconds)? = result else {
            return XCTFail("expected .latency, got \(String(describing: result))")
        }
        XCTAssertGreaterThanOrEqual(milliseconds, 0)
    }

    /// 全部地址都不通时，返回的是**最后一次**的失败结果，而不是被中途某个
    /// 地址的结果覆盖——`.timedOut` 与 `.unreachable` 的区分度要保住。
    func test_probeAll_allAddressesFail_keepsTheLastFailureKind() throws {
        let port = try reserveClosedPort()

        let families = resolvedAddressFamilies(host: "localhost", port: port)
        guard families.count >= 2 else {
            throw XCTSkip("本机 localhost 只解析出 \(families.count) 个地址，无法构造该分支")
        }

        let done = expectation(description: "probe finished")
        var result: HostLatencyProbe.ProbeResult?
        _ = HostLatencyProbe.probeAll(hosts: ["localhost"], port: port) { _, probeResult in
            result = probeResult
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result, .unreachable)
    }

    /// 遍历多地址后，`timeoutMilliseconds` 仍是**总**预算而不是每地址一份：
    /// 这条守住「不得把 UI 卡成 地址数 × timeout」。超时地址只能用不可路由的
    /// TEST-NET-1（单地址），所以这里验的是总预算这条不变量本身。
    func test_probeOnce_unreachableHost_staysWithinTheTotalTimeoutBudget() {
        let start = Date()
        let result = HostLatencyProbe.probeOnce(host: "192.0.2.1", port: 6789, timeoutMilliseconds: 500)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(elapsed, 1.5)
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
