import Foundation
import IMClient
import IMProto

public enum MediaUploadError: Error, Equatable {
    case wireError(MinioUploadURLTracker.TrackerError)
    case requestEncodingFailed
    case invalidUploadURL
    case httpFailure(statusCode: Int)
}

/// Generates the upload key, requests a presigned MinIO URL over the wire,
/// and PUTs the image bytes to it. See this plan's "Reference facts" for
/// the exact key format / `Content-Type` / final-URL-construction details,
/// verified against the real Android client and server.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class MediaUploadService {
    private let imClient: IMClient
    private let tracker: MinioUploadURLTracker
    private let session: URLSession
    private let nowMillis: () -> Int64

    public init(
        imClient: IMClient,
        scheduler: Scheduler = DispatchQueueScheduler(),
        session: URLSession = .shared,
        nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.imClient = imClient
        tracker = MinioUploadURLTracker(scheduler: scheduler)
        self.session = session
        self.nowMillis = nowMillis
        imClient.register(MinioUploadURLHandler(tracker: tracker))
    }

    /// Uploads `data` (a full-size image — thumbnail generation is Plan I's
    /// job, see this plan's "Reference facts") and returns the final
    /// remote URL string to embed in an outgoing image message's
    /// `remoteURL` field.
    public func uploadImage(_ data: Data, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
        let key = "1-\(imClient.userId)-\(nowMillis()).png"

        var wireRequest = Im_GetMinioUploadUrlRequest()
        wireRequest.type = 1
        wireRequest.key = key
        guard let body = try? wireRequest.serializedData() else {
            completion(.failure(.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gmurl, body: body)

        tracker.track(wireMessageId: wireMessageId) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(.wireError(error)))
            case .success(let uploadResult):
                Task { await self.performUpload(data: data, uploadResult: uploadResult, key: key, completion: completion) }
            }
        }
    }

    private func performUpload(
        data: Data,
        uploadResult: Im_GetMinioUploadUrlResult,
        key: String,
        completion: @escaping (Result<String, MediaUploadError>) -> Void
    ) async {
        guard let url = URL(string: uploadResult.url) else {
            completion(.failure(.invalidUploadURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/binary", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            completion(.failure(.httpFailure(statusCode: -1)))
            return
        }
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            completion(.failure(.httpFailure(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)))
            return
        }

        completion(.success("\(uploadResult.domain)/\(key)"))
    }
}
