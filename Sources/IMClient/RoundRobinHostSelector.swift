import Foundation

/// Byte-for-byte port of `com.comsince.github.util.RoundRobinHostSelector`:
/// parses a `:`-separated host list and cycles through it deterministically
/// (never randomly) on each call to `nextHost()`.
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
