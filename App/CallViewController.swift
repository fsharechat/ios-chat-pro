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
    private let hangUpButton = CallControlButton(systemImageName: "phone.down.fill", backgroundColor: .systemRed)
    private var isMuted = false
    private var isSpeakerOn = false

    init(callManager: CallManager, webRTCClient: WebRTCClient, peerDisplayName: String) {
        self.callManager = callManager
        self.webRTCClient = webRTCClient
        self.peerDisplayName = peerDisplayName
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutViews()
        bindCallManager()
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
        hangUpButton.addTarget(self, action: #selector(hangUpTapped), for: .touchUpInside)

        let controlBar = UIStackView(arrangedSubviews: [muteButton, switchCameraButton, hangUpButton, speakerButton])
        controlBar.axis = .horizontal
        controlBar.distribution = .equalSpacing
        controlBar.alignment = .center

        let centerStack = UIStackView(arrangedSubviews: [avatarView, nameLabel, statusLabel])
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 12

        [remoteVideoView, centerStack, localVideoView, controlBar].forEach {
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
            }
            .store(in: &cancellables)
    }

    private func applyState(_ state: CallState) {
        switch state {
        case .idle:
            durationTimer?.invalidate()
        case .outgoing:
            statusLabel.text = "正在呼叫…"
        case .incoming:
            statusLabel.text = "邀请你通话"
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

    @objc private func hangUpTapped() {
        try? callManager.hangUp()
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
