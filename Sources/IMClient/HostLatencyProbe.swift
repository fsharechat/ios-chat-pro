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

    /// 同步探测一个 host，阻塞调用线程，**不得在主队列调用**。
    static func probeOnce(host: String, port: UInt16, timeoutMilliseconds: Int32) -> ProbeResult {
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
        guard getaddrinfo(host, String(port), &hints, &addressList) == 0,
              let address = addressList else { return .unresolved }
        defer { freeaddrinfo(addressList) }

        let descriptor = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
        guard descriptor >= 0 else { return .unreachable }
        defer { close(descriptor) }

        // 非阻塞 connect + poll：阻塞式 connect 的超时由内核决定（可达 75 秒），
        // 没法压到我们要的 2 秒。
        var flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return .unreachable }
        flags |= O_NONBLOCK
        guard fcntl(descriptor, F_SETFL, flags) >= 0 else { return .unreachable }

        let start = DispatchTime.now()
        if connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen) != 0 {
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
