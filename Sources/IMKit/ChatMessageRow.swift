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

/// A voice message still uploading — lives only in `ConversationViewModel`'s
/// in-memory state until upload succeeds, same lifecycle as `PendingImageUpload`.
public struct PendingVoiceUpload: Equatable, Hashable {
    public enum State: Equatable, Hashable {
        case uploading
        case failed
    }

    public let id: UUID
    public let audioData: Data
    public let duration: Int
    public let fileName: String
    public var state: State

    public init(id: UUID, audioData: Data, duration: Int, fileName: String, state: State) {
        self.id = id
        self.audioData = audioData
        self.duration = duration
        self.fileName = fileName
        self.state = state
    }
}

/// Flattened, `Hashable` presentation of a `StoredMessage`. `senderDisplayName`/
/// `senderAvatarURL` are non-nil only for a group-chat message I received
/// (never for single chat, never for my own outgoing messages — there's no
/// sender row to show for either case). `senderUid` is non-nil only for
/// received messages (to enable avatar-tap mention insertion in groups).
public struct StoredMessageRow: Equatable, Hashable {
    public let storageId: Int64
    public let localMessageId: Int64
    public let messageUid: Int64          // server-assigned uid; 0 until acked
    public let isOutgoing: Bool
    public let status: MessageStatus
    public let timestamp: Int64
    public let text: String?
    public let imageThumbnail: Data?
    public let imageRemoteURL: String?    // also holds voice/file remote URLs
    public let senderDisplayName: String?
    public let senderAvatarURL: String?
    /// 发送者 uid，仅接收方向的消息非 nil — 群聊里点对方头像插入 @ 用；
    /// 自己发的消息为 nil，头像点击自然无动作。
    public let senderUid: String?
    /// Non-nil only for video messages — used by `ConversationViewController`
    /// to dispatch to `VideoMessageCell` instead of `ImageMessageCell`.
    public let videoDuration: Int?
    public let voiceDuration: Int?        // non-nil for voice messages
    public let fileSize: Int?             // non-nil for file messages
    public let fileName: String?          // non-nil for file messages
    /// Non-nil for location messages. Used by `ConversationViewController` to
    /// dispatch to `LocationMessageCell` and by `LocationPreviewViewController`.
    public let locationLat: Double?
    public let locationLng: Double?

    public init(
        storageId: Int64,
        localMessageId: Int64,
        messageUid: Int64 = 0,
        isOutgoing: Bool,
        status: MessageStatus,
        timestamp: Int64,
        text: String?,
        imageThumbnail: Data?,
        imageRemoteURL: String?,
        senderDisplayName: String? = nil,
        senderAvatarURL: String? = nil,
        senderUid: String? = nil,
        videoDuration: Int? = nil,
        voiceDuration: Int? = nil,
        fileSize: Int? = nil,
        fileName: String? = nil,
        locationLat: Double? = nil,
        locationLng: Double? = nil
    ) {
        self.storageId = storageId
        self.localMessageId = localMessageId
        self.messageUid = messageUid
        self.isOutgoing = isOutgoing
        self.status = status
        self.timestamp = timestamp
        self.text = text
        self.imageThumbnail = imageThumbnail
        self.imageRemoteURL = imageRemoteURL
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.senderUid = senderUid
        self.videoDuration = videoDuration
        self.voiceDuration = voiceDuration
        self.fileSize = fileSize
        self.fileName = fileName
        self.locationLat = locationLat
        self.locationLng = locationLng
    }
}

/// A non-bubble row rendered centered, no sender — a group system
/// notification (create/add/kick/quit/dismiss/rename/re-portrait), with its
/// Chinese wording already resolved by `ConversationViewModel`.
public struct SystemTipRow: Equatable, Hashable {
    public let storageId: Int64
    public let messageUid: Int64          // server-assigned uid; 0 until acked
    public let text: String
    public let timestamp: Int64

    public init(storageId: Int64, messageUid: Int64 = 0, text: String, timestamp: Int64) {
        self.storageId = storageId
        self.messageUid = messageUid
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
    case pendingVoice(PendingVoiceUpload)
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
        case .pendingImage, .pendingVideo, .pendingVoice, .timeHeader: return nil
        }
    }

    public var timestamp: Int64? {
        switch self {
        case .message(let row): return row.timestamp
        case .systemTip(let row): return row.timestamp
        case .pendingImage, .pendingVideo, .pendingVoice, .timeHeader: return nil
        }
    }

    /// The server-assigned uid of the underlying persisted message — non-nil
    /// for any row backed by an acked `StoredMessage`, whatever it renders
    /// as (`.message` bubble or `.systemTip` recall/group-notification line).
    /// `ConversationViewModel.oldestKnownMessageUid` pages remote history
    /// from this, so it must not depend on the row's presentation.
    public var messageUid: Int64? {
        switch self {
        case .message(let row): return row.messageUid == 0 ? nil : row.messageUid
        case .systemTip(let row): return row.messageUid == 0 ? nil : row.messageUid
        case .pendingImage, .pendingVideo, .pendingVoice, .timeHeader: return nil
        }
    }
}
