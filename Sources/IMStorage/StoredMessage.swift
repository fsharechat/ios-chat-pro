import GRDB
import Foundation

/// Mirrors the wire-field mapping documented at the top of this file: text →
/// `searchable_content`; image → `searchable_content` digest + `data`
/// thumbnail + `remoteMediaUrl`; group notifications → decoded purely for
/// display (never re-encoded — the client never constructs `notify_content`
/// itself; see `MessageContentCodec`'s doc comment). `IMStorage` itself never
/// touches the wire `Im_MessageContent` type — `IMMessaging`'s handlers are
/// responsible for that conversion.
public enum MessageContent: Equatable {
    case text(String)
    case image(thumbnail: Data?, remoteURL: String?, localPath: String?)
    /// `type` is always one of the 7 group-notification `MessageContentType`
    /// cases. `value` carries the new group name for `.changeGroupName`,
    /// `nil` otherwise. `memberUids` carries the affected member list for
    /// `.createGroup`/`.addGroupMember`/`.kickoffGroupMember`, empty
    /// otherwise.
    case groupNotification(type: MessageContentType, operatorUid: String, memberUids: [String], value: String?)
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
    public var mentionedType: Int
    public var mentionedTargetsRaw: String?
    public var groupNotificationOperator: String?
    public var groupNotificationMembersRaw: String?
    public var groupNotificationValue: String?

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
            return .groupNotification(
                type: contentType,
                operatorUid: groupNotificationOperator ?? "",
                memberUids: groupNotificationMembers,
                value: groupNotificationValue
            )
        }
    }

    /// Comma-joined storage for the `repeated string mentioned_target`
    /// wire field — this codebase has no precedent for a JSON-array column,
    /// and uids never contain commas, so a simple CSV column avoids adding
    /// one. Computed, not stored: Swift's synthesized `Codable` only
    /// persists *stored* properties, so this never becomes a duplicate
    /// GRDB column.
    public var mentionedTargets: [String] {
        guard let raw = mentionedTargetsRaw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map(String.init)
    }

    public var groupNotificationMembers: [String] {
        guard let raw = groupNotificationMembersRaw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map(String.init)
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
        direction: MessageDirection,
        mentionedType: Int = 0,
        mentionedTargets: [String] = []
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
        self.mentionedType = mentionedType
        self.mentionedTargetsRaw = mentionedTargets.isEmpty ? nil : mentionedTargets.joined(separator: ",")

        switch content {
        case .text(let text):
            contentType = .text
            textContent = text
            searchableContent = text
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
        case .image(let thumbnail, let remoteURL, let localPath):
            contentType = .image
            textContent = nil
            searchableContent = "[图片]"
            mediaRemoteURL = remoteURL
            mediaLocalPath = localPath
            mediaThumbnail = thumbnail
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
        case .groupNotification(let type, let operatorUid, let memberUids, let value):
            contentType = type
            textContent = nil
            searchableContent = "[群通知]"
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
            groupNotificationOperator = operatorUid
            groupNotificationMembersRaw = memberUids.isEmpty ? nil : memberUids.joined(separator: ",")
            groupNotificationValue = value
        }
    }
}
