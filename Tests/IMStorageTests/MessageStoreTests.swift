import GRDB
import Combine
import XCTest
@testable import IMStorage

final class MessageStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: MessageStore!
    private var cancellables: Set<AnyCancellable> = []

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

    func test_messageByLocalId_ignoresCollidingReceivedMessageWithSameLocalId() throws {
        let collidingId: Int64 = 555
        try store.insert(StoredMessage(
            localMessageId: collidingId, conversationType: .single, target: "someone-else", from: "someone-else",
            content: .text("not mine"), timestamp: 1_000, status: .unread, direction: .receive
        ))

        // No sent message with this localMessageId exists yet — must not
        // find the received one as a substitute.
        XCTAssertNil(try store.message(localMessageId: collidingId))

        try store.insert(StoredMessage(
            localMessageId: collidingId, conversationType: .single, target: "u2", from: "u1",
            content: .text("mine"), timestamp: 2_000, status: .sending, direction: .send
        ))

        // Now it must find my sent message, not the unrelated received one.
        XCTAssertEqual(try store.message(localMessageId: collidingId)?.content, .text("mine"))
    }

    func test_updateStatus_doesNotAffectCollidingReceivedMessageWithSameLocalId() throws {
        let collidingId: Int64 = 556
        try store.insert(StoredMessage(
            localMessageId: collidingId, conversationType: .single, target: "someone-else", from: "someone-else",
            content: .text("not mine"), timestamp: 1_000, status: .unread, direction: .receive
        ))
        try store.insert(StoredMessage(
            localMessageId: collidingId, conversationType: .single, target: "u2", from: "u1",
            content: .text("mine"), timestamp: 2_000, status: .sending, direction: .send
        ))

        try store.updateStatus(localMessageId: collidingId, status: .sent)

        XCTAssertEqual(try store.message(localMessageId: collidingId)?.status, .sent)
        // The received message's status must be untouched.
        let received = try database.dbQueue.read { db in
            try StoredMessage
                .filter(Column("localMessageId") == collidingId)
                .filter(Column("direction") == MessageDirection.receive.rawValue)
                .fetchOne(db)
        }
        XCTAssertEqual(received?.status, .unread)
    }

    func test_messageByUid_findsInsertedMessage() throws {
        let inserted = try store.insert(makeMessage(localMessageId: 50, text: "has a uid"))
        try store.updateMessageUid(localMessageId: 50, messageUid: 777)

        let found = try store.message(uid: 777)

        XCTAssertEqual(found?.content, .text("has a uid"))
        _ = inserted
    }

    func test_messageByUid_returnsNilWhenNotFound() throws {
        XCTAssertNil(try store.message(uid: 12345))
    }

    func test_messageByUid_withUidZero_alwaysReturnsNil() throws {
        // messageUid defaults to 0 for every not-yet-acked sent message —
        // querying uid 0 would be ambiguous across multiple pending sends,
        // so it must short-circuit to nil rather than returning an arbitrary row.
        try store.insert(makeMessage(localMessageId: 51))
        try store.insert(makeMessage(localMessageId: 52))

        XCTAssertNil(try store.message(uid: 0))
    }

    func test_updateContent_rewritesCallRecordFieldsByRowId() throws {
        let inserted = try store.insert(StoredMessage(
            localMessageId: 9, conversationType: .single, target: "u2", from: "u1",
            content: .callRecord(callId: "call-9", targetId: "u2", audioOnly: false, status: 0, connectTime: 0, endTime: 0),
            timestamp: 1_000, status: .sending, direction: .send
        ))

        try store.updateContent(id: inserted.id!, content: .callRecord(callId: "call-9", targetId: "u2", audioOnly: false, status: 2, connectTime: 5_000, endTime: 65_000))

        let updated = try store.message(localMessageId: 9)
        XCTAssertEqual(updated?.content, .callRecord(callId: "call-9", targetId: "u2", audioOnly: false, status: 2, connectTime: 5_000, endTime: 65_000))
    }

    func test_updateContent_worksOnReceivedRowsToo() throws {
        // The whole point of keying by `id` rather than `localMessageId`:
        // a received call-record row's `localMessageId` may collide with
        // one of my own sent rows (see `message(localMessageId:)`'s doc
        // comment), but `id` is always unambiguous.
        let inserted = try store.insert(StoredMessage(
            localMessageId: 555, conversationType: .single, target: "u1", from: "u2",
            content: .callRecord(callId: "call-10", targetId: "u1", audioOnly: true, status: 0, connectTime: 0, endTime: 0),
            timestamp: 1_000, status: .unread, direction: .receive
        ))

        try store.updateContent(id: inserted.id!, content: .callRecord(callId: "call-10", targetId: "u1", audioOnly: true, status: 1, connectTime: 2_000, endTime: 0))

        let messages = try store.messages(conversationType: .single, target: "u1")
        XCTAssertEqual(messages.first?.content, .callRecord(callId: "call-10", targetId: "u1", audioOnly: true, status: 1, connectTime: 2_000, endTime: 0))
    }

    func test_updateContent_unknownId_isANoOp() throws {
        // Must not throw — `IMCall.CallManager` calls this from timer/network
        // callbacks where there's no reasonable recovery if the row vanished.
        try store.updateContent(id: 999_999, content: .callRecord(callId: "x", targetId: "y", audioOnly: false, status: 2, connectTime: 0, endTime: 0))
    }

    func test_messagesPublisher_emitsLatestMessagesInAscendingOrder() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "first"))
        try store.insert(makeMessage(localMessageId: 2, timestamp: 2_000, text: "second"))

        var received: [[MessageContent]] = []
        let expectation = expectation(description: "received at least 2 updates")
        expectation.expectedFulfillmentCount = 2

        store.messagesPublisher(conversationType: .single, target: "u2")
            .sink(receiveCompletion: { _ in }, receiveValue: { messages in
                received.append(messages.map { $0.content })
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.insert(makeMessage(localMessageId: 3, timestamp: 3_000, text: "third"))

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(received[0], [.text("first"), .text("second")])
        XCTAssertEqual(received[1], [.text("first"), .text("second"), .text("third")])
    }

    func test_messagesPublisher_respectsLimit_keepingNewestWithinWindow() throws {
        for i in 0..<5 {
            try store.insert(makeMessage(localMessageId: Int64(i), timestamp: Int64(i), text: "msg\(i)"))
        }

        var received: [MessageContent] = []
        let expectation = expectation(description: "received update")
        store.messagesPublisher(conversationType: .single, target: "u2", limit: 2)
            .sink(receiveCompletion: { _ in }, receiveValue: { messages in
                received = messages.map { $0.content }
                expectation.fulfill()
            })
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(received, [.text("msg3"), .text("msg4")])
    }

    func test_olderMessages_returnsMessagesBeforeAnchorInAscendingOrder() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "first"))
        try store.insert(makeMessage(localMessageId: 2, timestamp: 2_000, text: "second"))
        try store.insert(makeMessage(localMessageId: 3, timestamp: 3_000, text: "third"))

        let older = try store.olderMessages(conversationType: .single, target: "u2", beforeTimestamp: 3_000, beforeId: 3, limit: 50)

        XCTAssertEqual(older.map { $0.content }, [.text("first"), .text("second")])
    }

    func test_olderMessages_respectsLimit() throws {
        for i in 0..<5 {
            try store.insert(makeMessage(localMessageId: Int64(i), timestamp: Int64(i), text: "msg\(i)"))
        }

        let older = try store.olderMessages(conversationType: .single, target: "u2", beforeTimestamp: 5_000, beforeId: 999, limit: 2)

        XCTAssertEqual(older.map { $0.content }, [.text("msg3"), .text("msg4")])
    }

    func test_olderMessages_tieBreaksOnIdWhenTimestampsCollide() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "a"))
        try store.insert(makeMessage(localMessageId: 2, timestamp: 1_000, text: "b"))
        let third = try store.insert(makeMessage(localMessageId: 3, timestamp: 1_000, text: "c"))

        let older = try store.olderMessages(conversationType: .single, target: "u2", beforeTimestamp: third.timestamp, beforeId: third.id!, limit: 50)

        XCTAssertEqual(older.map { $0.content }, [.text("a"), .text("b")])
    }

    func test_olderMessages_emptyWhenNoOlderHistoryExists() throws {
        try store.insert(makeMessage(localMessageId: 1, timestamp: 1_000, text: "only"))

        let older = try store.olderMessages(conversationType: .single, target: "u2", beforeTimestamp: 1_000, beforeId: 1, limit: 50)

        XCTAssertTrue(older.isEmpty)
    }

    func test_updateContent_db_updatesRecalledContent() throws {
        let inserted = try store.insert(makeMessage(localMessageId: 55, text: "original"))
        let rowId = try XCTUnwrap(inserted.id)

        try database.dbQueue.write { db in
            try store.updateContent(id: rowId, content: .recalled(operatorId: "them"), db: db)
        }

        let updated = try store.message(localMessageId: 55)
        XCTAssertEqual(updated?.content, .recalled(operatorId: "them"))
        XCTAssertEqual(updated?.searchableContent, "[撤回消息]")
    }

    func test_clearMessages_deletesAllMessagesForConversation() throws {
        try store.insert(makeMessage(localMessageId: 1, target: "g1", text: "hello"))
        try store.insert(makeMessage(localMessageId: 2, target: "g1", text: "world"))
        try store.insert(makeMessage(localMessageId: 3, target: "u2", text: "other"))

        try store.clearMessages(conversationType: .single, target: "g1")

        XCTAssertTrue(try store.messages(conversationType: .single, target: "g1").isEmpty)
        XCTAssertEqual(try store.messages(conversationType: .single, target: "u2").count, 1)
    }

    func test_searchMessages_returnsMatchingMessages() throws {
        try store.insert(makeMessage(localMessageId: 1, target: "g1", text: "hello world"))
        try store.insert(makeMessage(localMessageId: 2, target: "g1", text: "goodbye"))
        try store.insert(makeMessage(localMessageId: 3, target: "g1", text: "hello again"))

        let results = try store.searchMessages(conversationType: .single, target: "g1", keyword: "hello")

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { ($0.searchableContent ?? "").contains("hello") })
    }

    func test_searchMessages_returnsEmptyWhenNoMatch() throws {
        try store.insert(makeMessage(localMessageId: 1, target: "g1", text: "hello"))

        let results = try store.searchMessages(conversationType: .single, target: "g1", keyword: "xyz")

        XCTAssertTrue(results.isEmpty)
    }

    func test_deleteMessage_removesRowFromStorage() throws {
        let inserted = try store.insert(makeMessage(localMessageId: 10))
        let id = try XCTUnwrap(inserted.id)

        try store.deleteMessage(id: id)

        XCTAssertNil(try store.message(localMessageId: 10))
    }

    func test_deleteMessage_doesNotAffectOtherMessages() throws {
        let a = try store.insert(makeMessage(localMessageId: 11, text: "keep"))
        let b = try store.insert(makeMessage(localMessageId: 12, text: "delete me"))
        let bId = try XCTUnwrap(b.id)

        try store.deleteMessage(id: bId)

        XCTAssertNotNil(try store.message(localMessageId: 11))
        XCTAssertNil(try store.message(localMessageId: 12))
        _ = a
    }
}
