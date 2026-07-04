import XCTest
import Foundation
import Combine
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
    /// 注入给 CallManager 的"当前时间"(毫秒)。deliverCallStart 默认
    /// serverTimestamp=99_000,距 now 1 秒 → 新鲜;新鲜度用例单独调大 now。
    private var now: Int64 = 100_000

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
        manager = makeManager()
    }

    private func makeManager(myUserId: String = "me") -> CallManager {
        CallManager(
            messagingService: messagingService,
            storage: storage,
            mediaEngine: mediaEngine,
            scheduler: scheduler,
            myUserId: { myUserId },
            nowMillis: { [unowned self] in self.now }
        )
    }

    // MARK: - 主叫

    func test_startCall_transitionsToOutgoingAndSendsCallStart() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertEqual(manager.state, .outgoing)
        XCTAssertEqual(manager.peerUid, "them")
        let messages = try sentWireMessages()
        XCTAssertEqual(messages.first?.content.type, 400)
    }

    func test_startCall_onlyStartsPreview_noConnectionNoOffer() throws {
        // Android 协议:offer 由被叫在接听后发起,主叫此时只开本地预览。
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertEqual(mediaEngine.startPreviewCalls, [false])
        XCTAssertEqual(mediaEngine.connectCallCount, 0)
        XCTAssertEqual(mediaEngine.createOfferCallCount, 0)
        XCTAssertFalse(try sentWireMessages().contains { $0.content.type == 403 })
    }

    func test_startCall_whenNotIdle_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let countBefore = try sentWireMessages().count

        try manager.startCall(to: "someone-else", audioOnly: false)

        XCTAssertEqual(manager.peerUid, "them") // 不变
        XCTAssertEqual(try sentWireMessages().count, countBefore)
    }

    func test_receivingAnswer_transitionsToConnecting_andConnectsAsNonInitiator() throws {
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")

        XCTAssertEqual(manager.state, .connecting)
        XCTAssertEqual(mediaEngine.connectCallCount, 1)
        XCTAssertEqual(mediaEngine.createOfferCallCount, 0) // 主叫等对方 offer
    }

    func test_receivingAnswerWithAudioOnly_downgradesVideoCallToAudio() throws {
        // Android answerCall 可以把视频来电按语音接听 —— 主叫侧要跟着降级。
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: true), from: "them")

        XCTAssertEqual(manager.audioOnly, true)
        XCTAssertEqual(mediaEngine.audioOnlyCalls, [true])
    }

    func test_callerReceivingOfferWhileConnecting_createsAndSendsAnswerSDP() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them")

        try deliverSignal(.sdpOffer(callId: callId, sdp: "their-offer"), from: "them")

        XCTAssertEqual(mediaEngine.createAnswerCalls, ["their-offer"])
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .sdpAnswer(callId: callId, sdp: mediaEngine.answerSDPToReturn) })
    }

    func test_offerArrivingWhileStillOutgoing_isIgnored() throws {
        // 新协议下 offer 不会先于 Answer 到达;若出现(旧版本 iOS 对端),丢弃。
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.sdpOffer(callId: callIdFromLastCallStart(), sdp: "early-offer"), from: "them")

        XCTAssertTrue(mediaEngine.createAnswerCalls.isEmpty)
    }

    // MARK: - 接通/挂断

    func test_mediaEngineConnected_transitionsToConnectedAndUpdatesBubble() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")

        mediaEngine.simulateConnected()

        XCTAssertEqual(manager.state, .connected)
        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, let connectTime, _) = bubble?.content {
            XCTAssertEqual(status, 1)
            XCTAssertEqual(connectTime, now)
        } else {
            XCTFail("通话气泡应仍是 callRecord")
        }
    }

    func test_hangUp_sendsByeAndReturnsToIdle() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()

        try manager.hangUp()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.peerUid)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: callId) })
        XCTAssertEqual(mediaEngine.closeCallCount, 1)
    }

    func test_hangUp_updatesBubbleToEndedStatus() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        mediaEngine.simulateConnected()

        try manager.hangUp()

        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, let connectTime, let endTime) = bubble?.content {
            XCTAssertEqual(status, 2)
            XCTAssertEqual(connectTime, now) // 接通时间不能被挂断时丢掉
            XCTAssertEqual(endTime, now)
        } else {
            XCTFail("通话气泡应仍是 callRecord")
        }
    }

    func test_hangUp_whenIdle_isANoOp() throws {
        XCTAssertNoThrow(try manager.hangUp())
        XCTAssertEqual(manager.state, .idle)
    }

    func test_receivingBye_endsCallAndUpdatesBubble() throws {
        try manager.startCall(to: "them", audioOnly: false)
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }

        try deliverSignal(.bye(callId: callIdFromLastCallStart()), from: "them")

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .remoteBye)
        let bubble = try storage.messages.messages(conversationType: .single, target: "them").first
        if case .callRecord(_, _, _, let status, _, _) = bubble?.content {
            XCTAssertEqual(status, 2)
        } else {
            XCTFail("通话气泡应仍是 callRecord")
        }
    }

    // MARK: - 超时

    func test_answerTimeout_60Seconds_endsCallAsTimeoutAndSendsBye() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }

        scheduler.fireNext() // 60s 应答超时

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .timeout)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: callId) })
    }

    func test_connectingTimeout_60SecondsAfterAnswer_endsCallAsTimeout() throws {
        try manager.startCall(to: "them", audioOnly: false)
        // CallStart(400)本身走 `sendWireMessage`/`OutgoingMessageTracker`,
        // 自带一个独立的 5s 送达超时(与 CallManager 的应答/连接超时无关,
        // 但共享同一个 scheduler)。生产环境里服务器的 PUB_ACK 会在毫秒级
        // 到达并早早解除它;这里显式模拟一次,让它不再赖在 pending 队列里
        // 抢在真正要测的 60s 连接超时之前被 `fireNext()` 误触发。
        try ackCallStartSend()
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }

        scheduler.fireNext() // 60s 连接超时(应答超时已在收到 Answer 时取消)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .timeout)
    }

    // MARK: - 信令转发到 MediaEngine

    func test_receivingSdpAnswer_whileConnecting_forwardsToMediaEngine() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()

        try deliverSignal(.sdpAnswer(callId: "call-1", sdp: "remote-answer-sdp"), from: "them")

        XCTAssertEqual(mediaEngine.remoteAnswers, ["remote-answer-sdp"])
    }

    func test_receivingIceCandidate_whileConnecting_forwardsToMediaEngine() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()

        try deliverSignal(.iceCandidate(callId: "call-1", sdpMLineIndex: 1, sdpMid: "video", candidate: "candidate:9..."), from: "them")

        XCTAssertEqual(mediaEngine.remoteCandidates.count, 1)
        XCTAssertEqual(mediaEngine.remoteCandidates.first?.1, "video")
    }

    func test_receivingIceCandidate_whileOutgoing_isIgnored() throws {
        // Android 仅在 Connecting/Connected 处理 Signal —— 对齐。
        try manager.startCall(to: "them", audioOnly: false)

        try deliverSignal(.iceCandidate(callId: callIdFromLastCallStart(), sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1..."), from: "them")

        XCTAssertTrue(mediaEngine.remoteCandidates.isEmpty)
    }

    func test_receivingRemoveCandidates_whileConnecting_forwardsToMediaEngine() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()
        let candidates = [RemoteIceCandidate(sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1")]

        try deliverSignal(.removeCandidates(callId: "call-1", candidates: candidates), from: "them")

        XCTAssertEqual(mediaEngine.removedCandidateBatches, [candidates])
    }

    func test_mediaEngineLocalCandidate_sentAsSignal403() throws {
        try manager.startCall(to: "them", audioOnly: false)

        mediaEngine.simulateLocalCandidate()

        let signalMessages = try sentWireMessages().filter { $0.content.type == 403 }
        XCTAssertTrue(signalMessages.contains { CallSignalCodec.decode($0) == .iceCandidate(callId: callIdFromLastCallStart(), sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1...") })
    }

    func test_mediaEngineDisconnectedAfterConnected_endsCallAsMediaFailure() throws {
        try manager.startCall(to: "them", audioOnly: false)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: false), from: "them")
        mediaEngine.simulateConnected()
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }

        mediaEngine.simulateDisconnected()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .mediaFailure)
    }

    // MARK: - 被叫

    func test_receivingCallStartWhileIdle_transitionsToIncoming() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: true, from: "them")

        XCTAssertEqual(manager.state, .incoming)
        XCTAssertEqual(manager.peerUid, "them")
        XCTAssertEqual(manager.audioOnly, true)
        XCTAssertTrue(scheduler.scheduledDelays.contains(60)) // 应答超时已启动
        XCTAssertTrue(mediaEngine.startPreviewCalls.isEmpty) // 接听前不开摄像头
    }

    func test_staleCallStart_olderThan90Seconds_doesNotRing() throws {
        // 离线期间积压的 CallStart 重新同步时只落库,不能弹一个早就结束的来电。
        try deliverCallStart(callId: "stale-call", audioOnly: false, from: "them", serverTimestamp: 5_000) // 95 秒前

        XCTAssertEqual(manager.state, .idle)
        // 气泡照常落库(由 ReceiveMessageHandler 负责,与弹不弹窗无关)
        XCTAssertFalse(try storage.messages.messages(conversationType: .single, target: "them").isEmpty)
    }

    func test_answer_sendsAnswerTAndAnswer_connectsAsInitiator_andSendsOffer() throws {
        try deliverCallStart(callId: "call-incoming-1", audioOnly: false, from: "them")

        try manager.answer()

        XCTAssertEqual(manager.state, .connecting)
        XCTAssertEqual(mediaEngine.startPreviewCalls, [false])
        XCTAssertEqual(mediaEngine.connectCallCount, 1)
        XCTAssertEqual(mediaEngine.createOfferCallCount, 1) // 被叫是 initiator
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { $0.content.type == 405 }) // AnswerT 先行
        XCTAssertTrue(messages.contains { $0.content.type == 401 })
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .sdpOffer(callId: "call-incoming-1", sdp: mediaEngine.offerSDPToReturn) })
    }

    func test_answer_whenNotIncoming_isANoOp() throws {
        XCTAssertNoThrow(try manager.answer())
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(mediaEngine.startPreviewCalls.isEmpty)
    }

    func test_secondCallStartWhileBusy_autoRejectsWithBye() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()

        try deliverCallStart(callId: "call-2", audioOnly: false, from: "someone-else")

        XCTAssertEqual(manager.state, .connecting) // 原通话不受影响
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "call-2") })
    }

    // MARK: - 多端与无关信令

    func test_ownAnswerFromOtherDevice_whileIncoming_endsAsAcceptedElsewhere_withoutBye() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        var endReason: CallEndReason?
        manager.onCallEnded = { endReason = $0 }
        let countBefore = try sentWireMessages().count

        try deliverSignal(.answer(callId: "call-1", audioOnly: false), from: "me")

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(endReason, .acceptedElsewhere)
        XCTAssertEqual(try sentWireMessages().count, countBefore) // 没发 Bye
    }

    func test_signalForUnrelatedCallId_isRejectedWithBye() throws {
        // Android rejectOtherCall:与当前通话无关的来电信令直接回 Bye。
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")

        try deliverSignal(.answer(callId: "other-call", audioOnly: false), from: "someone-else")

        XCTAssertEqual(manager.state, .incoming) // 当前来电不受影响
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "other-call") })
    }

    // MARK: - glare(双方同时拨打)

    func test_glare_myUidSmaller_myOutgoingCallContinues_rejectsTheirs() throws {
        // "me" < "them",按字典序我赢 —— 我的去电继续,拒掉对方的。
        try manager.startCall(to: "them", audioOnly: false)

        try deliverCallStart(callId: "their-call-id", audioOnly: false, from: "them")

        XCTAssertEqual(manager.state, .outgoing)
        let messages = try sentWireMessages()
        XCTAssertTrue(messages.contains { CallSignalCodec.decode($0) == .bye(callId: "their-call-id") })
    }

    func test_glare_myUidLarger_abandonsMyOutgoingAndAcceptsTheirs() throws {
        // "me" > "a",我输 —— 放弃自己的去电,把对方来电转入 incoming。
        let losingManager = makeManager()
        try losingManager.startCall(to: "a", audioOnly: false)

        try deliverCallStart(callId: "their-call-id", audioOnly: true, from: "a")

        XCTAssertEqual(losingManager.state, .incoming)
        XCTAssertEqual(losingManager.peerUid, "a")
        XCTAssertGreaterThanOrEqual(mediaEngine.closeCallCount, 1) // 被弃去电的预览已撤

        // `messages(...)` 按 timestamp DESC 排序;被弃去电的气泡走的是
        // `messagingService` 的真实系统时钟(远大于本文件注入的假 `now`),
        // 而 `deliverCallStart` 的 serverTimestamp 固定为较小的测试值 ——
        // 所以"最新"(.first)才是被弃去电的气泡,而不是 .last。
        let abandonedBubble = try storage.messages.messages(conversationType: .single, target: "a").first
        if case .callRecord(_, _, _, let status, let connectTime, _) = abandonedBubble?.content {
            XCTAssertEqual(status, 2) // 被弃去电的气泡已收场
            XCTAssertEqual(connectTime, 0)
        } else {
            XCTFail("被弃去电的气泡应仍是 callRecord")
        }
    }

    // MARK: - 音视频切换

    func test_setAudioOnly_whileConnected_sendsModifyAndUpdatesEngine() throws {
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

    func test_setAudioOnly_whileOutgoing_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: false)

        XCTAssertNoThrow(try manager.setAudioOnly(true))

        XCTAssertEqual(manager.audioOnly, false)
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
    }

    /// Android 仅在 Connected 处理/发送 Modify —— connecting 阶段两端
    /// PeerConnection 还没建好,提前切 audioOnly 会让两端最终协商出的
    /// audioOnly 状态分叉。之前 iOS 在 connecting 也放行会发 Modify,
    /// 现收紧为仅 `.connected`。
    func test_setAudioOnly_whileConnecting_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them") // → .connecting,尚未 simulateConnected
        let countBefore = try sentWireMessages().count

        XCTAssertNoThrow(try manager.setAudioOnly(true))

        XCTAssertEqual(manager.audioOnly, false) // 不变
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
        XCTAssertEqual(try sentWireMessages().count, countBefore) // 没发 Modify
    }

    func test_setAudioOnly_turningVideoOn_whenCallStartedAsAudioOnly_isANoOp() throws {
        try manager.startCall(to: "them", audioOnly: true)
        try deliverSignal(.answer(callId: callIdFromLastCallStart(), audioOnly: true), from: "them")
        mediaEngine.simulateConnected()
        let countBefore = try sentWireMessages().count

        try manager.setAudioOnly(false)

        XCTAssertEqual(manager.audioOnly, true) // 音频通话没有可再启用的视频轨
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
        try manager.startCall(to: "them", audioOnly: true)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: true), from: "them")
        mediaEngine.simulateConnected()

        try deliverSignal(.modify(callId: callId, audioOnly: false), from: "them")

        XCTAssertEqual(manager.audioOnly, true) // 不变
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
    }

    /// 入站 Modify 同样仅在 `.connected` 处理 —— 对齐 Android。
    func test_receivingModify_whileConnecting_isIgnored() throws {
        try manager.startCall(to: "them", audioOnly: false)
        let callId = callIdFromLastCallStart()
        try deliverSignal(.answer(callId: callId, audioOnly: false), from: "them") // → .connecting,尚未 simulateConnected

        try deliverSignal(.modify(callId: callId, audioOnly: true), from: "them")

        XCTAssertEqual(manager.audioOnly, false) // 不变
        XCTAssertTrue(mediaEngine.audioOnlyCalls.isEmpty)
    }

    // MARK: - Helpers

    private func sentWireMessages() throws -> [Im_Message] {
        // `try?`(而非 `try`)解码:sentFrames 里还混着 IMClient 自己发的
        // 非 Im_Message 帧(CONNECT 握手 JSON、心跳 PING),那些不是合法
        // protobuf,跳过即可,不能让整个扫描失败。
        fakeTransport.sentFrames.compactMap { data in
            FrameDecoder().feed(data).first.flatMap { try? Im_Message(serializedBytes: $0.body) }
        }
    }

    private func callIdFromLastCallStart() -> String {
        guard let message = try? sentWireMessages().first(where: { $0.content.type == 400 }),
              case .callRecord(let callId, _, _, _, _, _) = try! MessageContentCodec.decode(message.content) else {
            XCTFail("应已发送 CallStart")
            return ""
        }
        return callId
    }

    /// 显式解除最近一次已发送 CallStart(400)的 `OutgoingMessageTracker` 5s
    /// 送达超时 —— 见调用点的注释。`fakeTransport`/`FrameDecoder` 只暴露原始
    /// 帧,这里重新解出对应 `Frame.header.messageId` 才能拼出匹配的
    /// PUB_ACK/MS 响应帧。
    private func ackCallStartSend() throws {
        guard let frame = fakeTransport.sentFrames.compactMap({ FrameDecoder().feed($0).first })
            .first(where: { (try? Im_Message(serializedBytes: $0.body))?.content.type == 400 })
        else {
            XCTFail("应已发送 CallStart")
            return
        }
        let ackBody = Data([0x00]) + Data(repeating: 0, count: 16) // messageUid=0, timestamp=0:CallManager 不关心这两个字段
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .ms, messageId: frame.header.messageId, body: ackBody))
    }

    /// 回归:信令经服务器可能重复投递,且对端(Android Plan B)收到重复
    /// offer 会重协商并发出第二个 answer —— Unified Plan 在 stable 状态
    /// 重复应用 answer 会报 "Called in wrong state: stable",一通电话只能
    /// 认第一个 answer。
    func test_secondRemoteAnswer_isIgnored() throws {
        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")
        try manager.answer()

        try deliverSignal(.sdpAnswer(callId: "call-1", sdp: "answer-1"), from: "them")
        try deliverSignal(.sdpAnswer(callId: "call-1", sdp: "answer-2"), from: "them")

        XCTAssertEqual(mediaEngine.remoteAnswers, ["answer-1"])
    }

    // MARK: - 状态发布时序

    /// 回归:SceneDelegate 在 state sink 里同步 present 来电页,
    /// CallViewController 随即订阅同一 publisher —— 订阅发生在本次发射的
    /// 派发过程中,必须回放到已更新的新状态。@Published 在 willSet 发射
    /// (属性存储仍是旧值),这个时机的新订阅者会回放到 .idle 且错过本次
    /// .incoming,来电页因此永远显示不出接听按钮。
    func test_statePublisher_subscriberAttachedDuringIncomingEmission_replaysIncoming() throws {
        let manager = self.manager!
        var cancellables = Set<AnyCancellable>()
        var lateSubscriberFirstValue: CallState?
        var propertyValueDuringEmission: CallState?
        manager.statePublisher
            .sink { state in
                guard state == .incoming, lateSubscriberFirstValue == nil else { return }
                propertyValueDuringEmission = manager.state
                manager.statePublisher
                    .sink { if lateSubscriberFirstValue == nil { lateSubscriberFirstValue = $0 } }
                    .store(in: &cancellables)
            }
            .store(in: &cancellables)

        try deliverCallStart(callId: "call-1", audioOnly: false, from: "them")

        XCTAssertEqual(propertyValueDuringEmission, .incoming, "发射派发中读属性必须已是新值(didSet 语义)")
        XCTAssertEqual(lateSubscriberFirstValue, .incoming, "发射派发中的新订阅者必须回放新状态")
    }

    /// audioOnly 与 state 同机制 —— CallViewController 的 audioOnly 绑定
    /// 同样是在 state sink 触发的 present 流程里建立的。
    func test_audioOnlyPublisher_subscriberAttachedDuringStateEmission_replaysCurrentAudioOnly() throws {
        let manager = self.manager!
        var cancellables = Set<AnyCancellable>()
        var lateSubscriberFirstValue: Bool?
        manager.statePublisher
            .sink { state in
                guard state == .incoming, lateSubscriberFirstValue == nil else { return }
                manager.audioOnlyPublisher
                    .sink { if lateSubscriberFirstValue == nil { lateSubscriberFirstValue = $0 } }
                    .store(in: &cancellables)
            }
            .store(in: &cancellables)

        try deliverCallStart(callId: "call-1", audioOnly: true, from: "them")

        XCTAssertEqual(lateSubscriberFirstValue, true)
    }

    private func deliverSignal(_ signal: OutgoingCallSignal, from: String, target: String = "me") throws {
        let encoded = CallSignalCodec.encode(signal)
        var wireMessage = Im_Message()
        wireMessage.messageID = Int64.random(in: 1_000_000...9_999_999)
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = target
        wireMessage.conversation.line = 0
        var content = Im_MessageContent()
        content.type = encoded.wireType
        // 对齐 Android:callId 走 wire 的 content 字段。
        content.content = encoded.callId
        if let data = encoded.data { content.data = data }
        wireMessage.content = content
        wireMessage.serverTimestamp = 99_000
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = wireMessage.messageID
        result.head = wireMessage.messageID
        let body = Data([0x00]) + (try result.serializedData())
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body))
    }

    private func deliverCallStart(callId: String, audioOnly: Bool, from: String, target: String = "me", serverTimestamp: Int64 = 99_000) throws {
        var wireMessage = Im_Message()
        wireMessage.messageID = Int64.random(in: 1_000_000...9_999_999)
        wireMessage.fromUser = from
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = target
        wireMessage.conversation.line = 0
        wireMessage.content = MessageContentCodec.encode(.callRecord(callId: callId, targetId: target, audioOnly: audioOnly, status: 0, connectTime: 0, endTime: 0))
        wireMessage.serverTimestamp = serverTimestamp
        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = wireMessage.messageID
        result.head = wireMessage.messageID
        let body = Data([0x00]) + (try result.serializedData())
        fakeTransport.simulateReceivedData(FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body))
    }
}
