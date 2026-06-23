import Foundation
import Combine
import IMClient
// Disambiguates `Scheduler` from `Combine.Scheduler` (also in scope, for
// `@Published`) — see `AppCore.LoginViewModel`'s identical import for why
// plain `IMClient.Scheduler` doesn't work here.
import protocol IMClient.Scheduler
import IMProto
import IMStorage
import IMMessaging

/// The single state-machine + coordination entry point for one-to-one
/// calling — see the Phase 3 design doc §3. Owns at most one `CallSession`
/// at a time. UI (`IMKit`) drives it through `startCall`/`answer`/
/// `reject`/`hangUp`; `WebRTCClient` (a later task) drives it through
/// `MediaEngine`'s callbacks; `ReceiveMessageHandler` (via
/// `MessagingService`'s forwarding properties) drives it through incoming
/// call signals.
///
/// **Threading contract:** like the rest of this codebase, no internal
/// locking — must be driven from a single consistent queue (by convention
/// main), matching `IMClient`'s own threading contract.
public final class CallManager {
    @Published public private(set) var state: CallState = .idle
    @Published public private(set) var audioOnly: Bool = false
    public private(set) var peerUid: String?

    /// Fired when an incoming CallStart arrives and is accepted into
    /// `.incoming` state (i.e. not auto-rejected as busy, see the next
    /// task) — the App-target `CXProvider` adapter wires this to
    /// `reportNewIncomingCall`.
    public var onIncomingCall: ((_ peerUid: String, _ audioOnly: Bool) -> Void)?
    /// Fired every time a call ends, for any reason — UI dismisses the
    /// call screen, CallKit adapter reports the end.
    public var onCallEnded: ((CallEndReason) -> Void)?

    private static let answerTimeoutSeconds: TimeInterval = 60
    private static let connectingTimeoutSeconds: TimeInterval = 60

    private let messagingService: MessagingService
    private let storage: IMStorage
    private let mediaEngine: MediaEngine
    private let scheduler: Scheduler
    private let myUserId: () -> String
    private let nowMillis: () -> Int64

    private var session: CallSession?
    private var pendingRemoteOfferSDP: String?
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
        // `messagingService.onCallStartMessage = ...` is wired in the next
        // task, alongside the `handleIncomingCallStart` method it drives —
        // there is nothing in this task's scope for it to call yet.
    }

    // MARK: - Outgoing

    public func startCall(to peerUid: String, audioOnly: Bool) throws {
        guard state == .idle else { return }
        let callId = UUID().uuidString

        // Scheduled before `sendCallStart` deliberately: `sendCallStart`
        // sends a wire frame through `MessagingService`, which registers
        // its own 5s ack-timeout with the same `scheduler` — starting the
        // 60s answer-timeout first keeps it the oldest-pending entry, which
        // is what `ManualScheduler.fireNext()`-driven tests rely on. Safe
        // because `timeoutFired()` no-ops while `session` is still `nil`.
        startAnswerTimeoutTimer()
        let stored = try messagingService.sendCallStart(targetId: peerUid, callId: callId, audioOnly: audioOnly)

        session = CallSession(callId: callId, peerUid: peerUid, audioOnly: audioOnly, localMessageRowId: stored.id)
        self.audioOnly = audioOnly
        self.peerUid = peerUid
        state = .outgoing

        mediaEngine.start(audioOnly: audioOnly)
        mediaEngine.createOffer { [weak self] sdp in
            guard let self, let session = self.session, session.callId == callId else { return }
            try? self.sendSignal(.sdpOffer(callId: session.callId, sdp: sdp), to: session.peerUid)
        }
    }

    // MARK: - Incoming

    public func answer() throws {
        guard state == .incoming, let session else { return }
        answerTimeoutToken?.cancel()
        try sendSignal(.answer(callId: session.callId, audioOnly: session.audioOnly), to: session.peerUid)
        mediaEngine.start(audioOnly: session.audioOnly)
        state = .connecting
        startConnectingTimeoutTimer()

        if let offerSDP = pendingRemoteOfferSDP {
            pendingRemoteOfferSDP = nil
            let answeringCallId = session.callId
            mediaEngine.createAnswer(forRemoteOffer: offerSDP) { [weak self] answerSDP in
                guard let self, let session = self.session, session.callId == answeringCallId else { return }
                try? self.sendSignal(.sdpAnswer(callId: session.callId, sdp: answerSDP), to: session.peerUid)
            }
        }
    }

    public func reject() throws { try hangUp(reason: .localHangup) }
    public func hangUp() throws { try hangUp(reason: .localHangup) }

    private func hangUp(reason: CallEndReason) throws {
        guard let session else { return }
        try sendSignal(.bye(callId: session.callId), to: session.peerUid)
        endSession(reason: reason)
    }

    // MARK: - Incoming signal dispatch (401-404 via `MessagingService.onCallSignal`)

    private func handleIncomingSignal(_ wireMessage: Im_Message) {
        guard let signal = CallSignalCodec.decode(wireMessage), matchesCurrentCall(signal) else { return }
        switch signal {
        case .answer:
            guard state == .outgoing else { return }
            state = .connecting
            startConnectingTimeoutTimer()
        case .bye:
            endSession(reason: .remoteBye)
        case .sdpOffer(let offerCallId, let sdp):
            if state == .connecting {
                mediaEngine.createAnswer(forRemoteOffer: sdp) { [weak self] answerSDP in
                    guard let self, let session = self.session, session.callId == offerCallId else { return }
                    try? self.sendSignal(.sdpAnswer(callId: session.callId, sdp: answerSDP), to: session.peerUid)
                }
            } else {
                pendingRemoteOfferSDP = sdp
            }
        case .sdpAnswer(_, let sdp):
            mediaEngine.setRemoteAnswer(sdp)
        case .iceCandidate(_, let index, let mid, let candidate):
            mediaEngine.addRemoteCandidate(sdpMLineIndex: index, sdpMid: mid, candidate: candidate)
        case .modify(_, let newAudioOnly):
            self.audioOnly = newAudioOnly
            mediaEngine.setAudioOnly(newAudioOnly)
        }
    }

    private func matchesCurrentCall(_ signal: IncomingCallSignal) -> Bool {
        guard let session else { return false }
        switch signal {
        case .answer(let callId, _), .bye(let callId), .sdpOffer(let callId, _), .sdpAnswer(let callId, _), .iceCandidate(let callId, _, _, _), .modify(let callId, _):
            return callId == session.callId
        }
    }

    // MARK: - MediaEngine callbacks

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

    // MARK: - Timers

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

    // MARK: - Ending a call

    private func endSession(reason: CallEndReason) {
        answerTimeoutToken?.cancel()
        connectingTimeoutToken?.cancel()
        updateCallBubble(status: 2, endTime: nowMillis())
        mediaEngine.close()
        session = nil
        pendingRemoteOfferSDP = nil
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
