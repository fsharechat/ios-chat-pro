// App/CallViewController.swift
import UIKit
import Combine
import AVFoundation
import WebRTC
import IMCall

/// One continuous screen covering `.outgoing`/`.incoming`/`.connecting`/
/// `.connected` — see this task's header for why this isn't split into two
/// VC classes. Presented/dismissed by `SceneDelegate` (a later task) whenever
/// `CallManager.state` leaves/returns to `.idle`.
final class CallViewController: UIViewController {
    private let callManager: CallManager
    private let webRTCClient: WebRTCClient
    private let peerDisplayName: String
    private var cancellables = Set<AnyCancellable>()
    private var callConnectedAt: Date?
    private var durationTimer: Timer?

    private let remoteVideoView = RTCMTLVideoView()
    private let localVideoView = RTCMTLVideoView()
    private let avatarView = UIImageView()
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
    /// Captured once at construction time, before any toggle could have
    /// happened — `callManager.audioOnly` at this instant is still the
    /// call's original mode. `toggleVideoButton` only ever does anything
    /// for a call that started with video (see `CallManager.setAudioOnly`'s
    /// doc comment: turning video on mid-call requires SDP renegotiation
    /// that isn't implemented), so a call that started audio-only never
    /// shows it at all — there'd be nothing for the user to tap into.
    private let startedAsVideo: Bool

    init(callManager: CallManager, webRTCClient: WebRTCClient, peerDisplayName: String) {
        self.callManager = callManager
        self.webRTCClient = webRTCClient
        self.peerDisplayName = peerDisplayName
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
        addLocalPreviewDragGesture()
    }

    private func layoutViews() {
        nameLabel.text = peerDisplayName
        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statusLabel.font = .systemFont(ofSize: 14)
        avatarView.backgroundColor = Theme.backgroundTertiary
        avatarView.layer.cornerRadius = 48
        avatarView.clipsToBounds = true

        localVideoView.layer.cornerRadius = 8
        localVideoView.clipsToBounds = true
        localVideoView.layer.borderWidth = 1
        localVideoView.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor

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
            remoteVideoView.topAnchor.constraint(equalTo: view.topAnchor),
            remoteVideoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remoteVideoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remoteVideoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 96),
            avatarView.heightAnchor.constraint(equalToConstant: 96),

            localVideoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            localVideoView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            localVideoView.widthAnchor.constraint(equalToConstant: 90),
            localVideoView.heightAnchor.constraint(equalToConstant: 135),

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
    }

    private func bindCallManager() {
        callManager.$state
            .sink { [weak self] state in self?.applyState(state) }
            .store(in: &cancellables)
        callManager.$audioOnly
            .sink { [weak self] audioOnly in
                self?.remoteVideoView.isHidden = audioOnly
                self?.localVideoView.isHidden = audioOnly
                self?.avatarView.isHidden = !audioOnly
                self?.switchCameraButton.isHidden = audioOnly
                self?.toggleVideoButton.setImage(UIImage(systemName: audioOnly ? "video.fill" : "video.slash.fill"), for: .normal)
            }
            .store(in: &cancellables)
    }

    private func applyState(_ state: CallState) {
        let isIncoming = state == .incoming
        incomingBar.isHidden = !isIncoming
        controlBar.isHidden = isIncoming
        // 视频开关只在媒体已就绪、且这通电话以视频开局时才有意义。
        toggleVideoButton.isHidden = !startedAsVideo || (state != .connecting && state != .connected)
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
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let connectedAt = self.callConnectedAt else { return }
            let elapsed = Int(Date().timeIntervalSince(connectedAt))
            self.statusLabel.text = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    private func addLocalPreviewDragGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleLocalPreviewPan))
        localVideoView.isUserInteractionEnabled = true
        localVideoView.addGestureRecognizer(pan)
    }

    @objc private func handleLocalPreviewPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        localVideoView.center = CGPoint(x: localVideoView.center.x + translation.x, y: localVideoView.center.y + translation.y)
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
