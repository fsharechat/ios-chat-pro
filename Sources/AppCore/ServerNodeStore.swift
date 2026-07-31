import Foundation

/// 「用户固定了哪个 IM 节点」的唯一读写入口，形状照 `ThemePreferenceStore`。
///
/// 固定单个节点时只把该 host 交给 `IMClient`，`RoundRobinHostSelector` 拿到
/// 单 host 时 `index = (index + 1) % 1` 恒为 0、永远返回它——固定语义因此
/// 无需改动轮询算法。未固定时交出全部 host，恢复轮询。
///
/// **Threading contract:** safe to call from any queue — `UserDefaults`
/// serializes its own reads/writes internally, same as `ThemePreferenceStore`.
public final class ServerNodeStore {
    private static let key = "AppCore.pinnedIMHost"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 用户固定的 host。未固定，或固定值已不在节点表中（版本升级后集群
    /// 调整），都返回 nil，即「自动轮询」。
    public func pinnedHost(nodes: [AppConfig.ServerNode]) -> String? {
        guard let stored = defaults.string(forKey: Self.key),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              nodes.contains(where: { $0.host == stored }) else { return nil }
        return stored
    }

    /// 传给 `IMClient` 的 `:` 分隔 host 串：固定了返回单 host，否则返回全部。
    public func currentHostSpec(nodes: [AppConfig.ServerNode]) -> String {
        pinnedHost(nodes: nodes) ?? nodes.map(\.host).joined(separator: ":")
    }

    public func pin(_ host: String) {
        defaults.set(host, forKey: Self.key)
    }

    public func unpin() {
        defaults.removeObject(forKey: Self.key)
    }
}
