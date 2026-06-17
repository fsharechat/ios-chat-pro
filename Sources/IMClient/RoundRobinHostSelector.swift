import Foundation

/// Cycles through a `:`-separated host list deterministically (never
/// randomly) on each call to `nextHost()` — the cycling/wraparound logic
/// (`index = (index + 1) % count`) is an exact port of
/// `com.comsince.github.util.RoundRobinHostSelector.getNextHost()`.
///
/// The `:`-splitting step intentionally diverges from Java's
/// `String.split(":")`: Swift's `split(separator:)` drops empty segments
/// (e.g. from `"a::b"` or a leading/trailing `:`), where Java would keep
/// them. This is safer (never returns an empty-string host) and doesn't
/// matter for real server-config host strings like Android's
/// `Config.IM_SERVER_HOST` example
/// (`"backend-tcp.fsharechat.cn:backend-tcp-s2.fsharechat.cn"`), which
/// never contain empty segments.
public final class RoundRobinHostSelector {
    public enum Error: Swift.Error, Equatable {
        case emptyHostsString
    }

    private let hosts: [String]
    private var index = 0

    public init(hostsString: String) throws {
        let trimmed = hostsString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.emptyHostsString }
        hosts = trimmed.split(separator: ":").map(String.init)
    }

    public func nextHost() -> String {
        let host = hosts[index]
        index = (index + 1) % hosts.count
        return host
    }
}
