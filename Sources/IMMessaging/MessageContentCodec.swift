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

    /// Wire shape for type 400 (`CallStart`)'s `data` field — mirrors
    /// Android `CallStartMessageContent.encode()`'s `JSONObject` exactly
    /// (`t`=targetId, `a`=audioOnly as 0/1, `c`/`e`/`s` omitted when 0).
    private struct CallStartWireContent: Codable {
        let t: String
        let a: Int
        let c: Int64?
        let e: Int64?
        let s: Int?
    }

    /// Wire shape for type 2 (voice)'s `data` field.
    private struct VoiceWireContent: Codable {
        let duration: Int
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
        case .callRecord(let callId, let targetId, let audioOnly, let status, let connectTime, let endTime):
            wire.type = 400
            wire.searchableContent = callId
            let payload = CallStartWireContent(
                t: targetId,
                a: audioOnly ? 1 : 0,
                c: connectTime > 0 ? connectTime : nil,
                e: endTime > 0 ? endTime : nil,
                s: status > 0 ? status : nil
            )
            if let data = try? JSONEncoder().encode(payload) {
                wire.data = data
            }
        case .voice(let remoteURL, _, let duration):
            wire.type = 2
            wire.searchableContent = "[语音]"
            // Android SoundMessageContent.encode() writes {"duration":X} JSON into content field.
            if let json = try? JSONEncoder().encode(VoiceWireContent(duration: duration)),
               let jsonStr = String(data: json, encoding: .utf8) {
                wire.content = jsonStr
            }
            if let remoteURL { wire.remoteMediaURL = remoteURL }
        case .file(let name, let size, let remoteURL, _):
            wire.type = 5
            wire.searchableContent = name
            wire.content = "\(size)"
            if let remoteURL { wire.remoteMediaURL = remoteURL }
        case .video(let thumbnail, let remoteURL, _, let duration):
            wire.type = 4
            wire.searchableContent = "[视频]"
            wire.content = "\(duration)"
            if let thumbnail { wire.data = thumbnail }
            if let remoteURL { wire.remoteMediaURL = remoteURL }
        case .recalled:
            // A recalled message is never re-sent over the wire — the client
            // only stores it locally after receiving a recall notification.
            // This branch is unreachable in normal operation but must exist
            // to keep the switch exhaustive.
            wire.type = 80
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
        case 2:
            // Android SoundMessageContent.decode() reads {"duration":X} JSON from content field.
            // Fall back to data JSON for any messages written by the old iOS codec.
            let duration: Int
            if wire.hasContent,
               let contentData = wire.content.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(VoiceWireContent.self, from: contentData) {
                duration = decoded.duration
            } else if wire.hasData {
                duration = (try? JSONDecoder().decode(VoiceWireContent.self, from: wire.data))?.duration ?? 0
            } else {
                duration = 0
            }
            return .voice(remoteURL: wire.hasRemoteMediaURL ? wire.remoteMediaURL : nil, localPath: nil, duration: duration)
        case 5:
            let name = wire.hasSearchableContent ? wire.searchableContent : ""
            let size = Int(wire.hasContent ? wire.content : "0") ?? 0
            return .file(name: name, size: size, remoteURL: wire.hasRemoteMediaURL ? wire.remoteMediaURL : nil, localPath: nil)
        case 400:
            return decodeCallStart(wire: wire)
        case 80:
            // Android RecallMessageContent.decode() reads operatorId from payload.content.
            return .recalled(operatorId: wire.hasContent ? wire.content : "")
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
        case .text, .image, .video, .quitGroup, .callStart, .voice, .file, .recalled:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: [], value: nil) // unreachable
        }
    }

    private static func decodeCallStart(wire: Im_MessageContent) -> MessageContent {
        let callId = wire.hasSearchableContent ? wire.searchableContent : ""
        guard wire.hasData, let parsed = try? JSONDecoder().decode(CallStartWireContent.self, from: wire.data) else {
            return .callRecord(callId: callId, targetId: "", audioOnly: false, status: 0, connectTime: 0, endTime: 0)
        }
        return .callRecord(callId: callId, targetId: parsed.t, audioOnly: parsed.a > 0, status: parsed.s ?? 0, connectTime: parsed.c ?? 0, endTime: parsed.e ?? 0)
    }
}
