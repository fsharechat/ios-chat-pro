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
    /// Wire type 400 (`CallStart`, see Phase 3 design doc §2). `status`:
    /// 0=未接听/1=通话中/2=已结束, matching Android's `CallStartMessageContent`.
    /// `connectTime`/`endTime` are 0 until the call actually connects/ends —
    /// `IMCall.CallManager` updates this in place via `MessageStore.updateContent`
    /// as the call progresses, it is never re-sent over the wire after the
    /// initial invite.
    case callRecord(callId: String, targetId: String, audioOnly: Bool, status: Int, connectTime: Int64, endTime: Int64)
    /// Wire type 4. `duration` is in seconds. Fields follow the same
    /// optional-presence convention as `.image` and `.voice`.
    case video(thumbnail: Data?, remoteURL: String?, localPath: String?, duration: Int)
    /// Wire type 2. `duration` is in seconds. `remoteURL`/`localPath` follow
    /// the same optional-presence convention as `.image` — remote is nil until
    /// uploaded, local is nil until downloaded.
    case voice(remoteURL: String?, localPath: String?, duration: Int)
    /// Wire type 5. `size` is in bytes. `remoteURL`/`localPath` follow the
    /// same optional-presence convention as `.image`.
    case file(name: String, size: Int, remoteURL: String?, localPath: String?)
    /// The original message was recalled by `operatorId`. Stored in-place:
    /// `textContent` holds the operator uid; `searchableContent` is "[撤回消息]".
    case recalled(operatorId: String)
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
    public var callId: String?
    public var callTargetId: String?
    public var callAudioOnly: Bool
    public var callStatus: Int
    public var callConnectTime: Int64
    public var callEndTime: Int64

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
        case .callStart:
            return .callRecord(
                callId: callId ?? "",
                targetId: callTargetId ?? "",
                audioOnly: callAudioOnly,
                status: callStatus,
                connectTime: callConnectTime,
                endTime: callEndTime
            )
        case .video:
            return .video(
                thumbnail: mediaThumbnail,
                remoteURL: mediaRemoteURL,
                localPath: mediaLocalPath,
                duration: Int(textContent ?? "0") ?? 0
            )
        case .voice:
            return .voice(remoteURL: mediaRemoteURL, localPath: mediaLocalPath, duration: Int(textContent ?? "0") ?? 0)
        case .file:
            return .file(name: searchableContent ?? "", size: Int(textContent ?? "0") ?? 0, remoteURL: mediaRemoteURL, localPath: mediaLocalPath)
        case .recalled:
            return .recalled(operatorId: textContent ?? "")
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

        // Placeholder values so every stored property has *some* value
        // before `setContent` (below) assigns the real ones per-case — a
        // Swift struct init must finish assigning every stored property
        // before calling any method on `self`, including a mutating one.
        contentType = .text
        textContent = nil
        searchableContent = nil
        mediaRemoteURL = nil
        mediaLocalPath = nil
        mediaThumbnail = nil
        groupNotificationOperator = nil
        groupNotificationMembersRaw = nil
        groupNotificationValue = nil
        callId = nil
        callTargetId = nil
        callAudioOnly = false
        callStatus = 0
        callConnectTime = 0
        callEndTime = 0

        setContent(content)
    }

    /// Flattens `content` into this row's storage columns, clearing every
    /// column owned by a *different* content case along the way (so e.g.
    /// updating a row from `.callRecord` to anything else, or vice versa,
    /// never leaves a stale value behind from the previous case). Shared by
    /// `init` (placeholder-then-set, see above) and `MessageStore.updateContent`
    /// (Task 2), which is the only reason this exists as its own method
    /// rather than being inlined back into `init`.
    public mutating func setContent(_ content: MessageContent) {
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
            callId = nil
            callTargetId = nil
            callAudioOnly = false
            callStatus = 0
            callConnectTime = 0
            callEndTime = 0
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
            callId = nil
            callTargetId = nil
            callAudioOnly = false
            callStatus = 0
            callConnectTime = 0
            callEndTime = 0
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
            callId = nil
            callTargetId = nil
            callAudioOnly = false
            callStatus = 0
            callConnectTime = 0
            callEndTime = 0
        case .callRecord(let callId, let targetId, let audioOnly, let status, let connectTime, let endTime):
            contentType = .callStart
            textContent = nil
            searchableContent = audioOnly ? "[语音通话]" : "[视频通话]"
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
            self.callId = callId
            self.callTargetId = targetId
            self.callAudioOnly = audioOnly
            self.callStatus = status
            self.callConnectTime = connectTime
            self.callEndTime = endTime
        case .voice(let remoteURL, let localPath, let duration):
            contentType = .voice
            textContent = "\(duration)"
            searchableContent = "[语音]"
            mediaRemoteURL = remoteURL
            mediaLocalPath = localPath
            mediaThumbnail = nil
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
            callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0
        case .file(let name, let size, let remoteURL, let localPath):
            contentType = .file
            textContent = "\(size)"
            searchableContent = name
            mediaRemoteURL = remoteURL
            mediaLocalPath = localPath
            mediaThumbnail = nil
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
            callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0
        case .video(let thumbnail, let remoteURL, let localPath, let duration):
            contentType = .video
            textContent = "\(duration)"
            searchableContent = "[视频]"
            mediaRemoteURL = remoteURL
            mediaLocalPath = localPath
            mediaThumbnail = thumbnail
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
            callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0
        case .recalled(let operatorId):
            contentType = .recalled
            textContent = operatorId
            searchableContent = "[撤回消息]"
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
            callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0
        }
    }
}
