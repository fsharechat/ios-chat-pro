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

    func test_handle_groupMessageMentioningMe_incrementsUnreadMentionCount() throws {
        var message = makeWireMessage(uid: 300, from: "them", target: "g1", text: "hi @me")
        message.conversation.type = 1 // group
        message.content.mentionedType = 1
        message.content.mentionedTarget = ["me"]
        let frame = try makePullResultFrame(messages: [message], head: 300)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .group, target: "g1")
        XCTAssertEqual(conversation?.unreadMentionCount, 1)
        XCTAssertEqual(try storage.messages.message(uid: 300)?.mentionedTargets, ["me"])
    }

    func test_handle_groupMessageMentioningAll_incrementsUnreadMentionCount() throws {
        var message = makeWireMessage(uid: 301, from: "them", target: "g1", text: "hi everyone")
        message.conversation.type = 1 // group
        message.content.mentionedType = 2
        let frame = try makePullResultFrame(messages: [message], head: 301)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .group, target: "g1")
        XCTAssertEqual(conversation?.unreadMentionCount, 1)
    }

    func test_handle_groupMessageMentioningSomeoneElse_doesNotIncrementUnreadMentionCount() throws {
        var message = makeWireMessage(uid: 302, from: "them", target: "g1", text: "hi @other")
        message.conversation.type = 1
        message.content.mentionedType = 1
        message.content.mentionedTarget = ["someone-else"]
        let frame = try makePullResultFrame(messages: [message], head: 302)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .group, target: "g1")
        XCTAssertEqual(conversation?.unreadMentionCount, 0)
    }

    func test_handle_groupNotificationMessage_firesOnGroupNotificationMessageWithGroupId() throws {
        var capturedGroupId: String?
        handler.onGroupNotificationMessage = { capturedGroupId = $0 }

        var message = Im_Message()
        message.messageID = 400
        message.fromUser = "them"
        message.conversation.type = 1 // group
        message.conversation.target = "g1"
        message.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 105 // addGroupMember
        wireContent.data = Data("""
        {"g":"g1","o":"them","ms":["me"]}
        """.utf8)
        message.content = wireContent
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 400)

        handler.handle(frame: frame)

        XCTAssertEqual(capturedGroupId, "g1")
    }

    func test_handle_groupNotificationWithEmptyOperatorInPayload_fallsBackToFromUser() throws {
        var message = Im_Message()
        message.messageID = 401
        message.fromUser = "them"
        message.conversation.type = 1
        message.conversation.target = "g1"
        message.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 107 // quitGroup — never carries a reliable operator in its payload
        message.content = wireContent
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 401)

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.messages.message(uid: 401)?.content, .groupNotification(type: .quitGroup, operatorUid: "them", memberUids: [], value: nil))
    }

    func test_handle_singleChatMessage_neverIncrementsUnreadMentionCountEvenIfMentionedTypeSet() throws {
        var message = makeWireMessage(uid: 303, from: "them", target: "them", text: "hi")
        message.content.mentionedType = 2 // shouldn't happen in practice for single chat, but must not crash/miscount
        let frame = try makePullResultFrame(messages: [message], head: 303)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .single, target: "them")
        XCTAssertEqual(conversation?.unreadMentionCount, 0)
    }
}
