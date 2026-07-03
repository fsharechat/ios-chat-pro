import Foundation
import Combine
import IMClient
// 消歧义:`Scheduler` 同时存在于 IMClient 与 Combine(@Published 引入)——
// 见 `AppCore.LoginViewModel` 同款 import 的说明。
import protocol IMClient.Scheduler
import IMProto
import IMStorage
import IMMessaging

/// 一对一通话的状态机与协调入口,协议方向与 Android `AVEngineKit` 完全一致
/// (offer 由被叫发起,见设计文档 §1 的流程图):
/// - 主叫:发 CallStart(400) → `.outgoing`,只开本地预览;收到 Answer(401)
///   → `.connecting`,建连接等对方 offer。
/// - 被叫:收到 CallStart → `.incoming`;`answer()` 发 AnswerT(405)+Answer(401)
///   → `.connecting`,建连接并主动 createOffer。
///
/// **线程契约:** 与整个代码库一致,无内部锁,必须固定从主队列驱动。
public final class CallManager {
    @Published public private(set) var state: CallState = .idle
    @Published public private(set) var audioOnly: Bool = false
    public private(set) var peerUid: String?

    /// 每次通话结束(任何原因)触发 —— UI 收掉通话页。
    public var onCallEnded: ((CallEndReason) -> Void)?

    private static let answerTimeoutSeconds: TimeInterval = 60
    private static let connectingTimeoutSeconds: TimeInterval = 60
    /// Android `AVEngineKit.onReceiveCallMessage` 的 90 秒新鲜度窗口:离线
    /// 期间积压的 CallStart 在重新同步时只落库为通话记录,不再弹窗。
    private static let callStartFreshnessMillis: Int64 = 90_000

    private let messagingService: MessagingService
    private let storage: IMStorage
    private let mediaEngine: MediaEngine
    private let scheduler: Scheduler
    private let myUserId: () -> String
    private let nowMillis: () -> Int64

    private var session: CallSession?
    private var answerTimeoutToken: SchedulerToken?
    private var connectingTimeoutToken: SchedulerToken?

    public init(
        messagingService: MessagingService,
        storage: IMStorage,
        mediaEngine: MediaEngine,
        scheduler: Scheduler = DispatchQueueScheduler(),
        myUserId: @escaping () -> String,
        nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.messagingService = messagingService
        self.storage = storage
        self.mediaEngine = mediaEngine
        self.scheduler = scheduler
        self.myUserId = myUserId
        self.nowMillis = nowMillis

        mediaEngine.onConnected = { [weak self] in self?.handleMediaConnected() }
        mediaEngine.onDisconnected = { [weak self] in self?.handleMediaDisconnected() }
        mediaEngine.onLocalCandidate = { [weak self] index, mid, candidate in
            self?.handleLocalCandidate(sdpMLineIndex: index, sdpMid: mid, candidate: candidate)
        }
        messagingService.onCallSignal = { [weak self] wireMessage in self?.handleIncomingSignal(wireMessage) }
        messagingService.onCallStartMessage = { [weak self] message in self?.handleIncomingCallStart(message) }
    }

    // MARK: - 主叫

    public func startCall(to peerUid: String, audioOnly: Bool) throws {
        guard state == .idle else { return }
        let callId = UUID().uuidString

        // 先排应答超时再发 CallStart:sendCallStart 会经 MessagingService 注册
        // 自己的 5s ack 超时到同一个 scheduler,先排 60s 让它保持最老的 pending
        // 条目,ManualScheduler.fireNext() 驱动的测试依赖这一点;session 尚为
        // nil 时 timeoutFired() 是 no-op,安全。
        startAnswerTimeoutTimer()
        let stored = try messagingService.sendCallStart(targetId: peerUid, callId: callId, audioOnly: audioOnly)

        session = CallSession(callId: callId, peerUid: peerUid, audioOnly: audioOnly, localMessageRowId: stored.id)
        self.audioOnly = audioOnly
        self.peerUid = peerUid
        state = .outgoing
        // Android 协议:主叫此刻只开本地预览(摄像头画面立即可见),
        // PeerConnection 等收到 Answer 再建,offer 由被叫发起。
        mediaEngine.startPreview(audioOnly: audioOnly)
    }

    // MARK: - 被叫

