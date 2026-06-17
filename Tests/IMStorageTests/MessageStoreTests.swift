import XCTest
@testable import IMStorage

final class MessageStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: MessageStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = MessageStore(dbQueue: database.dbQueue)
    }

    private func makeMessage(localMessageId: Int64, target: String = "u2", timestamp: Int64 = 1_000, text: String = "hi") -> StoredMessage {
        StoredMessage(
            localMessageId: localMessageId, conversationType: .single, target: target, from: "u1",
            content: .text(text), timestamp: timestamp, status: .sending, direction: .send
        )
    }

    func test_insert_assignsAutoIncrementedId() throws {
        let inserted = try store.insert(makeMessage(localMessageId: 1))
        XCTAssertNotNil(inserted.id)
    }

    func test_messageByLocalId_findsInsertedMessage() throws {
        try store.insert(makeMessage(localMessageId: 42, text: "find me"))

        let found = try store.message(localMessageId: 42)

        XCTAssertEqual(found?.content, .text("find me"))
    }

    func test_messageByLocalId_returnsNilWhenNotFound() throws {
        XCTAssertNil(try store.message(localMessageId: 999))
    }

    func test_messagesForConversation_returnsNewestFirst() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "first"))
        try store.insert(makeMessage(localMessageId: 2, timestamp: 3_000, text: "third"))
        try store.insert(makeMessage(localMessageId: 3, timestamp: 2_000, text: "second"))

        let messages = try store.messages(conversationType: .single, target: "u2")

        XCTAssertEqual(messages.map { $0.content }, [.text("third"), .text("second"), .text("first")])
    }

    func test_messagesForConversation_onlyReturnsMatchingTarget() throws {
        try store.insert(makeMessage(localMessageId: 1, target: "u2", text: "for u2"))
        try store.insert(makeMessage(localMessageId: 2, target: "u3", text: "for u3"))

        let messages = try store.messages(conversationType: .single, target: "u2")

        XCTAssertEqual(messages.map { $0.content }, [.text("for u2")])
    }

    func test_messagesForConversation_respectsLimit() throws {
        for i in 0..<5 {
            try store.insert(makeMessage(localMessageId: Int64(i), timestamp: Int64(i), text: "msg\(i)"))
        }

        let messages = try store.messages(conversationType: .single, target: "u2", limit: 2)

        XCTAssertEqual(messages.count, 2)
    }

    func test_updateStatus_changesStatusOfMatchingLocalMessageId() throws {
        try store.insert(makeMessage(localMessageId: 7))

        try store.updateStatus(localMessageId: 7, status: .sendFailure)

        XCTAssertEqual(try store.message(localMessageId: 7)?.status, .sendFailure)
    }

    func test_updateMessageUid_setsServerAssignedUidWithoutChangingContent() throws {
        try store.insert(makeMessage(localMessageId: 7, text: "keep me"))

        try store.updateMessageUid(localMessageId: 7, messageUid: 123_456)

        let updated = try store.message(localMessageId: 7)
        XCTAssertEqual(updated?.messageUid, 123_456)
        XCTAssertEqual(updated?.content, .text("keep me"))
    }
}
