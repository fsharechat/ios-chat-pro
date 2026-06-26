import Foundation
import IMMedia

/// Narrow interface for voice upload — same decoupling-for-testability pattern
/// as `ImageUploading`/`ImageUploading.swift`.
public protocol VoiceUploading: AnyObject {
    func uploadVoice(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void)
}

extension MediaUploadService: VoiceUploading {}
