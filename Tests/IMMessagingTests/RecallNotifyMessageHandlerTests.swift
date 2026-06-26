import XCTest
import Combine
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMMessaging

final class RecallNotifyMessageHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: RecallNotifyMessageHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = RecallNotifyMessageHandler(storage: storage)
    }

    private func makeRecallFrame(messageUid: Int64, fromUser: String) throws -> Frame {
        var notify = Im_NotifyRecallMessage()
        notify.id = messageUid
        notify.fromUser = fromUser
        let body = try notify.serializedData()
        return Frame(
            header: Header(signal: .publish, subSignal: .rmn, bodyLength: UInt32(body.count), messageId: 1),
            body: body
        )
    }

    func test_canHandle_onlyMatchesPublishAndRMN() {
        XCTAssertTrue(handler.canHandle(signal: .publish, subSignal: .rmn))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mn))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mr))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .rmn))
    }

    func test_handle_updatesMessageContentToRecalled() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 100,
            conversationType: .single, target: "them", from: "them",
            content: .text("original"), timestamp: 1_000, status: .unread, direction: .receive
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: .single, target: "them", line: 0,
            messageUid: 100, timestamp: 1_000, incrementUnread: true
        )

        let frame = try makeRecallFrame(messageUid: 100, fromUser: "them")
        handler.handle(frame: frame)

        XCTAssertEqual(try storage.messages.message(uid: 100)?.content, .recalled(operatorId: "them"))
    }

    func test_handle_firesOnRecalledWithTheMessageUid() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 2, messageUid: 200,
            conversationType: .single, target: "them", from: "them",
            content: .text("bye"), timestamp: 2_000, status: .unread, direction: .receive
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: .single, target: "them", line: 0,
            messageUid: 200, timestamp: 2_000, incrementUnread: true
        )

        var firedUid: Int64?
        handler.onRecalled = { uid in firedUid = uid }

        let frame = try makeRecallFrame(messageUid: 200, fromUser: "them")
        handler.handle(frame: frame)

        XCTAssertEqual(firedUid, 200)
    }

    func test_handle_messageNotFound_doesNotCrashAndDoesNotFireCallback() throws {
        var firedUid: Int64?
        handler.onRecalled = { uid in firedUid = uid }

        let frame = try makeRecallFrame(messageUid: 999, fromUser: "them")
        handler.handle(frame: frame)

        XCTAssertNil(firedUid)
    }

    /// Recalling a non-latest message must NOT regress the conversation's
    /// timestamp or lastMessageUid, and must NOT increment unread count.
    func test_handle_doesNotChangeConversationTimestampOrUnread() throws {
        // Insert older message (the one that will be recalled)
        try storage.messages.insert(StoredMessage(
            localMessageId: 10, messageUid: 300,
            conversationType: .single, target: "them", from: "them",
            content: .text("older"), timestamp: 1_000, status: .unread, direction: .receive
        ))
        // Insert newer message (should remain the lastMessageUid)
        try storage.messages.insert(StoredMessage(
            localMessageId: 11, messageUid: 301,
            conversationType: .single, target: "them", from: "them",
            content: .text("newer"), timestamp: 2_000, status: .unread, direction: .receive
        ))
        // Record conversation with the newer message (timestamp = 2_000, lastMessageUid = 301)
        try storage.conversations.recordIncomingMessage(
            conversationType: .single, target: "them", line: 0,
            messageUid: 301, timestamp: 2_000, incrementUnread: true
        )

        // Recall the OLDER message
        let frame = try makeRecallFrame(messageUid: 300, fromUser: "them")
        handler.handle(frame: frame)

        // Conversation ordering and pointer must be unchanged
        let conv = try storage.conversations.conversation(conversationType: .single, target: "them", line: 0)
        XCTAssertEqual(conv?.timestamp, 2_000, "timestamp must not regress to recalled message's timestamp")
        XCTAssertEqual(conv?.lastMessageUid, 301, "lastMessageUid must not be overwritten by recalled message uid")
        XCTAssertEqual(conv?.unreadCount, 1, "recall must not increment unread count")
    }

    func test_handle_malformedBody_doesNotCrash() {
        handler.handle(frame: Frame(
            header: Header(signal: .publish, subSignal: .rmn, bodyLength: 2, messageId: 1),
            body: Data([0xFF, 0xFF])
        ))
    }
}
