import Foundation
import CryptoKit

/// Fetches and caches full-size message images from a URL string. Returns
/// raw `Data`, not `UIImage` — `UIKit` isn't available when this target
/// builds for `swift test` on macOS; the `App` target decodes the bytes.
public protocol ImageLoading {
    func loadImageData(from urlString: String) async -> Data?
}

/// Two-level cache: `NSCache` in memory + files on disk under
/// `Caches/ImageCache/<SHA256(urlString)>`. Message rows store the fixed
/// post-upload `remoteMediaUrl`, so the URL string is a stable cache key.
///
/// **Threading contract:** like `AvatarLoader`, no internal locking — call
/// from the main queue. `NSCache` single operations are thread-safe and the
/// disk write is atomic, so the worst concurrent-miss outcome is a redundant
/// fetch of the same bytes, accepted for the same reasons documented on
/// `AvatarLoader`.
public final class ImageLoader: ImageLoading {
    public static let shared = ImageLoader()

    private let session: URLSession
    private let memoryCache = NSCache<NSString, NSData>()
    private let diskDirectory: URL

    public init(session: URLSession = .shared, diskDirectory: URL? = nil) {
        self.session = session
        self.diskDirectory = diskDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
    }

    public func loadImageData(from urlString: String) async -> Data? {
        let key = urlString as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached as Data
        }

        let fileURL = diskDirectory.appendingPathComponent(Self.cacheFileName(for: urlString))
        if let diskData = try? Data(contentsOf: fileURL) {
            memoryCache.setObject(diskData as NSData, forKey: key)
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

        memoryCache.setObject(result.0 as NSData, forKey: key)
        try? result.0.write(to: fileURL, options: .atomic)
        return result.0
    }

    static func cacheFileName(for urlString: String) -> String {
        SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
