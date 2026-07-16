import Foundation

/// Fetches and caches avatar image bytes from a URL string.
/// Returns raw `Data`, not `UIImage` — `UIKit` isn't available when this
/// target builds for `swift test` on macOS; the `App` target decodes the
/// bytes into an image.
///
/// Two-level cache like `ImageLoader`: `NSCache` in memory + files on disk
/// under `Caches/AvatarCache/<SHA256(urlString)>`, so avatars survive a cold
/// start instead of re-downloading on every launch.
public protocol AvatarLoading {
    func loadAvatarData(from urlString: String) async -> Data?

    /// Synchronous cache-only lookup. Returns the bytes immediately when the
    /// URL is already in the in-memory cache, `nil` otherwise — never touches
    /// the network. Lets UI set a cached avatar in the same frame it is
    /// configured, instead of flashing a placeholder for one runloop tick
    /// while an async cache hit round-trips through a `Task`.
    func cachedAvatarData(from urlString: String) -> Data?
}

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking. Unlike most of those types, the consequence here is
/// benign rather than a correctness hazard: `NSCache`'s individual
/// `object(forKey:)`/`setObject(forKey:)` calls are each thread-safe, so
/// there's no crash or data corruption risk. But because the cache check
/// and the network fetch aren't combined into one atomic operation, two
/// near-simultaneous `loadAvatarData` calls for the same not-yet-cached URL
/// can each miss the cache and both hit the network, redundantly fetching
/// the same bytes. This is accepted for Phase 1 rather than adding
/// in-flight-request deduplication, which would be unnecessary complexity
/// for the actual usage pattern (a handful of avatar loads per screen, not
/// a high-volume hot path).
public final class AvatarLoader: AvatarLoading {
    public static let shared = AvatarLoader()

    private let session: URLSession
    private let cache = NSCache<NSString, NSData>()
    private let diskDirectory: URL

    public init(session: URLSession = .shared, diskDirectory: URL? = nil) {
        self.session = session
        self.diskDirectory = diskDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AvatarCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
    }

    public func cachedAvatarData(from urlString: String) -> Data? {
        cache.object(forKey: urlString as NSString) as Data?
    }

    public func loadAvatarData(from urlString: String) async -> Data? {
        if let cached = cachedAvatarData(from: urlString) {
            return cached
        }

        let fileURL = diskDirectory.appendingPathComponent(ImageLoader.cacheFileName(for: urlString))
        if let diskData = try? Data(contentsOf: fileURL) {
            cache.setObject(diskData as NSData, forKey: urlString as NSString)
            return diskData
        }

        guard let url = URL(string: urlString) else { return nil }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(from: url)
        } catch {
            return nil
        }
        guard let httpResponse = result.1 as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        cache.setObject(result.0 as NSData, forKey: urlString as NSString)
        try? result.0.write(to: fileURL, options: .atomic)
        return result.0
    }
}
