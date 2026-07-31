import Foundation

/// 测「到 `host` + `port` 建立一条 TCP 连接要多久」。
///
/// 刻意用与 IM 完全相同的 host 和端口，避免出现「ICMP 通但 IM 端口不通」的
/// 假绿灯。探测连接一建立就立刻 `close()`，不发送任何协议数据。
///
/// **为什么是裸 BSD socket 而不是 `NWConnection`：** `NWConnection` 遵守系统
/// 代理设置。在配了 HTTP/SOCKS 代理或 VPN 的设备上，它连的是代理而不是目标
/// 节点，`.ready` 会在十几毫秒内到达且与目标是否可达无关——2026-07-31 实测：
/// 一台开了 `SOCKS 127.0.0.1:1089` 的 Mac 对不可路由的 `192.0.2.1:6789` 探测
/// 得到 `.ready`(15ms)，同机裸 socket 正确超时。那会让所有节点都显示成 ~1ms，
/// 是错误答案而不是慢答案。这里与 Android `HostLatencyProbe.probeOnce()` 的
/// `Socket.connect(new InetSocketAddress(host, port), 2000)` 保持同一实现方式。
///
/// **Threading contract:** 阻塞的 connect 跑在后台队列，结果一律投递回主队列，
/// 与 `IMClient` 的单队列约定一致；调用方必须在主队列调用 `probeAll` /
/// `Handle.cancel()`。`Handle.isCancelled` 只在主队列读写，因此无需加锁——
/// 与全仓库「无内部锁」的约定一致。
public enum HostLatencyProbe {
    public static let timeoutSeconds: TimeInterval = 2

    public enum ProbeResult: Equatable {
        /// 建连耗时，毫秒。
        case latency(Int)
        /// 超时窗口内未建立连接。
        case timedOut
        /// 域名无法解析。
        case unresolved
        /// 连接被拒绝或网络不可达。
        case unreachable
    }

    /// 一批在途探测。调用方必须在界面销毁时 `cancel()`，否则回调会打到
    /// 已销毁的 view 上。
    ///
    /// `cancel()` 不中断已经发出的 connect —— 那需要跨线程操作 fd，会把锁
    /// 引回来。阻塞的 connect 最多挂到 `timeout` 就自己结束，届时结果在
    /// 主队列上被这个标志丢弃，代价是一个短暂的空转线程，换来的是零锁。
    public final class Handle {
        fileprivate private(set) var isCancelled = false

        public func cancel() {
            isCancelled = true
        }
    }

