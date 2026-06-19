import Foundation
import IMMedia

/// Narrow interface `ConversationViewModel` depends on instead of the
/// concrete `MediaUploadService` — same decoupling-for-testability pattern
/// as `ContactInfoFetching`/`ContactSyncService`.
public protocol ImageUploading: AnyObject {
    func uploadImage(_ data: Data, completion: @escaping (Result<String, MediaUploadError>) -> Void)
}

extension MediaUploadService: ImageUploading {}
