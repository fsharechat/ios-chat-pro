// App/CameraCaptureViewController.swift
import UIKit
import AVFoundation

/// 仿 Android 端 JCameraView 的拍摄界面：轻触拍照，长按录像（最长 15s，
/// 按钮外圈走环形进度），拍完先预览，左侧「撤回」重拍、右侧「完成」发送。
final class CameraCaptureViewController: UIViewController {
    var onImage: ((UIImage) -> Void)?
    /// 录像成功后回调临时 mp4 文件 URL，调用方负责消费并删除该文件。
    var onVideo: ((URL) -> Void)?

    private static let maxVideoDuration: TimeInterval = 15
    private static let minVideoDuration: TimeInterval = 1

    private enum State { case idle, recording, photoPreview, videoPreview }
    private var state: State = .idle

    // MARK: 采集

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cn.comsince.fschat.camera-session")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var usingFrontCamera = false
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: session)

    private var recordStartedAt: Date?
    private var discardRecording = false
    private var recordedVideoURL: URL?
    private var capturedImage: UIImage?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playbackLoopObserver: NSObjectProtocol?

    // MARK: UI

    private let captureButton = CaptureButtonView()
    private let closeButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private let hintLabel = UILabel()
    private let previewImageView = UIImageView()
    private let retakeButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        setupControls()
        requestPermissionsThenStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        playerLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPlayback()
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: 布局

    private func setupControls() {
        previewImageView.contentMode = .scaleAspectFill
        previewImageView.clipsToBounds = true
        previewImageView.isHidden = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewImageView)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        switchButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
        switchButton.tintColor = .white
        switchButton.addTarget(self, action: #selector(switchCameraTapped), for: .touchUpInside)

        hintLabel.text = "轻触拍照，长按摄像"
        hintLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.layer.shadowColor = UIColor.black.cgColor
        hintLabel.layer.shadowOpacity = 0.6
        hintLabel.layer.shadowRadius = 2
        hintLabel.layer.shadowOffset = .zero

        captureButton.onTap = { [weak self] in self?.capturePhoto() }
        captureButton.onLongPressBegan = { [weak self] in self?.startRecording() }
        captureButton.onLongPressEnded = { [weak self] in self?.finishRecording() }

        retakeButton.backgroundColor = UIColor(white: 0.25, alpha: 0.9)
        retakeButton.setImage(UIImage(systemName: "arrow.uturn.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)), for: .normal)
        retakeButton.tintColor = .white
        retakeButton.layer.cornerRadius = 32
        retakeButton.addTarget(self, action: #selector(retakeTapped), for: .touchUpInside)

        confirmButton.backgroundColor = .white
        confirmButton.setImage(UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)), for: .normal)
        confirmButton.tintColor = .systemGreen
        confirmButton.layer.cornerRadius = 32
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)

        for v in [closeButton, switchButton, hintLabel, captureButton, retakeButton, confirmButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        setPreviewControlsHidden(true)

        NSLayoutConstraint.activate([
            previewImageView.topAnchor.constraint(equalTo: view.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            switchButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            switchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            switchButton.widthAnchor.constraint(equalToConstant: 40),
            switchButton.heightAnchor.constraint(equalToConstant: 40),

            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -36),
            captureButton.widthAnchor.constraint(equalToConstant: 120),
            captureButton.heightAnchor.constraint(equalToConstant: 120),

            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -4),

            retakeButton.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),
            retakeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -90),
            retakeButton.widthAnchor.constraint(equalToConstant: 64),
            retakeButton.heightAnchor.constraint(equalToConstant: 64),

            confirmButton.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),
            confirmButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 90),
            confirmButton.widthAnchor.constraint(equalToConstant: 64),
            confirmButton.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    private func setPreviewControlsHidden(_ hidden: Bool) {
        retakeButton.isHidden = hidden
        confirmButton.isHidden = hidden
        captureButton.isHidden = !hidden
        hintLabel.isHidden = !hidden
        closeButton.isHidden = !hidden
        switchButton.isHidden = !hidden
    }

    // MARK: 权限与会话

    private func requestPermissionsThenStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestAudioThenStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.requestAudioThenStart() : self?.showPermissionAlert()
                }
            }
        default:
            showPermissionAlert()
        }
    }

    /// 麦克风权限只影响录像有无声音，拿不到也照常启动。
    private func requestAudioThenStart() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.startSession() }
            }
        } else {
            startSession()
        }
    }

    private func showPermissionAlert() {
        let alert = UIAlertController(title: "无法使用相机", message: "请在 设置-隐私-相机 中允许访问相机", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty { self.configureSession() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = Self.camera(position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            movieOutput.maxRecordedDuration = CMTime(seconds: Self.maxVideoDuration, preferredTimescale: 600)
            // Android 端 MediaPlayer 只稳定支持 H.264，明确关掉 HEVC。
            if let conn = movieOutput.connection(with: .video),
               movieOutput.availableVideoCodecTypes.contains(.h264) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: conn)
            }
        }
        session.commitConfiguration()
    }

    private static func camera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    // MARK: 顶部按钮

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func switchCameraTapped() {
        guard state == .idle else { return }
        let targetPosition: AVCaptureDevice.Position = usingFrontCamera ? .back : .front
        usingFrontCamera.toggle()
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = Self.camera(position: targetPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }
            self.session.beginConfiguration()
            if let old = self.videoInput { self.session.removeInput(old) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
            } else if let old = self.videoInput {
                self.session.addInput(old)
            }
            self.session.commitConfiguration()
        }
    }

    // MARK: 拍照

    private func capturePhoto() {
        guard state == .idle else { return }
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        if let conn = photoOutput.connection(with: .video) {
            conn.videoOrientation = .portrait
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = usingFrontCamera
            }
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: 录像

    private func startRecording() {
        guard state == .idle, !movieOutput.isRecording else { return }
        state = .recording
        closeButton.isHidden = true
        switchButton.isHidden = true
        hintLabel.isHidden = true
        if let conn = movieOutput.connection(with: .video) {
            conn.videoOrientation = .portrait
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = usingFrontCamera
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-\(UUID().uuidString).mp4")
        recordStartedAt = Date()
        captureButton.beginRecording(duration: Self.maxVideoDuration)
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    /// 手指抬起（或长按被打断）时结束录制；15s 到点的自动停止走
    /// maxRecordedDuration，不经过这里。
    private func finishRecording() {
        guard state == .recording, movieOutput.isRecording else { return }
        let elapsed = Date().timeIntervalSince(recordStartedAt ?? Date())
        if elapsed < Self.minVideoDuration {
            discardRecording = true
            showToast("录制时间过短")
        }
        captureButton.endRecording()
        movieOutput.stopRecording()
    }

    // MARK: 预览：撤回 / 完成

    private func showPhotoPreview(_ image: UIImage) {
        capturedImage = image
        previewImageView.image = image
        previewImageView.isHidden = false
        state = .photoPreview
        setPreviewControlsHidden(false)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func showVideoPreview(url: URL) {
        recordedVideoURL = url
        state = .videoPreview
        setPreviewControlsHidden(false)

        let player = AVPlayer(url: url)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        // 插在预览层之上、按钮之下
        view.layer.insertSublayer(layer, above: previewLayer)
        self.player = player
        self.playerLayer = layer
        playbackLoopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        player.play()
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func stopPlayback() {
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        if let observer = playbackLoopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        playbackLoopObserver = nil
        player = nil
        playerLayer = nil
    }

    @objc private func retakeTapped() {
        stopPlayback()
        if let url = recordedVideoURL {
            try? FileManager.default.removeItem(at: url)
            recordedVideoURL = nil
        }
        capturedImage = nil
        previewImageView.image = nil
        previewImageView.isHidden = true
        captureButton.reset()
        setPreviewControlsHidden(true)
        state = .idle
        startSession()
    }

    @objc private func confirmTapped() {
        switch state {
        case .photoPreview:
            guard let image = capturedImage else { return }
            dismiss(animated: true) { [onImage] in onImage?(image) }
        case .videoPreview:
            guard let url = recordedVideoURL else { return }
            recordedVideoURL = nil // 交给回调方消费，retake/析构不再删它
            stopPlayback()
            dismiss(animated: true) { [onVideo] in onVideo?(url) }
        default:
            break
        }
    }

    private func resetToIdle() {
        captureButton.reset()
        closeButton.isHidden = false
        switchButton.isHidden = false
        hintLabel.isHidden = false
        state = .idle
    }

    private func showToast(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.7)
        label.textAlignment = .center
        label.layer.cornerRadius = 16
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 140),
            label.heightAnchor.constraint(equalToConstant: 32),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.2, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

// MARK: - 拍照回调

extension CameraCaptureViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showPhotoPreview(image)
        }
    }
}

// MARK: - 录像回调

extension CameraCaptureViewController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 15s 到点的自动停止会带 maximumDurationReached error，但文件有效，
            // 以 userInfo 里的 finished 标志为准。
            var recordedOK = true
            if let nsError = error as NSError? {
                recordedOK = (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            }
            self.captureButton.endRecording()
            if self.discardRecording || !recordedOK {
                self.discardRecording = false
                try? FileManager.default.removeItem(at: outputFileURL)
                self.resetToIdle()
                return
            }
            self.showVideoPreview(url: outputFileURL)
        }
    }
}

