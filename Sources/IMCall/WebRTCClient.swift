import AVFoundation
import WebRTC

/// Plain ICE/TURN server config — defined here rather than reusing
/// `AppCore.AppConfig.IceServer` so `IMCall` doesn't depend on `AppCore`.
/// `AppCore` is the layer that will depend on `IMCall` (to construct
/// `CallManager`/`WebRTCClient` from `AppEnvironment`, see the design doc
/// §3) — a reverse dependency here would make that a cycle. The App target
/// maps `AppConfig.IceServer` values into this type at the one call site
/// that constructs a `WebRTCClient`.
public struct IceServer {
    public var urlString: String
    public var username: String
    public var credential: String

    public init(urlString: String, username: String, credential: String) {
        self.urlString = urlString
        self.username = username
        self.credential = credential
    }
}

/// The production `MediaEngine` — wraps a single `RTCPeerConnection` at a
/// time (Phase 3 is one-to-one only, see the design doc §1; group calling's
/// mesh-of-peer-connections is explicitly out of scope). One long-lived
/// instance is reused across consecutive calls (constructed once in
/// `AppEnvironment`, alongside the equally long-lived `CallManager` that
/// owns it — a later task's job): `close()` tears every property below back
/// down to `nil`, and the next call's `start(audioOnly:)` rebuilds them
/// from scratch, so there's no state to carry over between calls.
public final class WebRTCClient: NSObject, MediaEngine {
    public var onLocalCandidate: ((Int32, String, String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: (() -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let iceServers: [IceServer]
    private var peerConnection: RTCPeerConnection?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    /// Used by `CallManager.handleMediaConnected`/`handleMediaDisconnected`
    /// to fire `onConnected`/`onDisconnected` exactly once per transition,
    /// rather than on every ICE state change `RTCPeerConnectionDelegate`
    /// reports (it reports several, including transient ones).
    private var hasReportedConnected = false

    public init(iceServers: [IceServer]) {
        self.iceServers = iceServers
        super.init()
    }

    public func attachLocalRenderer(_ renderer: RTCVideoRenderer) {
        localVideoTrack?.add(renderer)
    }

    public func attachRemoteRenderer(_ renderer: RTCVideoRenderer) {
        peerConnection?.transceivers
            .compactMap { $0.receiver.track as? RTCVideoTrack }
            .first?
            .add(renderer)
    }

    public func start(audioOnly: Bool) {
        configureAudioSession()

        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: [$0.urlString], username: $0.username, credential: $0.credential)
        }
        configuration.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else { return }
        connection.delegate = self
        peerConnection = connection

        let audioTrack = Self.factory.audioTrack(withTrackId: "audio0")
        localAudioTrack = audioTrack
        connection.add(audioTrack, streamIds: ["stream0"])

        if !audioOnly {
            let videoSource = Self.factory.videoSource()
            let capturer = RTCCameraVideoCapturer(delegate: videoSource)
            videoCapturer = capturer
            let videoTrack = Self.factory.videoTrack(with: videoSource, trackId: "video0")
            localVideoTrack = videoTrack
            connection.add(videoTrack, streamIds: ["stream0"])
            startCapture(front: true)
        }
    }

    /// Without this, `setMuted`/the in-call screen's speaker toggle
    /// (`AVAudioSession.overrideOutputAudioPort`) silently no-op: that API
    /// only takes effect on a session already in `.playAndRecord` — the
    /// default category does nothing of the sort, and nothing else in this
    /// codebase configures it. `.voiceChat` mode is Apple's recommended
    /// mode for this exact case (gives WebRTC's own audio unit the routing
    /// behavior VoIP calls expect — echo cancellation, automatic
    /// receiver/speaker switching — for free).
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    /// Front camera by default — matches the chosen in-call UI (design doc
    /// §4): the small local-preview window starts on the selfie camera.
    private func startCapture(front: Bool) {
        guard let capturer = videoCapturer else { return }
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }),
              let format = RTCCameraVideoCapturer.supportedFormats(for: device).first,
              let fpsRange = format.videoSupportedFrameRateRanges.first
        else { return }
        capturer.startCapture(with: device, format: format, fps: Int(fpsRange.maxFrameRate))
    }

    public func createOffer(completion: @escaping (String) -> Void) {
        guard let connection = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection.offer(for: constraints) { sdp, _ in
            guard let sdp else { return }
            connection.setLocalDescription(sdp) { _ in
                completion(sdp.sdp)
            }
        }
    }

    public func createAnswer(forRemoteOffer sdp: String, completion: @escaping (String) -> Void) {
        guard let connection = peerConnection else { return }
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        connection.setRemoteDescription(remoteDescription) { _ in
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            connection.answer(for: constraints) { answerSDP, _ in
                guard let answerSDP else { return }
                connection.setLocalDescription(answerSDP) { _ in
                    completion(answerSDP.sdp)
                }
            }
        }
    }

    public func setRemoteAnswer(_ sdp: String) {
        let remoteDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        peerConnection?.setRemoteDescription(remoteDescription) { _ in }
    }

    public func addRemoteCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String) {
        let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        peerConnection?.add(iceCandidate)
    }

    public func setAudioOnly(_ audioOnly: Bool) {
        localVideoTrack?.isEnabled = !audioOnly
    }

    public func setMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    private var isUsingFrontCamera = true

    public func switchCamera() {
        isUsingFrontCamera.toggle()
        videoCapturer?.stopCapture()
        startCapture(front: isUsingFrontCamera)
    }

    public func close() {
        videoCapturer?.stopCapture()
        peerConnection?.close()
        peerConnection = nil
        videoCapturer = nil
        localVideoTrack = nil
        localAudioTrack = nil
        // Must reset alongside the rest of this call's state — this
        // instance is reused for the next call (see this type's header
        // comment), and leaving this `true` would make the delegate's
        // `guard !hasReportedConnected` permanently suppress `onConnected`
        // for every subsequent call after the first one in a session.
        hasReportedConnected = false
        // Deactivate with `.notifyOthersOnDeactivation` so apps that were
        // ducked/interrupted by `configureAudioSession`'s `.playAndRecord`
        // activation (e.g. background music) get a chance to resume.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed:
            guard !hasReportedConnected else { return }
            hasReportedConnected = true
            onConnected?()
        case .failed, .disconnected, .closed:
            guard hasReportedConnected else { return } // never reached .connected — CallManager's own 60s connecting-timeout handles that path
            onDisconnected?()
        default:
            break
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalCandidate?(candidate.sdpMLineIndex, candidate.sdpMid ?? "", candidate.sdp)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
