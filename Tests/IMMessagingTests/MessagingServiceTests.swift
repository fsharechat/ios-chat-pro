import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMMessaging

final class MessagingServiceTests: XCTestCase {
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
        let frame = try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
        return frame
    }

    func test_sendText_insertsLocalEchoAndSendsCorrectWireFrame() throws {
        try service.sendText(to: "them", text: "hello")

        let echo = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(echo?.content, .text("hello"))
        XCTAssertEqual(echo?.status, .sending)

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .ms)
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.fromUser, "me")
        XCTAssertEqual(wireMessage.conversation.target, "them")
        XCTAssertEqual(try MessageContentCodec.decode(wireMessage.content), .text("hello"))
        XCTAssertEqual(wireMessage.localMessageID, echo?.localMessageId)
    }

    func test_sendText_ackArrival_updatesStatusAndMessageUid() throws {
        try service.sendText(to: "them", text: "hello")
        let sentFrame = try decodeOnlySentFrame()

        var ackBody: [UInt8] = [0x00]
        let uidBytes = (0..<8).map { UInt8((UInt64(bitPattern: 999) >> (8 * (7 - $0))) & 0xFF) }
        let tsBytes = (0..<8).map { UInt8((UInt64(bitPattern: 1_234) >> (8 * (7 - $0))) & 0xFF) }
        ackBody += uidBytes + tsBytes
        let ackFrameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .ms, messageId: sentFrame.header.messageId, body: Data(ackBody))
        fakeTransport.simulateReceivedData(ackFrameBytes)

        let updated = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(updated?.status, .sent)
        XCTAssertEqual(updated?.messageUid, 999)
    }

    func test_sendText_timeout_marksSendFailure() throws {
        try service.sendText(to: "them", text: "hello")

        XCTAssertTrue(scheduler.scheduledDelays.contains(5))
        scheduler.fireNext() // fires the 5s ack timeout (the only thing scheduled at this point)

        let updated = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(updated?.status, .sendFailure)
    }

    func test_receivingPullResult_isHandledEndToEnd() throws {
        var pullResult = Im_PullMessageResult()
        var wireMessage = Im_Message()
        wireMessage.messageID = 100
        wireMessage.fromUser = "them"
        wireMessage.conversation.type = 0 // single — `required` on the wire
        wireMessage.conversation.target = "them"
        wireMessage.conversation.line = 0 // `required` on the wire
        wireMessage.content = MessageContentCodec.encode(.text("incoming"))
        wireMessage.serverTimestamp = 1_000
        pullResult.message = [wireMessage]
        pullResult.current = 100 // `required` on the wire
        pullResult.head = 100
        var body = Data([0x00]) // success error-code byte — every PUB_ACK response has this prefix, enforced server-side
        body += try pullResult.serializedData()
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(try storage.messages.message(uid: 100)?.content, .text("incoming"))
        XCTAssertEqual(try storage.syncState.get().msgHead, 100)
    }

    func test_receivingNotify_sendsAPullRequest() throws {
        var notify = Im_NotifyMessage()
        notify.head = 50
        notify.type = 0
        let body = try notify.serializedData()
        let frameBytes = FrameEncoder.encode(signal: .publish, subSignal: .mn, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .mp)
        let request = try Im_PullMessageRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.id, 49) // head - 1
    }

    func test_pullMessagesSinceLastSync_sendsPullRequestSeededFromSyncState() throws {
        service.pullMessagesSinceLastSync(syncState: ConnectAckSyncState(messageHead: 77, friendHead: 0, friendRequestHead: 0, settingHead: 0, serverTime: 0))

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .mp)
        let request = try Im_PullMessageRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.id, 77)
    }

    func test_resend_afterSendFailure_resetsStatusAndSendsNewWireFrame() throws {
        try service.sendText(to: "them", text: "hello")
        scheduler.fireNext() // 5s ack timeout fires -> .sendFailure
        let failed = try storage.messages.messages(conversationType: .single, target: "them").first!
        XCTAssertEqual(failed.status, .sendFailure)

        try service.resend(localMessageId: failed.localMessageId)

        let resending = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(resending?.status, .sending)

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .ms)
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.localMessageID, failed.localMessageId)
        XCTAssertEqual(try MessageContentCodec.decode(wireMessage.content), .text("hello"))
    }

    func test_resend_ackArrival_updatesStatusAndMessageUid() throws {
        try service.sendText(to: "them", text: "hello")
        scheduler.fireNext()
        let failed = try storage.messages.messages(conversationType: .single, target: "them").first!

        try service.resend(localMessageId: failed.localMessageId)
        let resendFrame = try decodeOnlySentFrame()

        var ackBody: [UInt8] = [0x00]
        let uidBytes = (0..<8).map { UInt8((UInt64(bitPattern: 999) >> (8 * (7 - $0))) & 0xFF) }
        let tsBytes = (0..<8).map { UInt8((UInt64(bitPattern: 1_234) >> (8 * (7 - $0))) & 0xFF) }
        ackBody += uidBytes + tsBytes
        let ackFrameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .ms, messageId: resendFrame.header.messageId, body: Data(ackBody))
        fakeTransport.simulateReceivedData(ackFrameBytes)

        let updated = try storage.messages.messages(conversationType: .single, target: "them").first
        XCTAssertEqual(updated?.status, .sent)
        XCTAssertEqual(updated?.messageUid, 999)
    }

    func test_resend_unknownLocalMessageId_isANoOp() throws {
        let countBefore = fakeTransport.sentFrames.count

        try service.resend(localMessageId: 99999)

        XCTAssertEqual(fakeTransport.sentFrames.count, countBefore)
    }

    func test_resend_onMessageNotInSendFailureState_isANoOp() throws {
        try service.sendText(to: "them", text: "hello") // status is .sending, not .sendFailure
        let pending = try storage.messages.messages(conversationType: .single, target: "them").first!
        let countBefore = fakeTransport.sentFrames.count

        try service.resend(localMessageId: pending.localMessageId)

        XCTAssertEqual(fakeTransport.sentFrames.count, countBefore)
        XCTAssertEqual(try storage.messages.messages(conversationType: .single, target: "them").first?.status, .sending)
    }

    func test_sendText_withMention_encodesMentionedTypeAndTargetsOnTheWireMessage() throws {
        try service.sendText(to: "g1", conversationType: .group, text: "hi @u2", mentionedType: 1, mentionedTargets: ["u2"])

        let frame = try decodeOnlySentFrame()
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.content.mentionedType, 1)
        XCTAssertEqual(wireMessage.content.mentionedTarget, ["u2"])
    }

    func test_sendText_withMention_alsoPersistsMentionFieldsLocally() throws {
        try service.sendText(to: "g1", conversationType: .group, text: "hi @u2", mentionedType: 1, mentionedTargets: ["u2"])

        let stored = try storage.messages.messages(conversationType: .group, target: "g1").first
        XCTAssertEqual(stored?.mentionedType, 1)
        XCTAssertEqual(stored?.mentionedTargets, ["u2"])
    }

    func test_onGroupNotificationMessage_forwardsToTheInternalReceiveMessageHandler() throws {
        var capturedGroupId: String?
        service.onGroupNotificationMessage = { capturedGroupId = $0 }

        var wireMessage = Im_Message()
        wireMessage.messageID = 500
        wireMessage.fromUser = "them"
        wireMessage.conversation.type = 1
        wireMessage.conversation.target = "g1"
        wireMessage.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 108 // dismissGroup
        wireContent.data = Data("""
        {"g":"g1","o":"them"}
        """.utf8)
        wireMessage.content = wireContent
        wireMessage.serverTimestamp = 1_000

        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = 500 // `required` on the wire
        result.head = 500
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(capturedGroupId, "g1")
    }

    func test_sendCallStart_insertsLocalEchoAndSendsWireFrame() throws {
        let echo = try service.sendCallStart(targetId: "them", callId: "call-1", audioOnly: false)

        XCTAssertEqual(echo.content, .callRecord(callId: "call-1", targetId: "them", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
        XCTAssertNotNil(echo.id)

        let frame = try decodeOnlySentFrame()
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.content.type, 400)
        XCTAssertEqual(try MessageContentCodec.decode(wireMessage.content), .callRecord(callId: "call-1", targetId: "them", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
    }

    func test_sendCallControlMessage_doesNotInsertAnyLocalRow() throws {
        let countBefore = try storage.messages.messages(conversationType: .single, target: "them").count

        try service.sendCallControlMessage(to: "them", wireType: 402, callId: "call-1", dataPayload: nil)

        XCTAssertEqual(try storage.messages.messages(conversationType: .single, target: "them").count, countBefore)
    }

    func test_sendCallControlMessage_sendsCorrectWireFrame() throws {
        try service.sendCallControlMessage(to: "them", wireType: 403, callId: "call-1", dataPayload: Data("""
        {"type":"offer","sdp":"v=0..."}
        """.utf8))

        let frame = try decodeOnlySentFrame()
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.fromUser, "me")
        XCTAssertEqual(wireMessage.conversation.target, "them")
        XCTAssertEqual(wireMessage.content.type, 403)
        XCTAssertEqual(wireMessage.content.searchableContent, "call-1")
        XCTAssertTrue(wireMessage.content.data.starts(with: Data("{\"type\":\"offer\"".utf8)))
    }

    func test_onCallStartMessage_forwardsToTheInternalReceiveMessageHandler() throws {
        var captured: StoredMessage?
        service.onCallStartMessage = { captured = $0 }

        var wireMessage = Im_Message()
        wireMessage.messageID = 700
        wireMessage.fromUser = "them"
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = "them"
        wireMessage.conversation.line = 0
        wireMessage.content = MessageContentCodec.encode(.callRecord(callId: "call-3", targetId: "me", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
        wireMessage.serverTimestamp = 1_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = 700
        result.head = 700
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(captured?.from, "them")
    }

    func test_onCallSignal_forwardsToTheInternalReceiveMessageHandler() throws {
        var captured: Im_Message?
        service.onCallSignal = { captured = $0 }

        var wireMessage = Im_Message()
        wireMessage.messageID = 701
        wireMessage.fromUser = "them"
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = "them"
        wireMessage.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 402
        wireContent.searchableContent = "call-3"
        wireMessage.content = wireContent
        wireMessage.serverTimestamp = 1_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = 701
        result.head = 701
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(captured?.content.type, 402)
    }
}
