// App/CallViewController.swift
import UIKit
import Combine
import AVFoundation
import WebRTC
import IMCall
import IMKit

/// One continuous screen covering `.outgoing`/`.incoming`/`.connecting`/
/// `.connected` — see this task's header for why this isn't split into two
/// VC classes. Presented/dismissed by `SceneDelegate` (a later task) whenever
/// `CallManager.state` leaves/returns to `.idle`.
final class CallViewController: UIViewController {
    private let callManager: CallManager
    private let webRTCClient: WebRTCClient
    private let peerDisplayName: String
    private let peerPortrait: String?
    private var cancellables = Set<AnyCancellable>()
    private var callConnectedAt: Date?
    private var durationTimer: Timer?

    private let remoteVideoView = RTCMTLVideoView()
    private let localVideoView = RTCMTLVideoView()
    private let avatarView = AvatarImageView(loader: AvatarLoader.shared)
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let muteButton = CallControlButton(systemImageName: "mic.slash.fill")
    private let speakerButton = CallControlButton(systemImageName: "speaker.wave.2.fill")
    private let switchCameraButton = CallControlButton(systemImageName: "camera.rotate.fill")
    private let toggleVideoButton = CallControlButton(systemImageName: "video.fill")
    private let hangUpButton = CallControlButton(systemImageName: "phone.down.fill", backgroundColor: .systemRed)
    private let controlBar = UIStackView()
    // 来电操作区:接听前只显示 拒绝/接听 两个大按钮(对齐 Android 来电页)。
    private let incomingBar = UIStackView()
    private let acceptButton = CallControlButton(systemImageName: "phone.fill", backgroundColor: .systemGreen)
    private let rejectButton = CallControlButton(systemImageName: "phone.down.fill", backgroundColor: .systemRed)
    private var isMuted = false
    private var isSpeakerOn = false
    // 信息区(头像/名字/计时)的两套竖向位置:语音通话居中(头像是主视觉);
    // 视频通话时远端画面占满全屏,居中会压在画面正中,改挪到底部控制条上方。
    private var centerStackCenterYConstraint: NSLayoutConstraint?
    private var centerStackBottomConstraint: NSLayoutConstraint?
    // 视频画面的槽位分配(对齐微信):接通前本地预览铺满全屏、小窗不显示;
    // 接通后远端全屏、本地进右上角小窗;点小窗交换大小画面(swapped)。
    // 交换的是两个 RTCMTLVideoView 的布局槽位,不动 renderer 与轨道的绑定,
    // 避免换绑期间黑屏。
    private var swapped = false
    private var remoteVideoConstraints: [NSLayoutConstraint] = []
    private var localVideoConstraints: [NSLayoutConstraint] = []
    /// Captured once at construction time, before any toggle could have
    /// happened — `callManager.audioOnly` at this instant is still the
    /// call's original mode. `toggleVideoButton` only ever does anything
    /// for a call that started with video (see `CallManager.setAudioOnly`'s
    /// doc comment: turning video on mid-call requires SDP renegotiation
    /// that isn't implemented), so a call that started audio-only never
    /// shows it at all — there'd be nothing for the user to tap into.
    private let startedAsVideo: Bool

    init(callManager: CallManager, webRTCClient: WebRTCClient, peerDisplayName: String, peerPortrait: String?) {
        self.callManager = callManager
        self.webRTCClient = webRTCClient
        self.peerDisplayName = peerDisplayName
        self.peerPortrait = peerPortrait
        self.startedAsVideo = !callManager.audioOnly
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        // Defensive: the only wired-up dismissal path already invalidates
        // this via `applyState(.idle)`, but don't rely on that being the
        // only way this VC ever goes away — a repeating `Timer` left
        // running with no owner is a real leak regardless of how harmless
        // it looks today.
        durationTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutViews()
        bindCallManager()
        // pending-renderer:轨道尚未创建也没关系,WebRTCClient 会在轨道
        // 出现时自动补挂(本地:startPreview;远端:didAdd rtpReceiver)。
        webRTCClient.attachRemoteRenderer(remoteVideoView)
        webRTCClient.attachLocalRenderer(localVideoView)
        addVideoViewGestures()
    }

