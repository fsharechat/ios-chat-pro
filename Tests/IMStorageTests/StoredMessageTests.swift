import XCTest
import Foundation
@testable import IMStorage

final class VideoMessageTests: XCTestCase {
    func test_videoMessage_initFlattensContentToColumns() {
        let thumbnail = Data([0xAA, 0xBB])
        let message = StoredMessage(
            localMessageId: 10, conversationType: .single, target: "u2", from: "u1",
            content: .video(thumbnail: thumbnail, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 42),
            timestamp: 1_000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.contentType, .video)
        XCTAssertEqual(message.searchableContent, "[视频]")
        XCTAssertEqual(message.textContent, "42")
        XCTAssertEqual(message.mediaThumbnail, thumbnail)
        XCTAssertEqual(message.mediaRemoteURL, "https://example.com/v.mp4")
        XCTAssertNil(message.mediaLocalPath)
        XCTAssertNil(message.groupNotificationOperator)
        XCTAssertNil(message.callId)
    }

    func test_videoMessage_contentPropertyRoundTrips() {
        let thumbnail = Data([0xAA])
        let original = MessageContent.video(thumbnail: thumbnail, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 42)
        let message = StoredMessage(
            localMessageId: 10, conversationType: .single, target: "u2", from: "u1",
            content: original, timestamp: 1_000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.content, original)
    }

    func test_videoMessage_setContent_clearsPreviousColumns() {
        var message = StoredMessage(
            localMessageId: 10, conversationType: .single, target: "u2", from: "u1",
            content: .text("hello"), timestamp: 1_000, status: .sent, direction: .send
        )
        message.setContent(.video(thumbnail: nil, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 10))
        XCTAssertNil(message.groupNotificationOperator)
        XCTAssertNil(message.callId)
        XCTAssertEqual(message.contentType, .video)
    }
}

final class StoredMessageTests: XCTestCase {
    func test_textMessage_initFlattensContentAndSetsSearchableContent() {
        let message = StoredMessage(
            localMessageId: 1,
            conversationType: .single,
            target: "u2",
            from: "u1",
            content: .text("hello"),
            timestamp: 1_000,
            status: .sent,
            direction: .send
        )

        XCTAssertEqual(message.contentType, .text)
        XCTAssertEqual(message.textContent, "hello")
        XCTAssertEqual(message.searchableContent, "hello")
        XCTAssertNil(message.mediaRemoteURL)
        XCTAssertNil(message.mediaLocalPath)
        XCTAssertNil(message.mediaThumbnail)
    }

    func test_textMessage_contentComputedPropertyRoundTrips() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hello"), timestamp: 1_000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.content, .text("hello"))
    }

    func test_imageMessage_initFlattensContentAndSetsDigestSearchableContent() {
        let thumbnail = Data([0x01, 0x02, 0x03])
        let message = StoredMessage(
            localMessageId: 2,
            conversationType: .single,
            target: "u2",
            from: "u1",
            content: .image(thumbnail: thumbnail, remoteURL: "https://example.com/a.jpg", localPath: "/tmp/a.jpg"),
            timestamp: 1_000,
            status: .sent,
            direction: .send
        )

        XCTAssertEqual(message.contentType, .image)
        XCTAssertNil(message.textContent)
        XCTAssertEqual(message.searchableContent, "[图片]")
        XCTAssertEqual(message.mediaThumbnail, thumbnail)
        XCTAssertEqual(message.mediaRemoteURL, "https://example.com/a.jpg")
        XCTAssertEqual(message.mediaLocalPath, "/tmp/a.jpg")
    }

    func test_imageMessage_contentComputedPropertyRoundTrips() {
        let thumbnail = Data([0x01, 0x02, 0x03])
        let message = StoredMessage(
            localMessageId: 2, conversationType: .single, target: "u2", from: "u1",
            content: .image(thumbnail: thumbnail, remoteURL: "https://example.com/a.jpg", localPath: "/tmp/a.jpg"),
            timestamp: 1_000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.content, .image(thumbnail: thumbnail, remoteURL: "https://example.com/a.jpg", localPath: "/tmp/a.jpg"))
    }
}

