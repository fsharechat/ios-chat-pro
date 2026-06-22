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

    func test_encode_text_withMention_setsMentionedTypeAndTargets() {
        let wire = MessageContentCodec.encode(.text("hi"), mentionedType: 1, mentionedTargets: ["u2", "u3"])

        XCTAssertEqual(wire.mentionedType, 1)
        XCTAssertEqual(wire.mentionedTarget, ["u2", "u3"])
    }

    func test_encode_text_withoutMention_leavesMentionedFieldsUnset() {
        let wire = MessageContentCodec.encode(.text("hi"))

        XCTAssertFalse(wire.hasMentionedType)
        XCTAssertEqual(wire.mentionedTarget, [])
    }

    func test_decode_createGroup_parsesOperatorNameAndMembers() throws {
        var wire = Im_MessageContent()
        wire.type = 104
        wire.data = Data("""
        {"g":"g1","o":"u1","n":"My Group","ms":["u2","u3"]}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .createGroup, operatorUid: "u1", memberUids: ["u2", "u3"], value: "My Group"))
    }

    func test_decode_addGroupMember_parsesOperatorAndMembers() throws {
        var wire = Im_MessageContent()
        wire.type = 105
        wire.data = Data("""
        {"g":"g1","o":"u1","ms":["u2"]}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .addGroupMember, operatorUid: "u1", memberUids: ["u2"], value: nil))
    }

    func test_decode_kickoffGroupMember_parsesOperatorAndMembers() throws {
        var wire = Im_MessageContent()
        wire.type = 106
        wire.data = Data("""
        {"g":"g1","o":"u1","ms":["u2"]}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .kickoffGroupMember, operatorUid: "u1", memberUids: ["u2"], value: nil))
    }

    func test_decode_quitGroup_neverParsesContentField_leavesOperatorEmpty() throws {
        // The "m" field on the server's fallback encoder is unreliable (Java
        // overload-resolution quirk — see the design doc's flagged risk), so
        // quitGroup is decoded without reading `content` at all; the caller
        // (ReceiveMessageHandler) fills in the operator from `fromUser`.
        var wire = Im_MessageContent()
        wire.type = 107
        wire.content = "anything"

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .quitGroup, operatorUid: "", memberUids: [], value: nil))
    }

    func test_decode_dismissGroup_parsesOperator() throws {
        var wire = Im_MessageContent()
        wire.type = 108
        wire.data = Data("""
        {"g":"g1","o":"u1"}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .dismissGroup, operatorUid: "u1", memberUids: [], value: nil))
    }

    func test_decode_changeGroupName_parsesOperatorAndNewName() throws {
        var wire = Im_MessageContent()
        wire.type = 110
        wire.data = Data("""
        {"g":"g1","o":"u1","n":"New Name"}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .changeGroupName, operatorUid: "u1", memberUids: [], value: "New Name"))
    }

    func test_decode_changeGroupPortrait_parsesOperator() throws {
        var wire = Im_MessageContent()
        wire.type = 112
        wire.data = Data("""
        {"g":"g1","o":"u1"}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .changeGroupPortrait, operatorUid: "u1", memberUids: [], value: nil))
    }

    func test_decode_groupNotification_malformedOrMissingData_fallsBackToEmptyOperator() throws {
        var wire = Im_MessageContent()
        wire.type = 105 // no `data` set at all

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .addGroupMember, operatorUid: "", memberUids: [], value: nil))
    }
}
