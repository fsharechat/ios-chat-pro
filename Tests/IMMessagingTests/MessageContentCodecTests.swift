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

    func test_decode_groupNotification_malformedJSONData_fallsBackToEmptyOperator() throws {
        var wire = Im_MessageContent()
        wire.type = 105
        wire.data = Data("not json".utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .addGroupMember, operatorUid: "", memberUids: [], value: nil))
    }

    func test_encodeCallRecord_setsTypeContentAndDataJSON() throws {
        let wire = MessageContentCodec.encode(.callRecord(callId: "call-1", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0))

        XCTAssertEqual(wire.type, 400)
        // Android CallStartMessageContent.decode 从 payload.content 读 callId,
        // 所以必须编在 wire 的 content 字段(searchableContent 它不看)。
        XCTAssertEqual(wire.content, "call-1")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire.data) as? [String: Any])
        XCTAssertEqual(json["t"] as? String, "u2")
        XCTAssertEqual(json["a"] as? Int, 0)
        XCTAssertNil(json["c"]) // omitted when 0, matching Android's encode() guard
        XCTAssertNil(json["e"])
        XCTAssertNil(json["s"])
    }

    func test_encodeCallRecord_includesNonZeroConnectEndStatus() throws {
        let wire = MessageContentCodec.encode(.callRecord(callId: "call-1", targetId: "u2", audioOnly: true, status: 2, connectTime: 5_000, endTime: 65_000))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire.data) as? [String: Any])
        XCTAssertEqual(json["a"] as? Int, 1)
        XCTAssertEqual(json["c"] as? Int, 5_000)
        XCTAssertEqual(json["e"] as? Int, 65_000)
        XCTAssertEqual(json["s"] as? Int, 2)
    }

    func test_decodeCallRecord_parsesAllFields() throws {
        var wire = Im_MessageContent()
        wire.type = 400
        wire.content = "call-1"
        wire.data = Data("""
        {"t":"u2","a":1,"c":5000,"e":65000,"s":2}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .callRecord(callId: "call-1", targetId: "u2", audioOnly: true, status: 2, connectTime: 5_000, endTime: 65_000))
    }

    func test_decodeCallRecord_missingOptionalFields_defaultToZero() throws {
        var wire = Im_MessageContent()
        wire.type = 400
        wire.content = "call-1"
        wire.data = Data("""
        {"t":"u2","a":0}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .callRecord(callId: "call-1", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
    }

    func test_decodeCallRecord_fallsBackToSearchableContentForLegacyIOSMessages() throws {
        // 修 callId 字段错位之前的 iOS 版本把 callId 写在 searchableContent ——
        // 服务器历史里的这批消息拉回来仍要能解出 callId。
        var wire = Im_MessageContent()
        wire.type = 400
        wire.searchableContent = "call-legacy"
        wire.data = Data("""
        {"t":"u2","a":0}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .callRecord(callId: "call-legacy", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
    }

    func test_encodeThenDecodeCallRecord_roundTrips() throws {
        let original = MessageContent.callRecord(callId: "call-2", targetId: "u3", audioOnly: true, status: 1, connectTime: 1_000, endTime: 0)
        XCTAssertEqual(try MessageContentCodec.decode(MessageContentCodec.encode(original)), original)
    }

    // MARK: - Voice (type=2)

    func test_encodeVoice_setsTypeSearchableContentDataAndRemoteURL() throws {
        let wire = MessageContentCodec.encode(.voice(remoteURL: "https://cdn/a.m4a", localPath: nil, duration: 12))

        XCTAssertEqual(wire.type, 2)
        XCTAssertEqual(wire.searchableContent, "[语音]")
        XCTAssertTrue(wire.hasData)
        XCTAssertEqual(wire.remoteMediaURL, "https://cdn/a.m4a")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire.data) as? [String: Any])
        XCTAssertEqual(json["duration"] as? Int, 12)
    }

    // Android 的 MediaMessageContent.decode 靠 wire.mediaType 识别媒体类型
    // （IMAGE=1/VOICE=2/VIDEO=3/FILE=4），缺失时 mediaMessageContentFile 返回
    // null，收端点击语音/文件毫无反应（2026-07-09 线上问题）。
    func test_encodeMedia_setsAndroidMediaTypeField() {
        XCTAssertEqual(MessageContentCodec.encode(
            .image(thumbnail: nil, remoteURL: nil, localPath: nil)).mediaType, 1)
        XCTAssertEqual(MessageContentCodec.encode(
            .voice(remoteURL: nil, localPath: nil, duration: 1)).mediaType, 2)
        XCTAssertEqual(MessageContentCodec.encode(
            .video(thumbnail: nil, remoteURL: nil, localPath: nil, duration: 1)).mediaType, 3)
        XCTAssertEqual(MessageContentCodec.encode(
            .file(name: "a.txt", size: 1, remoteURL: nil, localPath: nil)).mediaType, 4)
    }

    func test_encodeVoice_noRemoteURL_doesNotSetRemoteMediaURL() {
        let wire = MessageContentCodec.encode(.voice(remoteURL: nil, localPath: nil, duration: 5))

        XCTAssertFalse(wire.hasRemoteMediaURL)
    }

    func test_decodeVoice_parsesRemoteURLAndDuration() throws {
        var wire = Im_MessageContent()
        wire.type = 2
        wire.searchableContent = "[语音]"
        wire.remoteMediaURL = "https://cdn/a.m4a"
        wire.data = Data(#"{"duration":12}"#.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .voice(remoteURL: "https://cdn/a.m4a", localPath: nil, duration: 12))
    }

    func test_decodeVoice_missingData_defaultsDurationToZero() throws {
        var wire = Im_MessageContent()
        wire.type = 2

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .voice(remoteURL: nil, localPath: nil, duration: 0))
    }

    func test_encodeDecodeVoice_roundTrips() throws {
        let original = MessageContent.voice(remoteURL: "https://cdn/a.m4a", localPath: nil, duration: 12)
        XCTAssertEqual(try MessageContentCodec.decode(MessageContentCodec.encode(original)), original)
    }

    // MARK: - File (type=5)

    func test_encodeFile_setsTypeSearchableContentSizeAndRemoteURL() {
        let wire = MessageContentCodec.encode(.file(name: "report.pdf", size: 204800, remoteURL: "https://cdn/f.pdf", localPath: nil))

        XCTAssertEqual(wire.type, 5)
        XCTAssertEqual(wire.searchableContent, "report.pdf")
        XCTAssertEqual(wire.content, "204800")
        XCTAssertEqual(wire.remoteMediaURL, "https://cdn/f.pdf")
    }

    func test_encodeFile_noRemoteURL_doesNotSetRemoteMediaURL() {
        let wire = MessageContentCodec.encode(.file(name: "doc.txt", size: 1024, remoteURL: nil, localPath: nil))

        XCTAssertFalse(wire.hasRemoteMediaURL)
    }

    func test_decodeFile_parsesNameSizeAndRemoteURL() throws {
        var wire = Im_MessageContent()
        wire.type = 5
        wire.searchableContent = "report.pdf"
        wire.content = "204800"
        wire.remoteMediaURL = "https://cdn/f.pdf"

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .file(name: "report.pdf", size: 204800, remoteURL: "https://cdn/f.pdf", localPath: nil))
    }

    func test_decodeFile_missingContentField_defaultsSizeToZero() throws {
        var wire = Im_MessageContent()
        wire.type = 5
        wire.searchableContent = "doc.txt"

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .file(name: "doc.txt", size: 0, remoteURL: nil, localPath: nil))
    }

    func test_encodeDecodeFile_roundTrips() throws {
        let original = MessageContent.file(name: "report.pdf", size: 204800, remoteURL: "https://cdn/f.pdf", localPath: nil)
        XCTAssertEqual(try MessageContentCodec.decode(MessageContentCodec.encode(original)), original)
    }

    // MARK: - Video (type=4)

    func test_encodeVideo_setsTypeSearchableThumbnailRemoteURLAndDurationJSON() throws {
        let thumbnail = Data([0xCC, 0xDD])
        let wire = MessageContentCodec.encode(
            .video(thumbnail: thumbnail, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 42)
        )
        XCTAssertEqual(wire.type, 4)
        XCTAssertEqual(wire.searchableContent, "[视频]")
        XCTAssertEqual(wire.data, thumbnail)
        XCTAssertEqual(wire.remoteMediaURL, "https://example.com/v.mp4")
        XCTAssertTrue(wire.hasContent)
        let parsed = try JSONDecoder().decode([String: Int].self, from: Data(wire.content.utf8))
        XCTAssertEqual(parsed["duration"], 42)
    }

    func test_decodeVideo_readsThumbnailRemoteURLAndDuration() throws {
        var wire = Im_MessageContent()
        wire.type = 6
        wire.data = Data([0xCC, 0xDD])
        wire.remoteMediaURL = "https://example.com/v.mp4"
        wire.content = "{\"duration\":42}"
        let content = try MessageContentCodec.decode(wire)
        XCTAssertEqual(content, .video(thumbnail: Data([0xCC, 0xDD]), remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 42))
    }

    func test_decodeVideo_missingDurationField_defaultsToZero() throws {
        var wire = Im_MessageContent()
        wire.type = 6
        wire.remoteMediaURL = "https://example.com/v.mp4"
        let content = try MessageContentCodec.decode(wire)
        XCTAssertEqual(content, .video(thumbnail: nil, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 0))
    }

    func test_videoRoundTrip() throws {
        let original = MessageContent.video(thumbnail: Data([0xEE]), remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 15)
        let roundTripped = try MessageContentCodec.decode(MessageContentCodec.encode(original))
        XCTAssertEqual(roundTripped, original)
    }

    // MARK: - Location (type=4)

    func test_encodeLocation_setsType4AndAllWireFields() {
        let thumbnail = Data([0x01, 0x02])
        let wire = MessageContentCodec.encode(
            .location(lat: 31.23, lng: 121.47, title: "上海市中心", thumbnail: thumbnail)
        )
        XCTAssertEqual(wire.type, 4)
        XCTAssertEqual(wire.searchableContent, "上海市中心")
        XCTAssertEqual(wire.data, thumbnail)
        XCTAssertTrue(wire.content.contains("\"lat\":31.23"))
        XCTAssertTrue(wire.content.contains("\"long\":121.47"))
    }

    func test_decodeType4_parsesAllFields() throws {
        var wire = Im_MessageContent()
        wire.type = 4
        wire.searchableContent = "上海市中心"
        wire.data = Data([0x03, 0x04])
        wire.content = "{\"lat\":31.23,\"long\":121.47}"
        let content = try MessageContentCodec.decode(wire)
        XCTAssertEqual(content, .location(lat: 31.23, lng: 121.47, title: "上海市中心", thumbnail: Data([0x03, 0x04])))
    }

    func test_decodeType4_missingThumbnail_nilThumbnail() throws {
        var wire = Im_MessageContent()
        wire.type = 4
        wire.searchableContent = "POI"
        wire.content = "{\"lat\":22.5,\"long\":114.1}"
        let content = try MessageContentCodec.decode(wire)
        XCTAssertEqual(content, .location(lat: 22.5, lng: 114.1, title: "POI", thumbnail: nil))
    }

    func test_locationMessage_roundTrips_throughCodec() throws {
        let original = MessageContent.location(lat: 39.9, lng: 116.4, title: "北京", thumbnail: Data([0xFF]))
        let decoded = try MessageContentCodec.decode(MessageContentCodec.encode(original))
        XCTAssertEqual(decoded, original)
    }
}