    public func answer() throws {
        guard state == .incoming, let session else { return }
        answerTimeoutToken?.cancel()
        // Android answerCall 的发送顺序:AnswerT(405,透传给自己其他端)
        // 先行,Answer(401,发给对方)随后。
        try sendSignal(.answerT(callId: session.callId, audioOnly: session.audioOnly), to: session.peerUid)
        try sendSignal(.answer(callId: session.callId, audioOnly: session.audioOnly), to: session.peerUid)
        state = .connecting
        startConnectingTimeoutTimer()

        mediaEngine.startPreview(audioOnly: session.audioOnly)
        mediaEngine.connect()
        // 被叫是 WebRTC initiator(Android startMedia(true))—— offer 从这边发。
        let answeringCallId = session.callId
        mediaEngine.createOffer { [weak self] sdp in
            guard let self, let current = self.session, current.callId == answeringCallId else { return }
            try? self.sendSignal(.sdpOffer(callId: current.callId, sdp: sdp), to: current.peerUid)
        }
    }

    public func reject() throws { try hangUp(reason: .localHangup) }
    public func hangUp() throws { try hangUp(reason: .localHangup) }

    private func hangUp(reason: CallEndReason) throws {
        guard let session else { return }
        try sendSignal(.bye(callId: session.callId), to: session.peerUid)
        endSession(reason: reason)
    }

    // MARK: - 通话中切换

    /// 视频通话中关掉视频永远可行(禁用已有本地轨);重新打开仅当这通电话
    /// 本来就是视频通话(`!session.audioOnly`,该字段记录通话原始模式,不被
    /// 本方法改写)—— 音频通话升级视频需要 SDP 重协商,不在本期范围,静默
    /// no-op 而不是误发 Modify。
    public func setAudioOnly(_ audioOnly: Bool) throws {
        guard let session, state == .connecting || state == .connected else { return }
        guard audioOnly || !session.audioOnly else { return }
        try sendSignal(.modify(callId: session.callId, audioOnly: audioOnly), to: session.peerUid)
        self.audioOnly = audioOnly
        mediaEngine.setAudioOnly(audioOnly)
    }

    // MARK: - 来电信令分发(401-405 via MessagingService.onCallSignal)

    private func handleIncomingSignal(_ wireMessage: Im_Message) {
        guard let signal = CallSignalCodec.decode(wireMessage) else { return }
        guard let session else { return }
        let sender = wireMessage.fromUser

        // 自己账号的其他设备接听了(401/405 经服务器同步回来)—— 本端还在
        // 响铃就静默收场,不发 Bye(Android AcceptByOtherClient)。
        if sender == myUserId() {
            if case .answer(let callId, _) = signal, state == .incoming, callId == session.callId {
                endSession(reason: .acceptedElsewhere)
            }
            return
        }

        guard signalCallId(signal) == session.callId, sender == session.peerUid else {
            // 与当前通话无关的信令 —— 对方在别的通话里找我,回 Bye 拒掉
            // (Android rejectOtherCall);无关的 Bye 本身不用回应。
            if case .bye = signal { return }
            try? sendSignal(.bye(callId: signalCallId(signal)), to: sender)
            return
        }

        switch signal {
        case .answer(_, let peerAudioOnly):
            guard state == .outgoing else { return }
            answerTimeoutToken?.cancel()
            if peerAudioOnly, !audioOnly {
                // 被叫把视频来电按语音接听(Android answerCall 的 audioOnly
                // 降级)—— 主叫侧跟着关掉本地视频。
                audioOnly = true
                mediaEngine.setAudioOnly(true)
            }
            state = .connecting
            startConnectingTimeoutTimer()
            mediaEngine.connect() // 主叫非 initiator:等对方 offer

        case .bye:
            endSession(reason: .remoteBye)

        case .sdpOffer(let offerCallId, let sdp):
            // Android 仅在 Connecting/Connected 处理 Signal —— 早到的 offer
            //(理论上只可能来自旧协议对端)丢弃。
            guard state == .connecting || state == .connected else { return }
            mediaEngine.createAnswer(forRemoteOffer: sdp) { [weak self] answerSDP in
                guard let self, let current = self.session, current.callId == offerCallId else { return }
                try? self.sendSignal(.sdpAnswer(callId: current.callId, sdp: answerSDP), to: current.peerUid)
            }

        case .sdpAnswer(_, let sdp):
            guard state == .connecting || state == .connected else { return }
            mediaEngine.setRemoteAnswer(sdp)

        case .iceCandidate(_, let index, let mid, let candidate):
            guard state == .connecting || state == .connected else { return }
            mediaEngine.addRemoteCandidate(sdpMLineIndex: index, sdpMid: mid, candidate: candidate)

        case .removeCandidates(_, let candidates):
            guard state == .connecting || state == .connected else { return }
            mediaEngine.removeRemoteCandidates(candidates)

        case .modify(_, let newAudioOnly):
            // 与 setAudioOnly 相同的门:这台设备以纯音频开局的通话没有可
            // 再启用的视频轨,对方请求打开视频只能忽略。
            guard newAudioOnly || !session.audioOnly else { return }
            audioOnly = newAudioOnly
            mediaEngine.setAudioOnly(newAudioOnly)
        }
    }

