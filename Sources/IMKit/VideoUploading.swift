import Foundation
import IMMedia

/// Narrow interface `ConversationViewModel` depends on instead of the
/// concrete `MediaUploadService` — same decoupling-for-testability pattern
/// as `ImageUploading`/`VoiceUploading`.
public protocol VideoUploading: AnyObject {
    func uploadVideo(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void)
}

extension MediaUploadService: VideoUploading {}