// MARK: - 拍摄按钮

/// 双圈按钮：轻触拍照；长按外圈放大、内圈缩小并开始录像，
/// 外圈边缘走绿色环形进度。
private final class CaptureButtonView: UIView {
    var onTap: (() -> Void)?
    var onLongPressBegan: (() -> Void)?
    var onLongPressEnded: (() -> Void)?

    private let outerView = UIView()
    private let innerView = UIView()
    private let progressLayer = CAShapeLayer()

    private let outerDiameter: CGFloat = 72
    private let innerDiameter: CGFloat = 54
    private let recordingScale: CGFloat = 1.3

    override init(frame: CGRect) {
        super.init(frame: frame)

        outerView.backgroundColor = UIColor(white: 0.9, alpha: 0.45)
        outerView.layer.cornerRadius = outerDiameter / 2
        outerView.isUserInteractionEnabled = false
        addSubview(outerView)

        innerView.backgroundColor = .white
        innerView.layer.cornerRadius = innerDiameter / 2
        innerView.isUserInteractionEnabled = false
        addSubview(innerView)

        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.strokeColor = UIColor.systemGreen.cgColor
        progressLayer.lineWidth = 5
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        layer.addSublayer(progressLayer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        outerView.bounds = CGRect(x: 0, y: 0, width: outerDiameter, height: outerDiameter)
        outerView.center = center
        innerView.bounds = CGRect(x: 0, y: 0, width: innerDiameter, height: innerDiameter)
        innerView.center = center
        let radius = outerDiameter * recordingScale / 2 - progressLayer.lineWidth / 2
        progressLayer.frame = bounds
        progressLayer.path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: .pi * 3 / 2,
            clockwise: true
        ).cgPath
    }

    @objc private func handleTap() { onTap?() }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            onLongPressBegan?()
        case .ended, .cancelled, .failed:
            onLongPressEnded?()
        default:
            break
        }
    }

    func beginRecording(duration: TimeInterval) {
        UIView.animate(withDuration: 0.2) {
            self.outerView.transform = CGAffineTransform(scaleX: self.recordingScale, y: self.recordingScale)
            self.innerView.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
        }
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        progressLayer.add(anim, forKey: "progress")
    }

    /// 停止走进度但保持缩放形态（等待录像回调决定去向）。
    func endRecording() {
        // 冻结当前进度，避免松手瞬间环形跳回 0
        if let presentation = progressLayer.presentation() {
            progressLayer.strokeEnd = presentation.strokeEnd
        }
        progressLayer.removeAnimation(forKey: "progress")
    }

    func reset() {
        progressLayer.removeAllAnimations()
        progressLayer.strokeEnd = 0
        UIView.animate(withDuration: 0.2) {
            self.outerView.transform = .identity
            self.innerView.transform = .identity
        }
    }
}