final class StoredMessageContentTests: XCTestCase {
    func test_groupNotificationContent_roundTripsThroughInit() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .addGroupMember, operatorUid: "u1", memberUids: ["u2", "u3"], value: nil),
            timestamp: 1000, status: .unread, direction: .receive
        )
        XCTAssertEqual(message.contentType, .addGroupMember)
        XCTAssertEqual(message.content, .groupNotification(type: .addGroupMember, operatorUid: "u1", memberUids: ["u2", "u3"], value: nil))
        XCTAssertEqual(message.searchableContent, "[群通知]")
    }

    func test_changeGroupNameContent_storesValue() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .changeGroupName, operatorUid: "u1", memberUids: [], value: "新群名"),
            timestamp: 1000, status: .unread, direction: .receive
        )
        XCTAssertEqual(message.content, .groupNotification(type: .changeGroupName, operatorUid: "u1", memberUids: [], value: "新群名"))
    }

    func test_mentionFields_defaultToEmptyAndRoundTrip() {
        let withoutMention = StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "u1",
            content: .text("hi"), timestamp: 1000, status: .unread, direction: .receive
        )
        XCTAssertEqual(withoutMention.mentionedType, 0)
        XCTAssertEqual(withoutMention.mentionedTargets, [])

        let withMention = StoredMessage(
            localMessageId: 2, conversationType: .group, target: "g1", from: "u1",
            content: .text("hi @you"), timestamp: 1000, status: .unread, direction: .receive,
            mentionedType: 1, mentionedTargets: ["u2", "u3"]
        )
        XCTAssertEqual(withMention.mentionedType, 1)
        XCTAssertEqual(withMention.mentionedTargets, ["u2", "u3"])
    }

    func test_callRecordContent_roundTripsThroughInit() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .callRecord(callId: "call-1", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0),
            timestamp: 1000, status: .sending, direction: .send
        )
        XCTAssertEqual(message.contentType, .callStart)
        XCTAssertEqual(message.searchableContent, "[视频通话]")
        XCTAssertEqual(message.content, .callRecord(callId: "call-1", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
    }

    func test_callRecordContent_audioOnlyUsesVoiceDigest() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .callRecord(callId: "call-1", targetId: "u2", audioOnly: true, status: 2, connectTime: 5_000, endTime: 65_000),
            timestamp: 1000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.searchableContent, "[语音通话]")
        XCTAssertEqual(message.content, .callRecord(callId: "call-1", targetId: "u2", audioOnly: true, status: 2, connectTime: 5_000, endTime: 65_000))
    }

    func test_textMessage_callFieldsStayAtDefaults() {
        // A non-call message must not leak stale values into the new
        // call-record columns — guards the `setContent` refactor in Task 1.
        let message = StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hi"), timestamp: 1000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.callId, nil)
        XCTAssertEqual(message.callTargetId, nil)
        XCTAssertEqual(message.callAudioOnly, false)
        XCTAssertEqual(message.callStatus, 0)
    }

    func test_voiceRoundtrip() {
        var msg = StoredMessage(localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
                                content: .voice(remoteURL: "https://cdn/a.m4a", localPath: nil, duration: 12),
                                timestamp: 0, status: .sent, direction: .send)
        XCTAssertEqual(msg.contentType, .voice)
        XCTAssertEqual(msg.textContent, "12")
        XCTAssertEqual(msg.searchableContent, "[语音]")
        XCTAssertEqual(msg.mediaRemoteURL, "https://cdn/a.m4a")
        if case .voice(let url, _, let d) = msg.content {
            XCTAssertEqual(url, "https://cdn/a.m4a")
            XCTAssertEqual(d, 12)
        } else { XCTFail() }
    }

    func test_fileRoundtrip() {
        var msg = StoredMessage(localMessageId: 2, conversationType: .single, target: "u2", from: "u1",
                                content: .file(name: "report.pdf", size: 204800, remoteURL: "https://cdn/f.pdf", localPath: nil),
                                timestamp: 0, status: .sent, direction: .send)
        XCTAssertEqual(msg.contentType, .file)
        XCTAssertEqual(msg.textContent, "204800")
        XCTAssertEqual(msg.searchableContent, "report.pdf")
        if case .file(let name, let size, let url, _) = msg.content {
            XCTAssertEqual(name, "report.pdf")
            XCTAssertEqual(size, 204800)
            XCTAssertEqual(url, "https://cdn/f.pdf")
        } else { XCTFail() }
    }

    func test_recalledMessage_initFlattensOperatorIdIntoTextContent() {
        let message = StoredMessage(
            localMessageId: 99,
            conversationType: .single,
            target: "them",
            from: "them",
            content: .recalled(operatorId: "them"),
            timestamp: 2_000,
            status: .unread,
            direction: .receive
        )

        XCTAssertEqual(message.contentType, .recalled)
        XCTAssertEqual(message.textContent, "them")
        XCTAssertEqual(message.searchableContent, "[撤回消息]")
        XCTAssertNil(message.mediaRemoteURL)
        XCTAssertNil(message.mediaThumbnail)
        XCTAssertNil(message.groupNotificationOperator)
        XCTAssertNil(message.callId)
        XCTAssertEqual(message.callAudioOnly, false)
        XCTAssertEqual(message.callStatus, 0)
    }

    func test_recalledMessage_contentComputedPropertyRoundTrips() {
        let message = StoredMessage(
            localMessageId: 99, conversationType: .single, target: "them", from: "them",
            content: .recalled(operatorId: "them"), timestamp: 2_000, status: .unread, direction: .receive
        )
        XCTAssertEqual(message.content, .recalled(operatorId: "them"))
    }

    func test_setContent_recalled_clearsAllOtherColumns() {
        var message = StoredMessage(
            localMessageId: 1, conversationType: .single, target: "them", from: "them",
            content: .image(thumbnail: Data([0x01]), remoteURL: "https://example.com/a.jpg", localPath: nil),
            timestamp: 1_000, status: .unread, direction: .receive
        )
        message.setContent(.recalled(operatorId: "op"))

        XCTAssertEqual(message.contentType, .recalled)
        XCTAssertEqual(message.textContent, "op")
        XCTAssertEqual(message.searchableContent, "[撤回消息]")
        XCTAssertNil(message.mediaRemoteURL)
        XCTAssertNil(message.mediaThumbnail)
        XCTAssertNil(message.callId)
        XCTAssertNil(message.groupNotificationOperator)
    }
}
