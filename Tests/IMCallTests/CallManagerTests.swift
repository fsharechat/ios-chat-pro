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
    private var callKitAdapter: FakeCallKitAdapter!

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
        callKitAdapter = FakeCallKitAdapter()
        manager.callKitAdapter = callKitAdapter
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

    func test_receivingCallStartWhileIdle_transitionsToIncomingAndFiresCallback() throws {
        var capturedPeer: String?
        var capturedAudioOnly: Bool?
        manager.onIncomingCall = { peer, audioOnly in capturedPeer = peer; capturedAudioOnly = audioOnly }

        try deliverCallStart(callId: "call-incoming-1", audioOnly: true, from: "them")

        XCTAssertEqual(manager.state, .incoming)
        XCTAssertEqual(manager.peerUid, "them")
        XCTAssertEqual(capturedPeer, "them")
        XCTAssertEqual(capturedAudioOnly, true)
    }

    func test_receivingCallStartWhileIdle_startsAnswerTimeoutTimer() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")
        XCTAssertTrue(scheduler.scheduledDelays.contains(60))
    }

    func test_answer_onIncomingCall_sendsAnswerSignalAndTransitionsToConnecting() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")

        try manager.answer()

        XCTAssertEqual(manager.state, .connecting)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 401 })
    }

    func test_answer_withAlreadyBufferedOffer_createsAndSendsAnswerSDP() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")
        try deliverSignal(.sdpOffer(callId: "call-incoming-1", sdp: "remote-offer-sdp"), from: "them")

        try manager.answer()

        XCTAssertEqual(mediaEngine.createAnswerCalls, ["remote-offer-sdp"])
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .sdpAnswer(callId: "call-incoming-1", sdp: mediaEngine.answerSDPToReturn) })
    }

    func test_offerArrivingAfterAnswer_createsAndSendsAnswerSDPImmediately() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")
        try manager.answer() // no offer buffered yet

        try deliverSignal(.sdpOffer(callId: "call-incoming-1", sdp: "late-offer-sdp"), from: "them")

        XCTAssertEqual(mediaEngine.createAnswerCalls, ["late-offer-sdp"])
    }

    func test_secondCallStartWhileBusy_autoRejectsWithBye() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()

        try deliverCallStart(callId: "call-2", audioOnly: false, from: "someone-else", target: "me")

        XCTAssertEqual(manager.state, .connecting) // untouched — still the original call
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "call-2") })
    }

    func test_glare_myUidSmaller_myOutgoingCallContinues_rejectsTheirs() throws {
        // "me" < "them" lexicographically — I win.
        try manager.startCall(to: "them", audioOnly: false)
        let myCallId = callIdFromLastCallStart()

        try deliverCallStart(callId: "their-call-id", audioOnly: false, from: "them")

        XCTAssertEqual(manager.state, .outgoing) // my call is untouched
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "their-call-id") })
        _ = myCallId
    }

    func test_glare_myUidLarger_abandonsMyOutgoingAndAcceptsTheirs() throws {
        // "me" > "a" lexicographically — I lose, and accept their call instead.
        let losingManager = CallManager(messagingService: messagingService, storage: storage, mediaEngine: mediaEngine, scheduler: scheduler, myUserId: { "me" })
        let losingManagerCallKitAdapter = FakeCallKitAdapter()
        losingManager.callKitAdapter = losingManagerCallKitAdapter
        try losingManager.startCall(to: "a", audioOnly: false)
        let abandonedCallId = losingManagerCallKitAdapter.reportedOutgoingStarted.first!
        var capturedPeer: String?
        losingManager.onIncomingCall = { peer, _ in capturedPeer = peer }

        try deliverCallStart(callId: "their-call-id", audioOnly: true, from: "a", target: "me", manager: losingManager)

        XCTAssertEqual(losingManager.state, .incoming)
        XCTAssertEqual(capturedPeer, "a")

        let abandonedBubble = try storage.messages.messages(conversationType: .single, target: "a").last
        if case .callRecord(_, _, _, let status, let connectTime, _) = abandonedBubble?.content {
            XCTAssertEqual(status, 2) // retired, not stuck at "calling..."
            XCTAssertEqual(connectTime, 0) // never connected
        } else {
            XCTFail("expected the abandoned outgoing call's bubble to still be a callRecord")
        }

        // The abandoned outgoing call must also be retired in CallKit's own
        // ledger before the new incoming call overwrites the adapter's
        // single-call tracking — otherwise it's left as a dangling,
        // never-ended system call.
        XCTAssertEqual(losingManagerCallKitAdapter.reportedEnded.first?.callId, abandonedCallId)
        XCTAssertEqual(losingManagerCallKitAdapter.reportedEnded.first?.reason, .localHangup)
        XCTAssertEqual(losingManagerCallKitAdapter.reportedIncomingCalls.first?.callId, "their-call-id")
    }

    func test_startCall_reportsOutgoingCallStartedToCallKit() throws {
        try manager.startCall(to: "them", audioOnly: false)
        XCTAssertEqual(callKitAdapter.reportedOutgoingStarted, [callIdFromLastCallStart()])
    }

    func test_incomingCallStart_reportsIncomingCallToCallKit() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: true, from: "them")
        XCTAssertEqual(callKitAdapter.reportedIncomingCalls.first?.callId, "call-incoming-1")
        XCTAssertEqual(callKitAdapter.reportedIncomingCalls.first?.callerName, "them")
        XCTAssertEqual(callKitAdapter.reportedIncomingCalls.first?.audioOnly, true)
    }

    func test_mediaEngineConnected_reportsConnectedToCallKit() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")

        mediaEngine.simulateConnected()

        XCTAssertEqual(callKitAdapter.reportedConnected, [callId])
    }

    func test_hangUp_reportsCallEndedToCallKit() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()

        try manager.hangUp()

        XCTAssertEqual(callKitAdapter.reportedEnded.first?.callId, callId)
        XCTAssertEqual(callKitAdapter.reportedEnded.first?.reason, .localHangup)
    }

    func test_setAudioOnly_whileConnected_sendsModifySignalAndUpdatesLocalStateAndMediaEngine() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        try manager.setAudioOnly(true)

        XCTAssertEqual(manager.audioOnly, true)
        XCTAssertEqual(mediaEngine.audioOnlyCalls, [true])
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .modify(callId: callId, audioOnly: true) })
    }

    func test_setAudioOnly_whileConnecting_sendsModifySignal() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")

        try manager.setAudioOnly(true)

        XCTAssertEqual(manager.audioOnly, true)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .modify(callId: callId, audioOnly: true) })
    }

    func test_setAudioOnly_whileIdle_isANoOp() throws {
        XCTAssertNoThrow(try manager.setAudioOnly(true))
        XCTAssertEqual(manager.audioOnly, false)
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
    }

    func test_setAudioOnly_whileOutgoing_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertNoThrow(try manager.setAudioOnly(true))

        XCTAssertEqual(manager.audioOnly, false) // unchanged — answer hasn't arrived yet
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
    }

    func test_setAudioOnly_turningVideoBackOn_whenCallStartedAsVideo_succeeds() throws {
        // The call started with video (audioOnly: false), so WebRTCClient
        // already created a video track/capturer to re-enable — turning
        // it off then back on is just toggling that existing track.
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        try manager.setAudioOnly(true) // turn video off
        try manager.setAudioOnly(false) // turn it back on

        XCTAssertEqual(manager.audioOnly, false)
        XCTAssertEqual(mediaEngine.audioOnlyCalls, [true, false])
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .modify(callId: callId, audioOnly: false) })
    }

    func test_setAudioOnly_turningVideoOn_whenCallStartedAsAudioOnly_isANoOp() throws {
        // The call started audio-only, so WebRTCClient never created a
        // video track/capturer — there is nothing to re-enable, and
        // upgrading to video would require SDP renegotiation this method
        // doesn't do. Must no-op rather than flip `audioOnly`/notify the
        // peer for a switch that wouldn't actually produce video.
        try manager.startCall(to: "them", audioOnly: true)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: true), from: "them")
        mediaEngine.simulateConnected()
        let countBefore = try sentWireMessages().count

        try manager.setAudioOnly(false)

        XCTAssertEqual(manager.audioOnly, true) // unchanged
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
        XCTAssertEqual(try sentWireMessages().count, countBefore)
    }

    func test_receivingModify_turnVideoOff_appliesLocally() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        try deliverSignal(.modify(callId: callId, audioOnly: true), from: "them")

        XCTAssertEqual(manager.audioOnly, true)
        XCTAssertEqual(mediaEngine.audioOnlyCalls, [true])
    }

    func test_receivingModify_turnVideoOn_whenCallStartedAsAudioOnly_isIgnored() throws {
        // Same gate as `setAudioOnly`, mirrored for the inbound direction:
        // a peer asking this side to turn video on for a call *this
        // device* started audio-only would hit the same nil-track no-op
        // in `WebRTCClient` — ignore it rather than flipping `audioOnly`/
        // the UI for a switch that wouldn't actually produce video.
        try manager.startCall(to: "them", audioOnly: true)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: true), from: "them")
        mediaEngine.simulateConnected()

        try deliverSignal(.modify(callId: callId, audioOnly: false), from: "them")

        XCTAssertEqual(manager.audioOnly, true) // unchanged
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
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

    private func deliverSignal(_ signal: OutgoingCallSignal, from: String, target: String = "me", manager: CallManager? = nil) throws {
        let encoded = CallSignalCodec.encode(signal)
        var wireMessage = Im_Message()
        wireMessage.messageID = Int64.random(in: 1_000_000...9_999_999)
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = target
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

    private func deliverCallStart(callId: String, audioOnly: Bool, from: String, target: String = "me", manager: CallManager? = nil) throws {
        var wireMessage = Im_Message()
        wireMessage.messageID = Int64.random(in: 1_000_000...9_999_999)
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = target
        wireMessage.conversation.line = 0
        wireMessage.content = MessageContentCodec.encode(.callRecord(callId: callId, targetId: target, audioOnly: audioOnly, status: 0, connectTime: 0, endTime: 0))
        wireMessage.serverTimestamp = 1_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = wireMessage.messageID
        result.head = wireMessage.messageID
        let body = Data([0x00]) + (try result.serializedData())
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body))
    }
}
