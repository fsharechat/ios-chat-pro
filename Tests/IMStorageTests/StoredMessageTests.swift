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
