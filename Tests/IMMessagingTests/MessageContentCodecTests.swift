import XCTest
import Foundation
import IMProto
import IMStorage
@testable import IMMessaging

final class MessageContentCodecTests: XCTestCase {
    func test_encodeText_setsTypeAndSearchableContent_notContent() {
        let wire = MessageContentCodec.encode(.text("hello"))

        XCTAssertEqual(wire.type, 1)
        XCTAssertEqual(wire.searchableContent, "hello")
        XCTAssertFalse(wire.hasContent) // text body goes in searchable_content, not content
    }

    func test_decodeText_readsSearchableContent() throws {
        var wire = Im_MessageContent()
        wire.type = 1
        wire.searchableContent = "hello"

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .text("hello"))
    }

    func test_encodeImage_setsDigestThumbnailAndRemoteURL() {
        let thumbnail = Data([0x01, 0x02])
        let wire = MessageContentCodec.encode(.image(thumbnail: thumbnail, remoteURL: "https://example.com/a.jpg", localPath: "/tmp/a.jpg"))

        XCTAssertEqual(wire.type, 3)
        XCTAssertEqual(wire.searchableContent, "[图片]")
        XCTAssertEqual(wire.data, thumbnail)
        XCTAssertEqual(wire.remoteMediaURL, "https://example.com/a.jpg")
    }

    func test_decodeImage_readsThumbnailAndRemoteURL_localPathAlwaysNil() throws {
        var wire = Im_MessageContent()
        wire.type = 3
        wire.data = Data([0x01, 0x02])
        wire.remoteMediaURL = "https://example.com/a.jpg"

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .image(thumbnail: Data([0x01, 0x02]), remoteURL: "https://example.com/a.jpg", localPath: nil))
    }

    func test_decodeUnsupportedType_throws() {
        var wire = Im_MessageContent()
        wire.type = 6 // voice — not in Phase 1 scope

        XCTAssertThrowsError(try MessageContentCodec.decode(wire)) { error in
            XCTAssertEqual(error as? MessageContentCodec.DecodeError, .unsupportedContentType(6))
        }
    }

    func test_encodeThenDecode_roundTrips_forBothContentTypes() throws {
        XCTAssertEqual(try MessageContentCodec.decode(MessageContentCodec.encode(.text("round trip"))), .text("round trip"))

        let imageContent = MessageContent.image(thumbnail: Data([0xAA]), remoteURL: "https://example.com/b.jpg", localPath: nil)
        XCTAssertEqual(try MessageContentCodec.decode(MessageContentCodec.encode(imageContent)), imageContent)
    }
}
