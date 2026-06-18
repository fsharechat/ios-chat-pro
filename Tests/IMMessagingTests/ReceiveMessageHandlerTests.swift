import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMMessaging

final class ReceiveMessageHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: ReceiveMessageHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = ReceiveMessageHandler(storage: storage, myUserId: { "me" })
    }

    private func makeWireMessage(uid: Int64, from: String, target: String, localId: Int64 = 0, text: String = "hi", timestamp: Int64 = 1_000) -> Im_Message {
        var message = Im_Message()
        message.messageID = uid
        message.fromUser = from
        message.conversation.type = 0 // single
        message.conversation.target = target
        message.conversation.line = 0
        message.content = MessageContentCodec.encode(.text(text))
        message.serverTimestamp = timestamp
        message.localMessageID = localId
        return message
    }

    private func makePullResultFrame(messages: [Im_Message], head: Int64) throws -> Frame {
        var result = Im_PullMessageResult()
        result.message = messages
        result.head = head
        result.current = head
        var body = Data([0x00]) // success error-code byte — every PUB_ACK response has this prefix, enforced server-side; see ReceiveMessageHandler's doc comment
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .mp, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndMP() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .mp))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .ms))
    }

    func test_handle_newReceivedMessage_persistsAndIncrementsConversationUnread() throws {
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 100, from: "them", target: "them", text: "hello")], head: 100)

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.messages.message(uid: 100)?.content, .text("hello"))
        let conversation = try storage.conversations.conversation(conversationType: .single, target: "them")
        XCTAssertEqual(conversation?.unreadCount, 1)
        XCTAssertEqual(try storage.syncState.get().msgHead, 100)
    }

    func test_handle_ownSentMessageInPull_doesNotIncrementUnread() throws {
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 101, from: "me", target: "them", text: "from me")], head: 101)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .single, target: "them")
        XCTAssertEqual(conversation?.unreadCount, 0)
        XCTAssertEqual(try storage.messages.message(uid: 101)?.direction, .send)
    }

    func test_handle_duplicateByUid_doesNotInsertTwiceOrDoubleCountUnread() throws {
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 102, from: "them", target: "them")], head: 102)
        handler.handle(frame: frame)
        handler.handle(frame: frame) // overlapping pull window redelivers the same uid

        let conversation = try storage.conversations.conversation(conversationType: .single, target: "them")
        XCTAssertEqual(conversation?.unreadCount, 1)
    }

    func test_handle_ownMessageAlreadyLocallyEchoed_updatesInPlaceRatherThanDuplicating() throws {
        // Simulate: I sent a message (local echo inserted, status .sending,
        // messageUid still 0), then a pull redelivers it before my own
        // send's ack arrived.
        try storage.messages.insert(StoredMessage(
            localMessageId: 555, conversationType: .single, target: "them", from: "me",
            content: .text("already echoed"), timestamp: 1_000, status: .sending, direction: .send
        ))

        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 200, from: "me", target: "them", localId: 555, text: "already echoed")], head: 200)
        handler.handle(frame: frame)

        let messages = try storage.messages.messages(conversationType: .single, target: "them")
        XCTAssertEqual(messages.count, 1) // not duplicated
        XCTAssertEqual(messages.first?.messageUid, 200)
        XCTAssertEqual(messages.first?.status, .sent)
    }

    func test_handle_syncHeadOnlyAdvancesForward() throws {
        try storage.syncState.set(StoredSyncState(msgHead: 500, friendHead: 1, friendRequestHead: 2, settingHead: 3))

        let frame = try makePullResultFrame(messages: [], head: 100) // a stale/out-of-order pull response
        handler.handle(frame: frame)

        let state = try storage.syncState.get()
        XCTAssertEqual(state.msgHead, 500) // unchanged, not regressed to 100
        XCTAssertEqual(state.friendHead, 1) // other fields preserved
    }

    func test_handle_nonZeroErrorCode_doesNothingNoCrash() throws {
        let initialMsgHead = try storage.syncState.get().msgHead
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .mp, bodyLength: 1, messageId: 1), body: Data([0x01]))

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.syncState.get().msgHead, initialMsgHead)
    }

    func test_handle_emptyBody_doesNothingNoCrash() throws {
        let initialMsgHead = try storage.syncState.get().msgHead
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .mp, bodyLength: 0, messageId: 1), body: Data())

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.syncState.get().msgHead, initialMsgHead)
    }
}
