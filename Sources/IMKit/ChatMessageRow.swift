import Foundation
import IMStorage

/// A message still uploading (or that failed to upload) its image data —
/// deliberately never written to `IMStorage`: until the upload succeeds
/// there's no `remoteURL` yet, and persisting a row without one would be an
/// ambiguous half-sent state. Lives only in `ConversationViewModel`'s
/// in-memory state until upload succeeds, at which point
/// `MessageSending.sendImage(...)` inserts the real, persisted row and this
/// one is removed.
public struct PendingImageUpload: Equatable, Hashable {
    public enum State: Equatable, Hashable {
        case uploading
        case failed
    }

    public let id: UUID
    public let thumbnail: Data
    public let fullImageData: Data
    public var state: State

    public init(id: UUID, thumbnail: Data, fullImageData: Data, state: State) {
        self.id = id
        self.thumbnail = thumbnail
        self.fullImageData = fullImageData
        self.state = state
    }
}

/// Flattened, `Hashable` presentation of a `StoredMessage` — same
/// flattening rationale as `ConversationRow`: diffable data sources need
/// stable `Hashable` item identifiers, and `StoredMessage`/`MessageContent`
/// aren't `Hashable` themselves.
public struct StoredMessageRow: Equatable, Hashable {
    public let storageId: Int64
    public let localMessageId: Int64
    public let isOutgoing: Bool
    public let status: MessageStatus
    public let timestamp: Int64
    public let text: String?
    public let imageThumbnail: Data?
    public let imageRemoteURL: String?

    public init(storageId: Int64, localMessageId: Int64, isOutgoing: Bool, status: MessageStatus, timestamp: Int64, text: String?, imageThumbnail: Data?, imageRemoteURL: String?) {
        self.storageId = storageId
        self.localMessageId = localMessageId
        self.isOutgoing = isOutgoing
        self.status = status
        self.timestamp = timestamp
        self.text = text
        self.imageThumbnail = imageThumbnail
        self.imageRemoteURL = imageRemoteURL
    }
}

/// A single row in the chat message list — either a real, persisted
/// message or an in-flight image upload placeholder (see
/// `PendingImageUpload`).
public enum ChatMessageRow: Equatable, Hashable {
    case message(StoredMessageRow)
    case pendingImage(PendingImageUpload)
}