    /// 并发探测多个 host，每个 host 出结果就回调一次（主队列，顺序不保证）。
    @discardableResult
    public static func probeAll(
        hosts: [String],
        port: UInt16,
        timeout: TimeInterval = timeoutSeconds,
        onResult: @escaping (String, ProbeResult) -> Void
    ) -> Handle {
        let handle = Handle()
        let timeoutMilliseconds = Int32(max(1, timeout * 1000))
        for host in hosts {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = probeOnce(host: host, port: port, timeoutMilliseconds: timeoutMilliseconds)
                DispatchQueue.main.async {
                    guard !handle.isCancelled else { return }
                    onResult(host, result)
                }
            }
        }
        return handle
    }

    /// 一个已解析出的目标地址，值类型。
    ///
    /// 刻意把 `getaddrinfo` 的结果拷成值而不是传 `addrinfo` 指针：一来
    /// `addrinfo.ai_addr` 指向的内存归 `freeaddrinfo` 管，值语义杜绝了释放后
    /// 误用；二来遍历逻辑因此可以被单测注入确定的多地址组合——真实 DNS 解析
    /// 出几个地址、谁在前，随机器配置而变，拿它做断言等于把测试押在环境上。
    struct ResolvedAddress {
        let family: Int32
        let socketType: Int32
        let protocolNumber: Int32
        /// `sockaddr` 的字节拷贝。用 `sockaddr_storage` 而非 `[UInt8]` 是为了
        /// 对齐——重绑定到 `sockaddr` 需要它，字节数组给不了这个保证。
        let storage: sockaddr_storage
        let length: socklen_t
    }

    /// 解析 host，返回全部候选地址（顺序即 `getaddrinfo` 给的顺序）。
    /// 解析失败或没有任何地址时返回 nil。
    static func resolve(host: String, port: UInt16) -> [ResolvedAddress]? {
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
        guard getaddrinfo(host, String(port), &hints, &addressList) == 0 else { return nil }
        defer { freeaddrinfo(addressList) }

        var addresses: [ResolvedAddress] = []
        var nextAddress = addressList
        while let address = nextAddress {
            if let socketAddress = address.pointee.ai_addr,
               address.pointee.ai_addrlen > 0,
               Int(address.pointee.ai_addrlen) <= MemoryLayout<sockaddr_storage>.size {
                var storage = sockaddr_storage()
                memcpy(&storage, socketAddress, Int(address.pointee.ai_addrlen))
                addresses.append(ResolvedAddress(
                    family: address.pointee.ai_family,
                    socketType: address.pointee.ai_socktype,
                    protocolNumber: address.pointee.ai_protocol,
                    storage: storage,
                    length: address.pointee.ai_addrlen
                ))
            }
            nextAddress = address.pointee.ai_next
        }
        return addresses.isEmpty ? nil : addresses
    }

    /// 同步探测一个 host，阻塞调用线程，**不得在主队列调用**。
    static func probeOnce(host: String, port: UInt16, timeoutMilliseconds: Int32) -> ProbeResult {
        guard let addresses = resolve(host: host, port: port) else { return .unresolved }
        return probeOnce(addresses: addresses, timeoutMilliseconds: timeoutMilliseconds)
    }

    /// 依次尝试 `addresses`，任一连通即返回其耗时；全部失败时返回**最后一次**
    /// 的失败结果。阻塞调用线程，**不得在主队列调用**。
    ///
    /// 为什么要遍历而不是只试头节点：一个 host 配了多条 A 记录、或同时有 A 与
    /// AAAA 时，头节点不通不代表节点不可达——IM 自己走的 `NWConnection` 会
    /// happy-eyeballs 到能通的那个地址，只试头节点会让弹窗显示「不可达」而 App
    /// 其实连得好好的，正是设计文档划的红线：错误答案比慢答案更糟。
    ///
    /// 超时语义：总预算就是 `timeoutMilliseconds`，每个地址分到的是**剩余
    /// 时间**而不是各自一份完整超时，否则「3 个地址 × 2 秒」会把 UI 卡满 6 秒。
    /// 代价是排在后面的地址可能只剩很短的窗口甚至轮不上——此时沿用前一个地址
    /// 的失败结果，保住 `.timedOut` / `.unreachable` 的区分度。
    static func probeOnce(addresses: [ResolvedAddress], timeoutMilliseconds: Int32) -> ProbeResult {
        guard !addresses.isEmpty else { return .unresolved }
        let budgetMilliseconds = UInt64(max(0, timeoutMilliseconds))
        let deadline = DispatchTime.now().uptimeNanoseconds &+ budgetMilliseconds &* 1_000_000
        var lastResult: ProbeResult = .timedOut
        for address in addresses {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let remainingMilliseconds = Int32(min(UInt64(Int32.max), max(1, (deadline - now) / 1_000_000)))
            lastResult = connectOnce(address: address, timeoutMilliseconds: remainingMilliseconds)
            if case .latency = lastResult { return lastResult }
        }
        return lastResult
    }

    /// 对单个已解析出的地址做一次非阻塞 connect，返回耗时或失败原因。
    private static func connectOnce(address: ResolvedAddress, timeoutMilliseconds: Int32) -> ProbeResult {
        let descriptor = socket(address.family, address.socketType, address.protocolNumber)
        guard descriptor >= 0 else { return .unreachable }
        defer { close(descriptor) }

        // 非阻塞 connect + poll：阻塞式 connect 的超时由内核决定（可达 75 秒），
        // 没法压到我们要的 2 秒。
        var flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return .unreachable }
        flags |= O_NONBLOCK
        guard fcntl(descriptor, F_SETFL, flags) >= 0 else { return .unreachable }

        var storage = address.storage
        let start = DispatchTime.now()
        let connectResult = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, address.length)
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else { return .unreachable }
            var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptorSet, 1, timeoutMilliseconds)
            if ready == 0 { return .timedOut }
            guard ready > 0 else { return .unreachable }
            // poll 报可写只说明 connect 有了结论，成败要看 SO_ERROR ——
            // 被 RST 拒绝的连接同样会让 fd 变可写。
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else { return .unreachable }
        }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return .latency(Int(elapsedNanoseconds / 1_000_000))
    }
}
