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

/// A video message still uploading — lives only in `ConversationViewModel`'s
/// in-memory state until upload succeeds, same lifecycle as `PendingImageUpload`.
public struct PendingVideoUpload: Equatable, Hashable {
    public enum State: Equatable, Hashable {
        case uploading
        case failed
    }

    public let id: UUID
    public let thumbnail: Data
    public let videoData: Data
    public let duration: Int
    public var state: State

    public init(id: UUID, thumbnail: Data, videoData: Data, duration: Int, state: State) {
        self.id = id
        self.thumbnail = thumbnail
        self.videoData = videoData
        self.duration = duration
        self.state = state
    }
}

/// Flattened, `Hashable` presentation of a `StoredMessage`. `senderDisplayName`/
/// `senderAvatarURL` are non-nil only for a group-chat message I received
/// (never for single chat, never for my own outgoing messages — there's no
/// sender row to show for either case).
public struct StoredMessageRow: Equatable, Hashable {
    public let storageId: Int64
    public let localMessageId: Int64
    public let isOutgoing: Bool
    public let status: MessageStatus
    public let timestamp: Int64
    public let text: String?
    public let imageThumbnail: Data?
    public let imageRemoteURL: String?
    public let senderDisplayName: String?
    public let senderAvatarURL: String?
    /// Non-nil only for video messages — used by `ConversationViewController`
    /// to dispatch to `VideoMessageCell` instead of `ImageMessageCell`.
    public let videoDuration: Int?
    /// Non-nil for location messages. Used by `ConversationViewController` to
    /// dispatch to `LocationMessageCell` and by `LocationPreviewViewController`.
    public let locationLat: Double?
    public let locationLng: Double?

    public init(
        storageId: Int64,
        localMessageId: Int64,
        isOutgoing: Bool,
        status: MessageStatus,
        timestamp: Int64,
        text: String?,
        imageThumbnail: Data?,
        imageRemoteURL: String?,
        senderDisplayName: String? = nil,
        senderAvatarURL: String? = nil,
        videoDuration: Int? = nil,
        locationLat: Double? = nil,
        locationLng: Double? = nil
    ) {
        self.storageId = storageId
        self.localMessageId = localMessageId
        self.isOutgoing = isOutgoing
        self.status = status
        self.timestamp = timestamp
        self.text = text
        self.imageThumbnail = imageThumbnail
        self.imageRemoteURL = imageRemoteURL
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.videoDuration = videoDuration
        self.locationLat = locationLat
        self.locationLng = locationLng
    }
}

/// A non-bubble row rendered centered, no sender — a group system
/// notification (create/add/kick/quit/dismiss/rename/re-portrait), with its
/// Chinese wording already resolved by `ConversationViewModel`.
public struct SystemTipRow: Equatable, Hashable {
    public let storageId: Int64
    public let text: String
    public let timestamp: Int64

    public init(storageId: Int64, text: String, timestamp: Int64) {
        self.storageId = storageId
        self.text = text
        self.timestamp = timestamp
    }
}

/// A single row in the chat message list: a real, persisted message; an
/// in-flight image upload placeholder; a group system-notification tip; or a
/// synthetic time separator injected between messages with a gap ≥ 5 minutes.
public enum ChatMessageRow: Equatable, Hashable {
    case message(StoredMessageRow)
    case pendingImage(PendingImageUpload)
    case pendingVideo(PendingVideoUpload)
    case systemTip(SystemTipRow)
    /// text: formatted display string; anchorId: storageId of the immediately
    /// following message, making each header globally unique even when two
    /// gaps produce the same formatted time string.
    case timeHeader(String, Int64)
}

extension ChatMessageRow {
    /// `nil` for `.pendingImage` — it was never persisted, so it has no
    /// storage identity to compare against. Used by `ConversationViewModel`
    /// to detect which previously-live rows fell out of the sliding
    /// "latest pageSize" window and need migrating into `olderRows`.
    public var storageId: Int64? {
        switch self {
        case .message(let row): return row.storageId
        case .systemTip(let row): return row.storageId
        case .pendingImage, .pendingVideo, .timeHeader: return nil
        }
    }

    public var timestamp: Int64? {
        switch self {
        case .message(let row): return row.timestamp
        case .systemTip(let row): return row.timestamp
        case .pendingImage, .pendingVideo, .timeHeader: return nil
        }
    }
}
