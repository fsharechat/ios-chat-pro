import GRDB
import Foundation

/// The only two content types Phase 1 needs. Mirrors the wire-field mapping
/// documented at the top of this plan (text → `searchable_content`; image →
/// `searchable_content` digest + `data` thumbnail + `remoteMediaUrl`) —
/// `IMStorage` itself never touches the wire `Im_MessageContent` type;
/// Plan D's handlers are responsible for that conversion in both directions.
public enum MessageContent: Equatable {
    case text(String)
    case image(thumbnail: Data?, remoteURL: String?, localPath: String?)
}

public struct StoredMessage: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "message"

    public var id: Int64?
    public var localMessageId: Int64
    public var messageUid: Int64
    public var conversationType: ConversationType
    public var target: String
    public var line: Int
    public var from: String
    public var contentType: MessageContentType
    public var textContent: String?
    public var searchableContent: String?
    public var mediaRemoteURL: String?
    public var mediaLocalPath: String?
    public var mediaThumbnail: Data?
    public var timestamp: Int64
    public var status: MessageStatus
    public var direction: MessageDirection

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Reassembles `MessageContent` from the flat storage columns.
    public var content: MessageContent {
        switch contentType {
        case .text:
            return .text(textContent ?? "")
        case .image:
            return .image(thumbnail: mediaThumbnail, remoteURL: mediaRemoteURL, localPath: mediaLocalPath)
        case .createGroup, .addGroupMember, .kickoffGroupMember, .quitGroup, .dismissGroup, .changeGroupName, .changeGroupPortrait:
            // Group notification types are handled separately by Phase 2 message handlers
            return .text("")
        }
    }

    public init(
        id: Int64? = nil,
        localMessageId: Int64,
        messageUid: Int64 = 0,
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        from: String,
        content: MessageContent,
        timestamp: Int64,
        status: MessageStatus,
        direction: MessageDirection
    ) {
        self.id = id
        self.localMessageId = localMessageId
        self.messageUid = messageUid
        self.conversationType = conversationType
        self.target = target
        self.line = line
        self.from = from
        self.timestamp = timestamp
        self.status = status
        self.direction = direction
        switch content {
        case .text(let text):
            contentType = .text
            textContent = text
            searchableContent = text
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
        case .image(let thumbnail, let remoteURL, let localPath):
            contentType = .image
            textContent = nil
            searchableContent = "[图片]"
            mediaRemoteURL = remoteURL
            mediaLocalPath = localPath
            mediaThumbnail = thumbnail
        }
    }
}
