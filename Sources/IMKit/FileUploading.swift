import Foundation
import IMMedia

/// Narrow interface for file upload — same decoupling-for-testability pattern
/// as `ImageUploading`/`ImageUploading.swift`.
/// Note: file upload uses mediaType=4; the wire message type for file messages is 5 (different).
public protocol FileUploading: AnyObject {
    func uploadFile(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void)
}

extension MediaUploadService: FileUploading {}
