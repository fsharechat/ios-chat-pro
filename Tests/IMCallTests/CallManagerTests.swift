import XCTest
import Foundation
import IMClient
import IMTransport
import IMProto
import IMStorage
import IMMessaging
@testable import IMCall

final class CallManagerTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var scheduler: ManualScheduler!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var messagingService: MessagingService!
    private var mediaEngine: FakeMediaEngine!
    private var manager: CallManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        scheduler = ManualScheduler()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, scheduler: scheduler, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        messagingService = MessagingService(imClient: imClient, storage: storage, scheduler: scheduler)
        imClient.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()

        mediaEngine = FakeMediaEngine()
        manager = CallManager(messagingService: messagingService, storage: storage, mediaEngine: mediaEngine, scheduler: scheduler, myUserId: { "me" })
    }

    private func sentWireMessages() throws -> [Im_Message] {
        // `try?` (not `try`) on the inner decode: `sentFrames` also contains
        // non-`Im_Message` frames sent by `IMClient` itself (the JSON
        // CONNECT handshake frame from `setUpWithError`, and any heartbeat
        // PINGs) — those aren't valid protobuf and must be skipped rather
        // than aborting the whole scan, exactly like `MessagingServiceTests`
        // sidesteps the same frames by only ever looking at `sentFrames.last`.
        fakeTransport.sentFrames.compactMap { data in
            FrameDecoder().feed(data).first.flatMap { try? Im_Message(serializedBytes: $0.body) }
        }
    }

    private func deliverSignal(_ signal: OutgoingCallSignal, from: String) throws {
        let encoded = CallSignalCodec.encode(signal)
        var wireMessage = Im_Message()
        wireMessage.messageID = Int64.random(in: 1_000_000...9_999_999)
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = "me"
        wireMessage.conversation.line = 0
        var content = Im_MessageContent()
        content.type = encoded.wireType
        content.searchableContent = encoded.callId
        if let data = encoded.data { content.data = data }
        wireMessage.content = content
        wireMessage.serverTimestamp = 1_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = wireMessage.messageID
        result.head = wireMessage.messageID
        let body = Data([0x00]) + (try result.serializedData())
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body))
    }

    func test_startCall_transitionsToOutgoingAndSendsCallStart() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertEqual(manager.state, .outgoing)
        XCTAssertEqual(manager.peerUid, "them")
        let messages = try sentWireMessages()
        XCTAssertEqual(messages.first?.content.type, 400)
    }

    func test_startCall_startsMediaEngineAndSendsOfferAsSignal() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertEqual(mediaEngine.startCalls, [false])
        XCTAssertEqual(mediaEngine.createOfferCallCount, 1)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 403 })
    }

    func test_startCall_whenNotIdle_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let countBefore = try sentWireMessages().count

        try manager.startCall(to: "someone-else", audioOnly: false)

        XCTAssertEqual(manager.peerUid, "them") // unchanged
        XCTAssertEqual(try sentWireMessages().count, countBefore)
    }

    func test_receivingAnswer_transitionsToConnecting() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")

        XCTAssertEqual(manager.state, .connecting)
    }

    func test_mediaEngineConnected_transitionsToConnectedAndUpdatesBubble() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")

        mediaEngine.simulateConnected()

        XCTAssertEqual(manager.state, .connected)
        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, let connectTime, _) = bubble?.content {
            XCTAssertEqual(status, 1)
            XCTAssertGreaterThan(connectTime, 0)
        } else {
            XCTFail("expected a callRecord bubble")
        }
    }

    func test_hangUp_sendsByeAndReturnsToIdle() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try manager.hangUp()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.peerUid)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 402 })
    }

    func test_hangUp_updatesBubbleToEndedStatus() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        try manager.hangUp()

        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, let connectTime, let endTime) = bubble?.content {
            XCTAssertEqual(status, 2)
            XCTAssertGreaterThan(connectTime, 0) // preserved from the earlier .connected update
            XCTAssertGreaterThan(endTime, 0)
        } else {
            XCTFail("expected a callRecord bubble")
        }
    }

    func test_hangUp_whenIdle_isANoOp() throws {
        XCTAssertNoThrow(try manager.hangUp())
        XCTAssertEqual(manager.state, .idle)
    }

    func test_receivingBye_endsCallAndUpdatesBubble() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.bye(callId: callIdFromLastCallStart()), from: "them")

        XCTAssertEqual(manager.state, .idle)
        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, _, _) = bubble?.content {
            XCTAssertEqual(status, 2)
        } else {
            XCTFail("expected a callRecord bubble")
        }
    }

    func test_answerTimeout_60Seconds_endsCallAsTimeoutAndSendsBye() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertTrue(scheduler.scheduledDelays.contains(60))
        var endedReason: CallEndReason?
        manager.onCallEnded = { endedReason = $0 }
        scheduler.fireNext()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endedReason, .timeout)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 402 })
    }

    func test_connectingTimeout_60SecondsAfterAnswer_endsCallAsTimeout() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        scheduler.pendingCount > 0 ? () : XCTFail("expected the connecting timer to be scheduled")

        var endedReason: CallEndReason?
        manager.onCallEnded = { endedReason = $0 }
        scheduler.fireNext() // fires the connecting-timeout (the only thing pending after answer cancels the answer-timeout)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endedReason, .timeout)
    }

    func test_receivingSdpAnswer_forwardsToMediaEngine() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.sdpAnswer(callId: callIdFromLastCallStart(), sdp: "remote-answer-sdp"), from: "them")

        XCTAssertEqual(mediaEngine.remoteAnswers, ["remote-answer-sdp"])
    }

    func test_receivingIceCandidate_forwardsToMediaEngine() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.iceCandidate(callId: callIdFromLastCallStart(), sdpMLineIndex: 1, sdpMid: "video", candidate: "candidate:9..."), from: "them")

        XCTAssertEqual(mediaEngine.remoteCandidates.count, 1)
        XCTAssertEqual(mediaEngine.remoteCandidates.first?.0, 1)
        XCTAssertEqual(mediaEngine.remoteCandidates.first?.1, "video")
    }

    func test_mediaEngineLocalCandidate_sentAsSignal403() throws {
        try manager.startCall(to: "them", audioOnly: false)

        mediaEngine.simulateLocalCandidate(sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1...")

        let messages = try sentWireMessages()
        let signalMessages = messages.filter { $0.content.type == 403 }
        XCTAssertTrue(signalMessages.contains { CallSignalCodec.decode($0) == .iceCandidate(callId: callIdFromLastCallStart(), sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1...") })
    }

    func test_mediaEngineDisconnectedAfterConnected_endsCallAsMediaFailure() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        var endedReason: CallEndReason?
        manager.onCallEnded = { endedReason = $0 }
        mediaEngine.simulateDisconnected()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endedReason, .mediaFailure)
    }

    // MARK: - Helpers

    private func callIdFromLastCallStart() -> String {
        guard let message = try? sentWireMessages().first(where: { $0.content.type == 400 }),
              case .callRecord(let callId, _, _, _, _, _) = try! MessageContentCodec.decode(message.content) else {
            XCTFail("expected a sent CallStart")
            return ""
        }
        return callId
    }
}
