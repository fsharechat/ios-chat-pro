import Foundation

/// Everything `CallManager` needs from a WebRTC implementation, kept
/// narrow and protocol-shaped so `CallManagerTests` can drive the state
/// machine against `FakeMediaEngine` without linking real WebRTC. The
/// production conformer is `WebRTCClient` (a later task), built on top of
/// `stasel/WebRTC`.
public protocol MediaEngine: AnyObject {
    /// Fired whenever local ICE gathering produces a new candidate —
    /// `CallManager` wraps each one in `OutgoingCallSignal.iceCandidate`
    /// and sends it as a 403 Signal message.
    var onLocalCandidate: ((_ sdpMLineIndex: Int32, _ sdpMid: String, _ candidate: String) -> Void)? { get set }
    /// Fired once the underlying `RTCPeerConnection`'s ICE connection
    /// state first becomes connected — drives the `.connecting → .connected`
    /// transition.
    var onConnected: (() -> Void)? { get set }
    /// Fired if a connected call's ICE connection later fails/disconnects
    /// and doesn't recover — `CallManager` treats this as `.mediaFailure`
    /// (see the design doc §5's edge-case table; no ICE restart in Phase 3).
    var onDisconnected: (() -> Void)? { get set }

    func start(audioOnly: Bool)
    func createOffer(completion: @escaping (String) -> Void)
    func createAnswer(forRemoteOffer sdp: String, completion: @escaping (String) -> Void)
    func setRemoteAnswer(_ sdp: String)
    func addRemoteCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String)
    func setAudioOnly(_ audioOnly: Bool)
    func close()
}
