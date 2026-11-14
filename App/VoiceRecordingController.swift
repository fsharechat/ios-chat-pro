import UIKit
import AVFoundation
import IMKit

/// Owns microphone, temporary files and a single press lifecycle. All entry points use the main queue.
final class VoiceRecordingController: NSObject, AVAudioRecorderDelegate {
    var onUpdate: ((_ title: String, _ isRecording: Bool) -> Void)?
    var onNotice: ((String) -> Void)?
    var onSend: ((_ data: Data, _ duration: Int, _ name: String, _ localURL: URL?) -> Void)?

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var timer: Timer?
    private var gesture = VoiceRecordingGestureState()
    private var permissionRequestID: UUID?
    private var deliveryEpoch = 0
    var isRecording: Bool { gesture.isActive }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cancelAll),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit {
        timer?.invalidate()
        recorder?.stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        if recorder != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func begin() {
        guard !isRecording, permissionRequestID == nil else { return }
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .undetermined:
            let id = UUID()
            permissionRequestID = id
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.permissionRequestID == id else { return }
                    self.permissionRequestID = nil
                    self.onNotice?(granted ? "已允许麦克风，请重新按住说话" : "请在系统设置中允许飞享IM使用麦克风")
                }
            }
            return
        case .denied:
            onNotice?("请在系统设置中允许飞享IM使用麦克风")
            return
        case .granted: break
        @unknown default: return
        }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
            recorder.delegate = self
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            url = file
            gesture.begin()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            refreshTitle()
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            try? FileManager.default.removeItem(at: file)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            onNotice?("无法开始录音，请稍后重试")
        }
    }

    func move(upwardDistance: CGFloat) {
        let wasCancelled = gesture.isCancelArmed
        gesture.move(upwardDistance: Double(upwardDistance))
        if wasCancelled != gesture.isCancelArmed {
            UISelectionFeedbackGenerator().selectionChanged()
            refreshTitle()
        }
    }

    func finish(cancelled: Bool) {
        let hadRecording = isRecording
        let shouldSend = gesture.finish(cancelled: cancelled)
        let duration = recorder?.currentTime ?? 0
        timer?.invalidate()
        timer = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        let file = url
        url = nil
        if hadRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        onUpdate?("按住说话", false)
        guard let file else { return }
        guard shouldSend, duration >= 1 else {
            try? FileManager.default.removeItem(at: file)
            if shouldSend { onNotice?("说话时间太短") }
            return
        }
        convert(file, duration: Int(duration))
    }

    @objc func cancelAll() {
        permissionRequestID = nil
        deliveryEpoch += 1
        finish(cancelled: true)
    }

    @objc private func interrupted(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              type == AVAudioSession.InterruptionType.began.rawValue else { return }
        cancelAll()
    }

    private func tick() {
        guard isRecording else { return }
        if (recorder?.currentTime ?? 0) >= 60 { finish(cancelled: false) }
        else { refreshTitle() }
    }

    private func refreshTitle() {
        guard isRecording else { return }
        let seconds = Int(recorder?.currentTime ?? 0)
        let suffix = seconds >= 50 ? " · 剩余\(60 - seconds)秒" : " · 上滑取消"
        onUpdate?(gesture.isCancelArmed ? "松开取消" : "\(seconds)秒 · 松开发送\(suffix)", true)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        cancelAll()
        onNotice?("录音中断，请重试")
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard recorder === self.recorder, isRecording else { return }
        cancelAll()
        onNotice?("录音中断，请重试")
    }

    private func convert(_ file: URL, duration: Int) {
        let epoch = deliveryEpoch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { try? FileManager.default.removeItem(at: file) }
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceMessages")
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let localURL = cache.appendingPathComponent(file.lastPathComponent)
            let cached = (try? FileManager.default.copyItem(at: file, to: localURL)) != nil
            let amr = VoiceConverter.convertToAMR(from: file)
            let data: Data?
            let name: String
            if let amr, amr.count > 20 {
                data = amr
                name = file.deletingPathExtension().appendingPathExtension("amr").lastPathComponent
            } else {
                data = try? Data(contentsOf: file)
                name = file.lastPathComponent
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.deliveryEpoch == epoch else {
                    try? FileManager.default.removeItem(at: localURL)
                    return
                }
                guard let data else {
                    try? FileManager.default.removeItem(at: localURL)
                    self.onNotice?("语音处理失败，请重试")
                    return
                }
                self.onSend?(data, duration, name, cached ? localURL : nil)
            }
        }
    }
}