    private func signalCallId(_ signal: IncomingCallSignal) -> String {
        switch signal {
        case .answer(let callId, _), .bye(let callId), .sdpOffer(let callId, _), .sdpAnswer(let callId, _),
             .iceCandidate(let callId, _, _, _), .removeCandidates(let callId, _), .modify(let callId, _):
            return callId
        }
    }

    // MARK: - 来电 CallStart

    private func handleIncomingCallStart(_ message: StoredMessage) {
        guard case .callRecord(let callId, _, let audioOnlyFlag, _, _, _) = message.content else { return }
        // 90 秒新鲜度窗口(Android 同款):过期的 CallStart 只作为通话记录
        // 气泡存在(ReceiveMessageHandler 已落库),绝不能事后弹铃。
        guard nowMillis() - message.timestamp < Self.callStartFreshnessMillis else { return }
        let callerUid = message.from

        if state == .outgoing, let session, session.peerUid == callerUid {
            // glare:双方同一瞬间互拨 —— uid 小的一方的去电胜出。
            if myUserId() < callerUid {
                try? sendSignal(.bye(callId: callId), to: callerUid)
                return
            } else {
                answerTimeoutToken?.cancel()
                updateCallBubble(status: 2, endTime: nowMillis())
                mediaEngine.close() // 撤掉被弃去电已开的本地预览
                acceptIncomingCall(callId: callId, callerUid: callerUid, audioOnly: audioOnlyFlag, localMessageRowId: message.id)
                return
            }
        }

        guard state == .idle else {
            try? sendSignal(.bye(callId: callId), to: callerUid) // 忙线自动拒接
            return
        }

        acceptIncomingCall(callId: callId, callerUid: callerUid, audioOnly: audioOnlyFlag, localMessageRowId: message.id)
    }

    private func acceptIncomingCall(callId: String, callerUid: String, audioOnly: Bool, localMessageRowId: Int64?) {
        session = CallSession(callId: callId, peerUid: callerUid, audioOnly: audioOnly, localMessageRowId: localMessageRowId)
        self.audioOnly = audioOnly
        peerUid = callerUid
        state = .incoming // UI(SceneDelegate)监听 $state 弹出来电页
        startAnswerTimeoutTimer()
    }

    // MARK: - MediaEngine 回调

    private func handleMediaConnected() {
        guard state == .connecting else { return }
        connectingTimeoutToken?.cancel()
        state = .connected
        session?.connectTime = nowMillis()
        updateCallBubble(status: 1, endTime: 0)
    }

    private func handleMediaDisconnected() {
        guard state == .connected || state == .connecting else { return }
        try? hangUp(reason: .mediaFailure)
    }

    private func handleLocalCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String) {
        guard let session else { return }
        try? sendSignal(.iceCandidate(callId: session.callId, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid, candidate: candidate), to: session.peerUid)
    }

    // MARK: - 计时器

    private func startAnswerTimeoutTimer() {
        answerTimeoutToken = scheduler.scheduleOnce(after: Self.answerTimeoutSeconds) { [weak self] in self?.timeoutFired() }
    }

    private func startConnectingTimeoutTimer() {
        connectingTimeoutToken = scheduler.scheduleOnce(after: Self.connectingTimeoutSeconds) { [weak self] in self?.timeoutFired() }
    }

    private func timeoutFired() {
        guard session != nil else { return }
        try? hangUp(reason: .timeout)
    }

    // MARK: - 收场

    private func endSession(reason: CallEndReason) {
        answerTimeoutToken?.cancel()
        connectingTimeoutToken?.cancel()
        updateCallBubble(status: 2, endTime: nowMillis())
        mediaEngine.close()
        session = nil
        state = .idle
        peerUid = nil
        onCallEnded?(reason)
    }

    private func updateCallBubble(status: Int, endTime: Int64) {
        guard let session, let rowId = session.localMessageRowId else { return }
        let content = MessageContent.callRecord(
            callId: session.callId,
            targetId: session.peerUid,
            audioOnly: session.audioOnly,
            status: status,
            connectTime: session.connectTime,
            endTime: endTime
        )
        try? storage.messages.updateContent(id: rowId, content: content)
    }

    private func sendSignal(_ signal: OutgoingCallSignal, to peerUid: String) throws {
        let encoded = CallSignalCodec.encode(signal)
        try messagingService.sendCallControlMessage(to: peerUid, wireType: encoded.wireType, callId: encoded.callId, dataPayload: encoded.data)
    }
}
