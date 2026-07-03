import AVFoundation
import CoreMedia
import WebRTC

/// 纯数据的 ICE/TURN 配置 —— 不复用 `AppCore.AppConfig.IceServer` 以避免
/// 反向依赖成环(AppCore 依赖 IMCall)。App target 在构造 `WebRTCClient`
/// 的唯一调用点做映射。
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

/// 生产版 `MediaEngine`,两阶段模型(对齐 Android AVEngineKit):
/// `startPreview` 建 capturer/本地轨(本地画面立即可渲染),`connect` 建
/// PeerConnection。单实例跨通话复用:`close()` 拆干净,下一通重建。
///
/// **渲染挂载(pending-renderer):** `attachLocalRenderer`/`attachRemoteRenderer`
/// 随时可调 —— 轨道已存在就立即挂,否则记下 renderer,等轨道出现(本地:
/// `startPreview`;远端:`didAdd rtpReceiver` 代理回调)时自动补挂。这消除
/// 了旧实现"viewDidLoad 挂载时轨道还不存在,一次挂空永不重试"的黑屏根因。
///
/// **线程:** WebRTC 的代理/completion 在其内部线程回调,这里统一派发回主
/// 队列再向外抛,维持 CallManager 的主队列契约。
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
    private var remoteVideoTrack: RTCVideoTrack?
    private var localRenderer: RTCVideoRenderer?
    private var remoteRenderer: RTCVideoRenderer?
    /// 保证 onConnected/onDisconnected 每次通话只各发一次(ICE 状态会多次抖动)。
    private var hasReportedConnected = false
    private var isUsingFrontCamera = true

    public init(iceServers: [IceServer]) {
        self.iceServers = iceServers
        super.init()
    }

    // MARK: - 渲染挂载

    public func attachLocalRenderer(_ renderer: RTCVideoRenderer) {
        localRenderer = renderer
        localVideoTrack?.add(renderer)
    }

    public func attachRemoteRenderer(_ renderer: RTCVideoRenderer) {
        remoteRenderer = renderer
        remoteVideoTrack?.add(renderer)
    }

    // MARK: - 阶段一:本地预览

    public func startPreview(audioOnly: Bool) {
        guard localAudioTrack == nil else { return } // 重入保护(如 glare 后重开)
        configureAudioSession(audioOnly: audioOnly)

        localAudioTrack = Self.factory.audioTrack(withTrackId: "audio0")

        if !audioOnly {
            let videoSource = Self.factory.videoSource()
            let capturer = RTCCameraVideoCapturer(delegate: videoSource)
            videoCapturer = capturer
            let videoTrack = Self.factory.videoTrack(with: videoSource, trackId: "video0")
            localVideoTrack = videoTrack
            if let renderer = localRenderer { videoTrack.add(renderer) } // 补挂已登记的 renderer
            startCapture(front: true)
        }
    }

    // MARK: - 阶段二:建立连接

    public func connect() {
        guard peerConnection == nil else { return }
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: [$0.urlString], username: $0.username, credential: $0.credential)
        }
        configuration.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else { return }
        connection.delegate = self
        peerConnection = connection

        if let audioTrack = localAudioTrack { connection.add(audioTrack, streamIds: ["stream0"]) }
        if let videoTrack = localVideoTrack { connection.add(videoTrack, streamIds: ["stream0"]) }
    }

    /// 没这个配置 setMuted/扬声器切换会静默失效(overrideOutputAudioPort 只
    /// 对 .playAndRecord 会话生效);.voiceChat 给 WebRTC 音频单元 VoIP 语义
    ///(回声消除、听筒/扬声器自动路由)。视频通话默认外放,对齐 Android。
    private func configureAudioSession(audioOnly: Bool) {
        // iOS-only:macOS 无 AVAudioSession,Package.swift 声明 .macOS(.v12)
        // 只为让 swift test 能构建。
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        if !audioOnly { options.insert(.defaultToSpeaker) }
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try? session.setActive(true)
        #endif
    }

    /// 默认前摄(自拍小窗);格式选最接近 720p 的(Android 端 VideoProfile
    /// 默认 VP720P),fps 封顶 30 —— 旧实现取"第一个格式"可能极低清。
    private func startCapture(front: Bool) {
        guard let capturer = videoCapturer else { return }
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }) else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let targetPixels = 1280 * 720
        guard let format = formats.min(by: { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return abs(Int(l.width) * Int(l.height) - targetPixels) < abs(Int(r.width) * Int(r.height) - targetPixels)
        }) else { return }
        let maxFps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(maxFps, 30)))
    }

    // MARK: - SDP / ICE

    public func createOffer(completion: @escaping (String) -> Void) {
        guard let connection = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection.offer(for: constraints) { sdp, _ in
            guard let sdp else { return }
            connection.setLocalDescription(sdp) { _ in
                DispatchQueue.main.async { completion(sdp.sdp) } // 回主队列,守 CallManager 契约
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
                    DispatchQueue.main.async { completion(answerSDP.sdp) }
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

    public func removeRemoteCandidates(_ candidates: [RemoteIceCandidate]) {
        let iceCandidates = candidates.map {
            RTCIceCandidate(sdp: $0.candidate, sdpMLineIndex: $0.sdpMLineIndex, sdpMid: $0.sdpMid)
        }
        peerConnection?.remove(iceCandidates)
    }

    // MARK: - 通话中控制

    public func setAudioOnly(_ audioOnly: Bool) {
        localVideoTrack?.isEnabled = !audioOnly
    }

    public func setMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    public func switchCamera() {
        isUsingFrontCamera.toggle()
        videoCapturer?.stopCapture()
        startCapture(front: isUsingFrontCamera)
    }

    // MARK: - 收场

    public func close() {
        videoCapturer?.stopCapture()
        peerConnection?.close()
        peerConnection = nil
        videoCapturer = nil
        localVideoTrack = nil
        localAudioTrack = nil
        remoteVideoTrack = nil
        // 注意:不清 localRenderer/remoteRenderer —— renderer 归 UI(CallViewController)
        // 持有,不归这次通话的 PeerConnection 生命周期管。glare 败者路径下
        // CallManager 会 close() 掉预览再转入 incoming,但同一个 CallViewController
        // 不会重建,若这里把 renderer 置 nil,接听后就没有 renderer 可补挂,
        // 造成双向黑屏。下一通电话的 VC attach 时会用新的 renderer 覆盖它们。
        isUsingFrontCamera = true
        // 必须复位:实例跨通话复用,留 true 会永久吞掉下一通的 onConnected。
        hasReportedConnected = false
        // .notifyOthersOnDeactivation:让被 .playAndRecord 压掉的后台音频恢复。
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        // WebRTC 内部线程 → 主队列,维持 CallManager 的主队列契约。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch newState {
            case .connected, .completed:
                guard !self.hasReportedConnected else { return }
                self.hasReportedConnected = true
                self.onConnected?()
            case .failed, .disconnected, .closed:
                // 从未连通过的失败由 CallManager 的 60s 连接超时兜底。
                guard self.hasReportedConnected else { return }
                self.onDisconnected?()
            default:
                break
            }
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let (index, mid, sdp) = (candidate.sdpMLineIndex, candidate.sdpMid ?? "", candidate.sdp)
        DispatchQueue.main.async { [weak self] in
            self?.onLocalCandidate?(index, mid, sdp)
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        // unified-plan 下远端轨道从 receiver 到达 —— 这是远端画面能渲染的关键
        //(旧实现在 viewDidLoad 时从 transceivers 找轨道,彼时协商未完成,
        // 永远挂空)。
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.remoteVideoTrack = track
            if let renderer = self.remoteRenderer { track.add(renderer) }
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
