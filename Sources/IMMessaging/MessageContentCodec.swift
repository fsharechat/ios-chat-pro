import IMProto
import IMStorage
import Foundation

/// Converts between the wire `Im_MessageContent` protobuf type and
/// `IMStorage.MessageContent`. Field mapping verified against
/// `chat-proto`'s `MessageContent` message and the Android
/// `TextMessageContent`/`ImageMessageContent`/`MediaMessageContent`
/// `encode()`/`decode()` methods (see this plan's "Reference facts"):
/// - text: body goes in `searchableContent`, not `content`.
/// - image: `searchableContent` holds a `"[图片]"` digest, `data` holds the
///   thumbnail bytes, `remoteMediaURL` holds the uploaded image URL.
///   `localPath` is never a wire field — always `nil` on decode.
public enum MessageContentCodec {
    public enum DecodeError: Error, Equatable {
        case unsupportedContentType(Int32)
    }

    public static func encode(_ content: MessageContent) -> Im_MessageContent {
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
        default:
            throw DecodeError.unsupportedContentType(wire.type)
        }
    }
}
