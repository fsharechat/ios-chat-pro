import Foundation

/// Fetches and in-memory-caches avatar image bytes from a URL string.
/// Returns raw `Data`, not `UIImage` — `UIKit` isn't available when this
/// target builds for `swift test` on macOS; the `App` target decodes the
/// bytes into an image.
public protocol AvatarLoading {
    func loadAvatarData(from urlString: String) async -> Data?
}

public final class AvatarLoader: AvatarLoading {
    private let session: URLSession
    private let cache = NSCache<NSString, NSData>()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func loadAvatarData(from urlString: String) async -> Data? {
        if let cached = cache.object(forKey: urlString as NSString) {
            return cached as Data
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
        return result.0
    }
}