    private func layoutViews() {
        nameLabel.text = peerDisplayName
        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statusLabel.font = .systemFont(ofSize: 14)
        avatarView.setAvatar(urlString: peerPortrait, displayName: peerDisplayName)

        localVideoView.clipsToBounds = true
        remoteVideoView.clipsToBounds = true

        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        speakerButton.addTarget(self, action: #selector(speakerTapped), for: .touchUpInside)
        switchCameraButton.addTarget(self, action: #selector(switchCameraTapped), for: .touchUpInside)
        toggleVideoButton.addTarget(self, action: #selector(toggleVideoTapped), for: .touchUpInside)
        hangUpButton.addTarget(self, action: #selector(hangUpTapped), for: .touchUpInside)

        [muteButton, switchCameraButton, toggleVideoButton, hangUpButton, speakerButton].forEach { controlBar.addArrangedSubview($0) }
        controlBar.axis = .horizontal
        controlBar.distribution = .equalSpacing
        controlBar.alignment = .center

        acceptButton.addTarget(self, action: #selector(acceptTapped), for: .touchUpInside)
        rejectButton.addTarget(self, action: #selector(rejectTapped), for: .touchUpInside)
        [rejectButton, acceptButton].forEach { incomingBar.addArrangedSubview($0) }
        incomingBar.axis = .horizontal
        incomingBar.distribution = .equalSpacing
        incomingBar.alignment = .center

        let centerStack = UIStackView(arrangedSubviews: [avatarView, nameLabel, statusLabel])
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 12

        [remoteVideoView, centerStack, localVideoView, controlBar, incomingBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        let controlBarBackground = UIView()
        controlBarBackground.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        controlBarBackground.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(controlBarBackground, belowSubview: controlBar)

        NSLayoutConstraint.activate([
            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 96),
            avatarView.heightAnchor.constraint(equalToConstant: 96),

            controlBarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlBarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlBarBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controlBarBackground.topAnchor.constraint(equalTo: controlBar.topAnchor, constant: -16),

            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            controlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            controlBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),

            incomingBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 64),
            incomingBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -64),
            incomingBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])

        centerStackCenterYConstraint = centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        centerStackBottomConstraint = centerStack.bottomAnchor.constraint(equalTo: controlBar.topAnchor, constant: -24)
        // 初始位置由 bindCallManager 的 audioOnly sink 立即设定(Combine 对
        // @Published 的订阅同步回放当前值),这里不用先激活任何一条。
    }

    private func bindCallManager() {
        callManager.statePublisher
            .sink { [weak self] state in self?.applyState(state) }
            .store(in: &cancellables)
        callManager.audioOnlyPublisher
            .sink { [weak self] audioOnly in
                guard let self else { return }
                self.updateVideoLayout()
                self.avatarView.isHidden = !audioOnly
                self.switchCameraButton.isHidden = audioOnly
                self.toggleVideoButton.setImage(UIImage(systemName: audioOnly ? "video.fill" : "video.slash.fill"), for: .normal)
                // 先撤旧约束再上新约束,避免瞬时双激活冲突。
                if audioOnly {
                    self.centerStackBottomConstraint?.isActive = false
                    self.centerStackCenterYConstraint?.isActive = true
                } else {
                    self.centerStackCenterYConstraint?.isActive = false
                    self.centerStackBottomConstraint?.isActive = true
                }
            }
            .store(in: &cancellables)
    }

    private func applyState(_ state: CallState) {
        let isIncoming = state == .incoming
        incomingBar.isHidden = !isIncoming
        controlBar.isHidden = isIncoming
        // 视频开关只在通话已 Connected、且这通电话以视频开局时才有意义 ——
        // 与 CallManager.setAudioOnly/入站 Modify 仅在 .connected 放行对齐
        // (Android 仅在 Connected 处理/发送 Modify),connecting 阶段两端
        // PeerConnection 还没建好,提前露出这个按钮会让用户在它其实是 no-op
        // 的窗口期点了它。
        toggleVideoButton.isHidden = !startedAsVideo || state != .connected
        switch state {
        case .idle:
            durationTimer?.invalidate()
        case .outgoing:
            statusLabel.text = "正在呼叫…"
        case .incoming:
            statusLabel.text = callManager.audioOnly ? "邀请你进行语音通话" : "邀请你进行视频通话"
        case .connecting:
            statusLabel.text = "连接中…"
        case .connected:
            callConnectedAt = Date()
            startDurationTimer()
        }
        if state != .connected { swapped = false } // 大小画面交换只在通话中有意义
        updateVideoLayout()
    }

    // MARK: - 视频画面槽位

    /// 当前占小窗槽位的画面(仅接通后有意义,接通前小窗不显示)。
    private var pipVideoView: UIView { swapped ? remoteVideoView : localVideoView }

    private func updateVideoLayout() {
        NSLayoutConstraint.deactivate(remoteVideoConstraints + localVideoConstraints)
        let audioOnly = callManager.audioOnly
        let connected = callManager.state == .connected

        let fullscreenView: RTCMTLVideoView
        let pipView: RTCMTLVideoView
        if connected && !swapped {
            fullscreenView = remoteVideoView
            pipView = localVideoView
        } else if connected {
            fullscreenView = localVideoView
            pipView = remoteVideoView
        } else {
            // 接通前:本地预览铺满全屏(拨出/接听等待期都是),远端还没画面,
            // 小窗槽位闲置(隐藏)。
            fullscreenView = localVideoView
            pipView = remoteVideoView
        }

        // 接通前小窗槽位闲置:占位其中的视图直接隐藏(pipView 此时必是远端)。
        remoteVideoView.isHidden = audioOnly || (!connected && remoteVideoView == pipView)
        localVideoView.isHidden = audioOnly || (!connected && localVideoView == pipView)

        let assignFullscreen = fullscreenConstraints(for: fullscreenView)
        let assignPip = pipConstraints(for: pipView)
        if fullscreenView == remoteVideoView {
            remoteVideoConstraints = assignFullscreen
            localVideoConstraints = assignPip
        } else {
            localVideoConstraints = assignFullscreen
            remoteVideoConstraints = assignPip
        }
        NSLayoutConstraint.activate(remoteVideoConstraints + localVideoConstraints)

        // 全屏画面垫底(信息区/控制条都在其上),小窗浮在最上层。
        view.sendSubviewToBack(fullscreenView)
        view.bringSubviewToFront(pipView)

        fullscreenView.layer.cornerRadius = 0
        fullscreenView.layer.borderWidth = 0
        pipView.layer.cornerRadius = 8
        pipView.layer.borderWidth = 1
        pipView.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
    }

    private func fullscreenConstraints(for videoView: UIView) -> [NSLayoutConstraint] {
        [
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
    }

    private func pipConstraints(for videoView: UIView) -> [NSLayoutConstraint] {
        [
            videoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            videoView.widthAnchor.constraint(equalToConstant: 110),
            videoView.heightAnchor.constraint(equalToConstant: 165),
        ]
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let connectedAt = self.callConnectedAt else { return }
            let elapsed = Int(Date().timeIntervalSince(connectedAt))
            self.statusLabel.text = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    /// 拖动与点击都装在两个视频视图上,手势回调里按"谁正占着小窗槽位"过滤 ——
    /// 交换大小画面后小窗可能是本地也可能是远端。
    private func addVideoViewGestures() {
        for videoView in [localVideoView, remoteVideoView] {
            videoView.isUserInteractionEnabled = true
            videoView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePipPan)))
            videoView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handlePipTap)))
        }
    }

    @objc private func handlePipTap(_ gesture: UITapGestureRecognizer) {
        // 对齐微信:接通后点小窗交换大小画面;接通前小窗不存在,不响应。
        guard callManager.state == .connected, gesture.view == pipVideoView else { return }
        swapped.toggle()
        updateVideoLayout()
    }

    @objc private func handlePipPan(_ gesture: UIPanGestureRecognizer) {
        guard callManager.state == .connected, let videoView = gesture.view, videoView == pipVideoView else { return }
        let translation = gesture.translation(in: view)
        videoView.center = CGPoint(x: videoView.center.x + translation.x, y: videoView.center.y + translation.y)
        gesture.setTranslation(.zero, in: view)
    }

    @objc private func muteTapped() {
        isMuted.toggle()
        muteButton.setActive(isMuted)
        webRTCClient.setMuted(isMuted)
    }

    @objc private func speakerTapped() {
        isSpeakerOn.toggle()
        speakerButton.setActive(isSpeakerOn)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
    }

    @objc private func switchCameraTapped() {
        webRTCClient.switchCamera()
    }

    @objc private func toggleVideoTapped() {
        try? callManager.setAudioOnly(!callManager.audioOnly)
    }

    @objc private func hangUpTapped() {
        try? callManager.hangUp()
    }

    @objc private func acceptTapped() {
        // 与已移除的系统级来电接听路径同语义:权限不足时自动拒接,而不是
        // 接进一个没声音/没画面的通话。
        CallPermissions.ensureAuthorized(audioOnly: callManager.audioOnly) { [weak self] authorized in
            guard let self else { return }
            guard authorized else {
                try? self.callManager.reject()
                return
            }
            try? self.callManager.answer()
        }
    }

    @objc private func rejectTapped() {
        try? callManager.reject()
    }
}

/// Round, semi-transparent control bar button — `systemImageName`-driven so
/// the same type covers mute/speaker/switch-camera/hang-up without four
/// near-duplicate subclasses.
private final class CallControlButton: UIButton {
    init(systemImageName: String, backgroundColor: UIColor = UIColor.white.withAlphaComponent(0.25)) {
        super.init(frame: .zero)
        self.backgroundColor = backgroundColor
        tintColor = .white
        setImage(UIImage(systemName: systemImageName), for: .normal)
        layer.cornerRadius = 28
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 56).isActive = true
        heightAnchor.constraint(equalToConstant: 56).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setActive(_ active: Bool) {
        backgroundColor = active ? Theme.accent : UIColor.white.withAlphaComponent(0.25)
    }
}
