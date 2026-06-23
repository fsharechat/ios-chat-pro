import IMProto
import IMStorage
import Foundation

/// Converts between the wire `Im_MessageContent` protobuf type and
/// `IMStorage.MessageContent`. Field mapping verified against
/// `chat-proto`'s `MessageContent` message and the Android
/// `TextMessageContent`/`ImageMessageContent`/`MediaMessageContent`
/// `encode()`/`decode()` methods:
/// - text: body goes in `searchableContent`, not `content`.
/// - image: `searchableContent` holds a `"[图片]"` digest, `data` holds the
///   thumbnail bytes, `remoteMediaUrl` holds the uploaded image URL.
///   `localPath` is never a wire field — always `nil` on decode.
/// - group notifications: **decode-only.** The client never constructs
///   `notify_content` when sending a group action request (every group
///   action `Handler` in `chat-server-pro` auto-generates it server-side
///   via `GroupNotificationBinaryContent` when the client omits it — see
///   the design doc §2), so `encode(_:)` is never called with a
///   `.groupNotification` case in practice; `decode(_:)` is the only
///   direction that matters for these 7 types.
public enum MessageContentCodec {
    public enum DecodeError: Error, Equatable {
        case unsupportedContentType(Int32)
    }

    /// Server-generated JSON shape for group-notification `data` payloads
    /// (`GroupNotificationBinaryContent`'s Gson fields): `g`=groupId,
    /// `o`=operator uid, `n`=name (createGroup's group name /
    /// changeGroupName's new name), `ms`=affected member uid list. All
    /// optional and independently absent depending on notification kind.
    private struct GroupNotificationWireContent: Decodable {
        let g: String?
        let o: String?
        let n: String?
        let ms: [String]?
    }

    public static func encode(_ content: MessageContent, mentionedType: Int32 = 0, mentionedTargets: [String] = []) -> Im_MessageContent {
        var wire = Im_MessageContent()
        switch content {
        case .text(let text):
            wire.type = 1
            wire.searchableContent = text
        case .image(let thumbnail, let remoteURL, _):
            wire.type = 3
            wire.searchableContent = "[图片]"
            if let thumbnail {
                wire.data = thumbnail
            }
            if let remoteURL {
                wire.remoteMediaURL = remoteURL
            }
        case .groupNotification(let type, _, _, _):
            // Never sent in practice (see this type's doc comment) — set
            // `type` for completeness rather than leave the wire message
            // at its default (text=0-equivalent) value if this is ever
            // called.
            wire.type = Int32(type.rawValue)
        case .callRecord:
            // Placeholder arm only — forced by `MessageContent` gaining this
            // case in Task 1 (storage representation). The real wire
            // mapping (`searchableContent`=callId, `data`=JSON payload) is
            // Task 3's job; this exists solely to keep this exhaustive
            // switch compiling until then.
            wire.type = Int32(MessageContentType.callStart.rawValue)
        }
        if mentionedType != 0 {
            wire.mentionedType = mentionedType
        }
        if !mentionedTargets.isEmpty {
            wire.mentionedTarget = mentionedTargets
        }
        return wire
    }

    public static func decode(_ wire: Im_MessageContent) throws -> MessageContent {
        switch wire.type {
        case 1:
            return .text(wire.hasSearchableContent ? wire.searchableContent : "")
        case 3:
            return .image(
                thumbnail: wire.hasData ? wire.data : nil,
                remoteURL: wire.hasRemoteMediaURL ? wire.remoteMediaURL : nil,
                localPath: nil
            )
        case 104:
            return decodeGroupNotification(type: .createGroup, wire: wire)
        case 105:
            return decodeGroupNotification(type: .addGroupMember, wire: wire)
        case 106:
            return decodeGroupNotification(type: .kickoffGroupMember, wire: wire)
        case 107:
            return decodeGroupNotification(type: .quitGroup, wire: wire)
        case 108:
            return decodeGroupNotification(type: .dismissGroup, wire: wire)
        case 110:
            return decodeGroupNotification(type: .changeGroupName, wire: wire)
        case 112:
            return decodeGroupNotification(type: .changeGroupPortrait, wire: wire)
        default:
            throw DecodeError.unsupportedContentType(wire.type)
        }
    }

    private static func decodeGroupNotification(type: MessageContentType, wire: Im_MessageContent) -> MessageContent {
        // quitGroup's `m`/content field is unreliable server-side (a Java
        // overload-resolution quirk in `GroupNotificationBinaryContent`
        // picks a different constructor than intended) — never parsed.
        // `ReceiveMessageHandler` fills in `operatorUid` from the wire
        // message's `fromUser` instead.
        guard type != .quitGroup,
              wire.hasData,
              let parsed = try? JSONDecoder().decode(GroupNotificationWireContent.self, from: wire.data)
        else {
            return .groupNotification(type: type, operatorUid: "", memberUids: [], value: nil)
        }

        switch type {
        case .createGroup:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: parsed.ms ?? [], value: parsed.n)
        case .addGroupMember, .kickoffGroupMember:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: parsed.ms ?? [], value: nil)
        case .changeGroupName:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: [], value: parsed.n)
        case .dismissGroup, .changeGroupPortrait:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: [], value: nil)
        case .text, .image, .quitGroup, .callStart:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: [], value: nil) // unreachable
        }
    }
}
