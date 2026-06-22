import XCTest
import Foundation
@testable import IMStorage

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
}
