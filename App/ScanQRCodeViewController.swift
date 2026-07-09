// App/ScanQRCodeViewController.swift
import UIKit
import AVFoundation
import PhotosUI

/// WeChat-style QR scanner: full-screen camera preview with a dimmed
/// viewfinder cutout, plus an album button that runs `CIDetector` over a
/// picked photo. Emits the raw QR string via `onScanned` — parsing/dispatch
/// is the caller's job (see `QRCodeContent.parse`).
final class ScanQRCodeViewController: UIViewController {

    /// Fired at most once per appearance, on the main queue.
    var onScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "scan-qrcode-session")
    private var didEmitResult = false

    private let dimLayer = CAShapeLayer()
    private let frameView = UIView()
    private let hintLabel = UILabel()
    private let albumButton = UIButton(type: .system)
    private let deniedStack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "扫一扫"
        view.backgroundColor = .black
        layoutOverlay()
        requestCameraIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        didEmitResult = false
        startSessionIfConfigured()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updateViewfinderMask()
    }

    // MARK: - 相机权限与会话

    private func requestCameraIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configureSession() : self?.showDeniedState()
                }
            }
        default:
            showDeniedState()
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showDeniedState()
            return
        }
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        startSessionIfConfigured()
    }

    private func startSessionIfConfigured() {
        sessionQueue.async { [session] in
            if !session.inputs.isEmpty, !session.isRunning { session.startRunning() }
        }
    }

    private func showDeniedState() {
        deniedStack.isHidden = false
        dimLayer.isHidden = true
        frameView.isHidden = true
        hintLabel.isHidden = true
    }

    // MARK: - UI

    private func layoutOverlay() {
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        view.layer.addSublayer(dimLayer)

        frameView.layer.borderColor = Theme.accent.cgColor
        frameView.layer.borderWidth = 2
        frameView.backgroundColor = .clear
        view.addSubview(frameView)

        hintLabel.text = "将二维码放入框内,即可自动扫描"
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        var albumConfig = UIButton.Configuration.plain()
        albumConfig.image = UIImage(systemName: "photo.on.rectangle")
        albumConfig.title = "相册"
        albumConfig.imagePlacement = .top
        albumConfig.imagePadding = 6
        albumConfig.baseForegroundColor = .white
        albumButton.configuration = albumConfig
        albumButton.translatesAutoresizingMaskIntoConstraints = false
        albumButton.addTarget(self, action: #selector(albumTapped), for: .touchUpInside)
        view.addSubview(albumButton)

        let deniedLabel = UILabel()
        deniedLabel.text = "未获得相机权限\n请在系统设置中允许飞享IM访问相机"
        deniedLabel.numberOfLines = 0
        deniedLabel.textAlignment = .center
        deniedLabel.textColor = .white
        deniedLabel.font = .systemFont(ofSize: 15)
        let settingsButton = UIButton(type: .system)
        settingsButton.setTitle("去设置", for: .normal)
        settingsButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        settingsButton.addTarget(self, action: #selector(openSettingsTapped), for: .touchUpInside)
        deniedStack.axis = .vertical
        deniedStack.spacing = 16
        deniedStack.alignment = .center
        deniedStack.addArrangedSubview(deniedLabel)
        deniedStack.addArrangedSubview(settingsButton)
        deniedStack.isHidden = true
        deniedStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(deniedStack)

        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            albumButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            albumButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),

            deniedStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            deniedStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            deniedStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
        ])
    }

    private func updateViewfinderMask() {
        let side: CGFloat = min(view.bounds.width - 96, 260)
        let rect = CGRect(
            x: (view.bounds.width - side) / 2,
            y: view.safeAreaInsets.top + 90,
            width: side,
            height: side
        )
        frameView.frame = rect
        hintLabel.frame.origin.y = rect.maxY + 16
        hintLabel.frame.size = CGSize(width: view.bounds.width - 32, height: 18)
        hintLabel.frame.origin.x = 16

        let path = UIBezierPath(rect: view.bounds)
        path.append(UIBezierPath(rect: rect))
        dimLayer.path = path.cgPath
        dimLayer.frame = view.bounds
    }

    // MARK: - 结果

    private func emit(_ raw: String) {
        guard !didEmitResult else { return }
        didEmitResult = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        onScanned?(raw)
    }

    /// Re-arms scanning after the caller decided the code wasn't actionable
    /// (e.g. unknown content alert dismissed).
    func resumeScanning() {
        didEmitResult = false
        startSessionIfConfigured()
    }

    // MARK: - 相册识码

    @objc private func albumTapped() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func openSettingsTapped() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func detectQRCode(in image: UIImage) -> String? {
        guard let ciImage = CIImage(image: image),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            return nil
        }
        let features = detector.features(in: ciImage)
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    private func presentNoCodeFoundAlert() {
        let alert = UIAlertController(title: nil, message: "未发现二维码", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

extension ScanQRCodeViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let raw = object.stringValue, !raw.isEmpty else { return }
        emit(raw)
    }
}

extension ScanQRCodeViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let image = object as? UIImage, let raw = self.detectQRCode(in: image) {
                    self.emit(raw)
                } else {
                    self.presentNoCodeFoundAlert()
                }
            }
        }
    }
}
