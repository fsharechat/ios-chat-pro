import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMMessaging

/// Covers `MessagingService.loadRemoteMessages` — the `PUBLISH`/`LRM`
/// remote-history request and its `PUB_ACK`/`LRM` response (1 byte error
/// code + `Im_PullMessageResult`, messages in *descending* uid order),
/// mirroring Android's `ProtoService.getRemoteMessages` +
/// `RemoteMessageHandler`.
final class RemoteHistoryLoadTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var scheduler: ManualScheduler!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var service: MessagingService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        scheduler = ManualScheduler()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, scheduler: scheduler, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        service = MessagingService(imClient: imClient, storage: storage, scheduler: scheduler)

        imClient.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend() // CONNECT message send completes; transport is now ready for business messages
    }

    private func decodeOnlySentFrame() throws -> Frame {
        try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
    }

    private func makeHistoryWireMessage(uid: Int64, from: String, text: String, timestamp: Int64) -> Im_Message {
        var wireMessage = Im_Message()
        wireMessage.messageID = uid
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0 // single — `required` on the wire
        wireMessage.conversation.target = from == "me" ? "them" : "me"
        wireMessage.conversation.line = 0 // `required` on the wire
        wireMessage.content = MessageContentCodec.encode(.text(text))
        wireMessage.serverTimestamp = timestamp
        return wireMessage
    }

    private func simulateLRMAck(messageId: UInt16, messages: [Im_Message]) throws {
        var pullResult = Im_PullMessageResult()
        pullResult.message = messages
        pullResult.current = 0 // `required` on the wire
        pullResult.head = 0
        var body = Data([0x00])
        body += try pullResult.serializedData()
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .lrm, messageId: messageId, body: body)
        fakeTransport.simulateReceivedData(frameBytes)
    }

    func test_loadRemoteMessages_sendsLRMRequestFrame() throws {
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 123, count: 20) { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .lrm)
        let request = try Im_LoadRemoteMessages(serializedBytes: frame.body)
        XCTAssertEqual(request.conversation.target, "them")
        XCTAssertEqual(request.conversation.type, 0)
        XCTAssertEqual(request.beforeUid, 123)
        XCTAssertEqual(request.count, 20)
    }

    func test_loadRemoteMessages_successAck_persistsHistoryAndReportsInsertedCount() throws {
        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { insertedCount = $0 }
        let sentFrame = try decodeOnlySentFrame()

        // Server returns descending uid order (newest first), like Android's
        // RemoteMessageHandler documents.
        try simulateLRMAck(messageId: sentFrame.header.messageId, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "older-9", timestamp: 900),
            makeHistoryWireMessage(uid: 8, from: "them", text: "older-8", timestamp: 800),
        ])

        XCTAssertEqual(insertedCount, 2)
        XCTAssertEqual(try storage.messages.message(uid: 8)?.content, .text("older-8"))
        XCTAssertEqual(try storage.messages.message(uid: 9)?.content, .text("older-9"))
    }

    func test_loadRemoteMessages_persistedHistory_doesNotTouchConversationOrSyncHead() throws {
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { _ in }
        let sentFrame = try decodeOnlySentFrame()

        try simulateLRMAck(messageId: sentFrame.header.messageId, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "older", timestamp: 900),
        ])

        // History paging must not resurrect the conversation preview, add
        // unread badges, or advance the incremental-pull cursor.
        XCTAssertTrue(try storage.conversations.conversations().isEmpty)
        XCTAssertEqual(try storage.syncState.get().msgHead, 0)
    }

    func test_loadRemoteMessages_alreadyStoredUid_isNotCountedAgain() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 9, conversationType: .single, target: "them", from: "them", content: .text("already-here"), timestamp: 900, status: .unread, direction: .receive))

        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { insertedCount = $0 }
        let sentFrame = try decodeOnlySentFrame()

        try simulateLRMAck(messageId: sentFrame.header.messageId, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "dup", timestamp: 900),
            makeHistoryWireMessage(uid: 8, from: "them", text: "new", timestamp: 800),
        ])

        XCTAssertEqual(insertedCount, 1)
        XCTAssertEqual(try storage.messages.message(uid: 9)?.content, .text("already-here"))
    }

    /// `persistHistory` mirrors `ReceiveMessageHandler.persist`'s call-signal
    /// filter — a 405 AnswerT mixed into a history page (e.g. it happened to
    /// land between two ordinary messages before the server-side history
    /// query excluded it) must not be persisted nor counted as inserted.
    func test_loadRemoteMessages_405AnswerTInPage_isNotPersistedOrCounted() throws {
        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { insertedCount = $0 }
        let sentFrame = try decodeOnlySentFrame()

        var answerTMessage = Im_Message()
        answerTMessage.messageID = 7
        answerTMessage.fromUser = "them"
        answerTMessage.conversation.type = 0
        answerTMessage.conversation.target = "me"
        answerTMessage.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 405
        wireContent.searchableContent = "call-1"
        wireContent.data = Data("0".utf8)
        answerTMessage.content = wireContent
        answerTMessage.serverTimestamp = 700

        try simulateLRMAck(messageId: sentFrame.header.messageId, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "older-9", timestamp: 900),
            answerTMessage,
        ])

        XCTAssertEqual(insertedCount, 1) // 只数了正常消息,405 被跳过
        XCTAssertNil(try storage.messages.message(uid: 7))
        XCTAssertEqual(try storage.messages.message(uid: 9)?.content, .text("older-9"))
    }

    func test_loadRemoteMessages_errorAck_completesWithZero() throws {
        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { insertedCount = $0 }
        let sentFrame = try decodeOnlySentFrame()

        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .lrm, messageId: sentFrame.header.messageId, body: Data([0x01]))
        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(insertedCount, 0)
    }

    func test_loadRemoteMessages_timeout_completesWithZero() throws {
        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { insertedCount = $0 }

        XCTAssertTrue(scheduler.scheduledDelays.contains(5))
        scheduler.fireNext() // the request's 5s ack timeout — the only thing scheduled here

        XCTAssertEqual(insertedCount, 0)
    }

    func test_loadRemoteMessages_ackAfterTimeout_doesNotCompleteTwice() throws {
        var completions = 0
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { _ in completions += 1 }
        let sentFrame = try decodeOnlySentFrame()

        scheduler.fireNext()
        try simulateLRMAck(messageId: sentFrame.header.messageId, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "late", timestamp: 900),
        ])

        XCTAssertEqual(completions, 1)
    }
}
