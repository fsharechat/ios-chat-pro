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
    /// `IMClient` 自己的定时器(握手超时/心跳/退避重连)走独立 scheduler,
    /// 这样 `scheduler` 上排的就只有远程历史请求的空闲超时,`fireNext()`
    /// 的顺序不会被连接层的内部计时打乱。
    private var clientScheduler: ManualScheduler!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var service: MessagingService!
    /// 受控时钟,供空闲超时的硬上限用例推进时间。
    private var currentMillis: Int64 = 1_000_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        scheduler = ManualScheduler()
        clientScheduler = ManualScheduler()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, scheduler: clientScheduler, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        service = MessagingService(imClient: imClient, storage: storage, scheduler: scheduler, nowMillis: { [unowned self] in self.currentMillis })

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

    private func makeLRMAckFrameBytes(messageId: UInt16, messages: [Im_Message]) throws -> Data {
        var pullResult = Im_PullMessageResult()
        pullResult.message = messages
        pullResult.current = 0 // `required` on the wire
        pullResult.head = 0
        var body = Data([0x00])
        body += try pullResult.serializedData()
        return FrameEncoder.encode(signal: .pubAck, subSignal: .lrm, messageId: messageId, body: body)
    }

    private func simulateLRMAck(messageId: UInt16, messages: [Im_Message]) throws {
        fakeTransport.simulateReceivedData(try makeLRMAckFrameBytes(messageId: messageId, messages: messages))
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

    /// A server error is a *failed request* (`nil`), distinct from a
    /// successful-but-empty page (`0`) — the conversation screen only stops
    /// re-asking on the latter.
    func test_loadRemoteMessages_errorAck_completesWithNil() throws {
        var completed = false
        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { completed = true; insertedCount = $0 }
        let sentFrame = try decodeOnlySentFrame()

        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .lrm, messageId: sentFrame.header.messageId, body: Data([0x01]))
        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertTrue(completed)
        XCTAssertNil(insertedCount)
    }

    func test_loadRemoteMessages_idleTimeout_completesWithNil() throws {
        var completed = false
        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { completed = true; insertedCount = $0 }

        XCTAssertTrue(scheduler.scheduledDelays.contains(10))
        scheduler.fireNext() // the request's idle timeout — the only thing scheduled here

        XCTAssertTrue(completed)
        XCTAssertNil(insertedCount)
    }

    func test_loadRemoteMessages_successEmptyPage_completesWithZero() throws {
        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { insertedCount = $0 }
        let sentFrame = try decodeOnlySentFrame()

        try simulateLRMAck(messageId: sentFrame.header.messageId, messages: [])

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

    /// 迟到的响应仍然入库:字节已经收下、protobuf 已经解完,此刻丢掉只会让
    /// 下次下拉重新下载同一页——慢链路上那正是历史永远拉不出来的死循环。
    func test_loadRemoteMessages_ackAfterTimeout_stillPersistsHistory() throws {
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { _ in }
        let sentFrame = try decodeOnlySentFrame()

        scheduler.fireNext() // 空闲超时先到,调用方已收到 nil
        try simulateLRMAck(messageId: sentFrame.header.messageId, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "late-but-useful", timestamp: 900),
        ])

        XCTAssertEqual(try storage.messages.message(uid: 9)?.content, .text("late-but-useful"))
    }

    // MARK: - 空闲超时:响应还在流式到达就续期

    /// 一页 180 KB 的历史在慢链路上要收好几个空闲窗口那么久。只要字节还在
    /// 推进,请求就不该被判死——这是原来固定 5 秒超时误杀的场景。
    func test_loadRemoteMessages_responseStillStreamingIn_renewsIdleTimeoutAndSucceeds() throws {
        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { insertedCount = $0 }
        let sentFrame = try decodeOnlySentFrame()
        XCTAssertEqual(scheduler.pendingCount, 1)

        let ackBytes = try makeLRMAckFrameBytes(messageId: sentFrame.header.messageId, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "older-9", timestamp: 900),
            makeHistoryWireMessage(uid: 8, from: "them", text: "older-8", timestamp: 800),
        ])
        let firstCut = Header.length + 10
        let secondCut = Header.length + 20

        currentMillis += 8_000
        fakeTransport.simulateReceivedData(ackBytes.prefix(firstCut))
        XCTAssertEqual(scheduler.scheduledDelays.count, 2, "有新字节到达就应重排一枚新的空闲超时")
        XCTAssertEqual(scheduler.pendingCount, 1, "旧的那枚必须被取消,不能两枚并存")

        currentMillis += 8_000
        fakeTransport.simulateReceivedData(ackBytes[firstCut..<secondCut])
        XCTAssertEqual(scheduler.scheduledDelays.count, 3)
        XCTAssertEqual(scheduler.pendingCount, 1)

        currentMillis += 8_000
        fakeTransport.simulateReceivedData(ackBytes.suffix(from: secondCut))

        // 总耗时 24 秒,远超单个 10 秒空闲窗口,仍然成功。
        XCTAssertEqual(insertedCount, 2)
        XCTAssertEqual(try storage.messages.message(uid: 8)?.content, .text("older-8"))
    }

    func test_loadRemoteMessages_progressOfUnrelatedRequest_doesNotRenewTimeout() throws {
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { _ in }
        let sentFrame = try decodeOnlySentFrame()

        // 同为 PUB_ACK/LRM,但 messageId 不是自己那一笔。
        let otherBytes = try makeLRMAckFrameBytes(messageId: sentFrame.header.messageId &+ 99, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "someone-else", timestamp: 900),
        ])
        fakeTransport.simulateReceivedData(otherBytes.prefix(Header.length + 5))

        XCTAssertEqual(scheduler.scheduledDelays.count, 1, "不该被别人的响应续期")
    }

    /// 硬上限:防止服务端以慢速滴灌把一个请求无限吊住。
    func test_loadRemoteMessages_progressAfterMaxDuration_stopsRenewing() throws {
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { _ in }
        let sentFrame = try decodeOnlySentFrame()

        let ackBytes = try makeLRMAckFrameBytes(messageId: sentFrame.header.messageId, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "trickle", timestamp: 900),
        ])
        currentMillis += 61_000
        fakeTransport.simulateReceivedData(ackBytes.prefix(Header.length + 5))

        XCTAssertEqual(scheduler.scheduledDelays.count, 1, "过了 60 秒硬上限就不再续期")
    }

    // MARK: - 断连立即判失败

    func test_loadRemoteMessages_connectionDrops_completesWithNilImmediately() throws {
        var completed = false
        var insertedCount: Int?
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { completed = true; insertedCount = $0 }

        fakeTransport.simulate(.cancelled)

        XCTAssertTrue(completed, "不该让调用方干等满整个空闲窗口")
        XCTAssertNil(insertedCount)
    }

    func test_loadRemoteMessages_afterConnectionDrops_lateAckDoesNotCompleteTwice() throws {
        var completions = 0
        service.loadRemoteMessages(conversationType: .single, target: "them", line: 0, beforeUid: 10, count: 20) { _ in completions += 1 }
        let sentFrame = try decodeOnlySentFrame()

        fakeTransport.simulate(.cancelled)
        try simulateLRMAck(messageId: sentFrame.header.messageId, messages: [
            makeHistoryWireMessage(uid: 9, from: "them", text: "late", timestamp: 900),
        ])

        XCTAssertEqual(completions, 1)
    }
}
