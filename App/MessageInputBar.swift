import UIKit
import AVFoundation

final class MessageInputBar: UIView {

    // MARK: - Public callbacks
    var onSendText: ((_ text: String, _ mentionedType: Int32, _ mentionedTargets: [String]) -> Void)?
    var onPickImage: (() -> Void)?
    var onCamera: (() -> Void)?
    var onPickFile: (() -> Void)?
    var onSendVoice: ((_ audioData: Data, _ duration: Int, _ fileName: String, _ localM4AURL: URL?) -> Void)?
    var onMentionTriggered: (() -> Void)?

    // MARK: - Mention state
    private var mentionedType: Int32 = 0
    private var mentionedTargets: [String] = []

    // MARK: - Panel state
    private enum PanelState { case none, emoji, ext }
    private var panelState: PanelState = .none
    private var isVoiceMode = false

    // MARK: - Subviews
    private let voiceToggleButton = UIButton(type: .system)
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let recordButton = UIButton(type: .system)
    private let emojiButton = UIButton(type: .system)
    private let extButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private var textViewHeightConstraint: NSLayoutConstraint!

    private let panelContainer = UIView()
    private var panelContainerHeightConstraint: NSLayoutConstraint!
    private let emojiPanel = EmojiPanelView()
    private let extPanel = ExtPanelView()

    // MARK: - Voice recording
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        setupInputRow()
        setupPanelContainer()
        wireCallbacks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API (mention)
    func insertMention(uid: String?, displayName: String) {
        textView.text += "@\(displayName) "
        if let uid {
            if mentionedType != 2 { mentionedType = 1; mentionedTargets.append(uid) }
        } else {
            mentionedType = 2; mentionedTargets = []
        }
        textViewDidChange(textView)
    }

    func removeTrailingMentionTrigger() {
        guard textView.text.hasSuffix("@") else { return }
        textView.text.removeLast()
        textViewDidChange(textView)
    }

    // MARK: - Layout
    private func setupInputRow() {
        voiceToggleButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        voiceToggleButton.tintColor = Theme.accent
        voiceToggleButton.addTarget(self, action: #selector(voiceToggleTapped), for: .touchUpInside)

        textView.font = .systemFont(ofSize: 16)
        textView.backgroundColor = Theme.backgroundTertiary
        textView.layer.cornerRadius = Theme.cardCornerRadius
        textView.isScrollEnabled = false
        textView.delegate = self

        placeholderLabel.text = "发消息..."
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .systemFont(ofSize: 16)

        recordButton.setTitle("按住说话", for: .normal)
        recordButton.titleLabel?.font = .systemFont(ofSize: 16)
        recordButton.backgroundColor = Theme.backgroundTertiary
        recordButton.layer.cornerRadius = Theme.cardCornerRadius
        recordButton.isHidden = true
        recordButton.addTarget(self, action: #selector(recordTouchDown), for: .touchDown)
        recordButton.addTarget(self, action: #selector(recordTouchUp), for: [.touchUpInside, .touchUpOutside])
        recordButton.addTarget(self, action: #selector(recordTouchCancel), for: .touchCancel)

        emojiButton.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        emojiButton.tintColor = Theme.accent
        emojiButton.addTarget(self, action: #selector(emojiTapped), for: .touchUpInside)

        extButton.setImage(UIImage(systemName: "plus.circle"), for: .normal)
        extButton.tintColor = Theme.accent
        extButton.addTarget(self, action: #selector(extTapped), for: .touchUpInside)

        sendButton.setTitle("发送", for: .normal)
        sendButton.tintColor = Theme.accent
        sendButton.isHidden = true
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        for v in [voiceToggleButton, textView, recordButton, emojiButton, extButton, sendButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)

        NSLayoutConstraint.activate([
            voiceToggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            voiceToggleButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            voiceToggleButton.widthAnchor.constraint(equalToConstant: 32),
            voiceToggleButton.heightAnchor.constraint(equalToConstant: 32),

            textView.leadingAnchor.constraint(equalTo: voiceToggleButton.trailingAnchor, constant: 6),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textViewHeightConstraint,

            recordButton.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            recordButton.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            recordButton.topAnchor.constraint(equalTo: textView.topAnchor),
            recordButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 8),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.topAnchor, constant: 18),

            emojiButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 6),
            emojiButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            emojiButton.widthAnchor.constraint(equalToConstant: 32),
            emojiButton.heightAnchor.constraint(equalToConstant: 32),

            extButton.leadingAnchor.constraint(equalTo: emojiButton.trailingAnchor, constant: 4),
            extButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            extButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            extButton.widthAnchor.constraint(equalToConstant: 32),
            extButton.heightAnchor.constraint(equalToConstant: 32),

            sendButton.leadingAnchor.constraint(equalTo: emojiButton.trailingAnchor, constant: 4),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
        ])
    }

    private func setupPanelContainer() {
        panelContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panelContainer)
        panelContainerHeightConstraint = panelContainer.heightAnchor.constraint(equalToConstant: 0)

        // panelContainer sits between the text row and inputBar.bottom.
        // When height = 0: inputBar.height = 8 + textViewHeight + 8 = 52.
        // When height = panelHeight: inputBar.height = 52 + panelHeight.
        // Safe area (home indicator) is handled by ConversationViewController which pins
        // inputBar.bottom to view.safeAreaLayoutGuide.bottomAnchor.
        NSLayoutConstraint.activate([
            panelContainer.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 8),
            panelContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            panelContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            panelContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            panelContainerHeightConstraint,
        ])

        emojiPanel.translatesAutoresizingMaskIntoConstraints = false
        extPanel.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.addSubview(emojiPanel)
        panelContainer.addSubview(extPanel)
        emojiPanel.isHidden = true
        extPanel.isHidden = true

        for panel in [emojiPanel, extPanel] as [UIView] {
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: panelContainer.topAnchor),
                panel.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor),
            ])
        }
    }

    private func wireCallbacks() {
        emojiPanel.onEmojiTapped = { [weak self] emoji in
            self?.textView.insertText(emoji)
        }
        emojiPanel.onDeleteTapped = { [weak self] in
            guard let tv = self?.textView, !tv.text.isEmpty else { return }
            tv.deleteBackward()
            self?.textViewDidChange(tv)
        }
        extPanel.onAlbum = { [weak self] in self?.onPickImage?() }
        extPanel.onCamera = { [weak self] in self?.onCamera?() }
        extPanel.onFile = { [weak self] in self?.onPickFile?() }
    }

    // MARK: - Button Actions
    @objc private func voiceToggleTapped() {
        isVoiceMode.toggle()
        textView.isHidden = isVoiceMode
        recordButton.isHidden = !isVoiceMode
        let icon = isVoiceMode ? "keyboard" : "mic.fill"
        voiceToggleButton.setImage(UIImage(systemName: icon), for: .normal)
        if isVoiceMode {
            textView.resignFirstResponder()
            setPanelState(.none, animated: true)
        }
    }

    @objc private func emojiTapped() {
        setPanelState(panelState == .emoji ? .none : .emoji, animated: true)
        if panelState == .none { textView.becomeFirstResponder() } else { textView.resignFirstResponder() }
    }

    @objc private func extTapped() {
        setPanelState(panelState == .ext ? .none : .ext, animated: true)
        if panelState == .none { textView.becomeFirstResponder() } else { textView.resignFirstResponder() }
    }

    @objc private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSendText?(text, mentionedType, mentionedTargets)
        textView.text = ""
        mentionedType = 0; mentionedTargets = []
        placeholderLabel.isHidden = false
        updateSendExtVisibility()
        updateHeight()
    }

    // MARK: - Voice Recording
    @objc private func recordTouchDown() {
        startRecording()
        recordButton.setTitle("松开发送 (上滑取消)", for: .normal)
    }

    @objc private func recordTouchUp() {
        guard let url = recordingURL else { return }
        let duration = Int(audioRecorder?.currentTime ?? 0)
        stopRecording()
        resetRecordButton()
        guard duration >= 1 else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Save M4A to caches so local playback can bypass AMR decode.
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceMessages")
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let m4aCacheURL = cacheDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: m4aCacheURL)

            let amrData = VoiceConverter.convertToAMR(from: url)
            let data: Data
            let fileName: String
            // Require > 20 bytes to guard against empty AMR containers.
            if let amrData, amrData.count > 20 {
                data = amrData
                fileName = url.deletingPathExtension().appendingPathExtension("amr").lastPathComponent
            } else if let m4aData = try? Data(contentsOf: url) {
                data = m4aData
                fileName = url.lastPathComponent
            } else {
                return
            }
            DispatchQueue.main.async { self?.onSendVoice?(data, duration, fileName, m4aCacheURL) }
        }
    }

    @objc private func recordTouchCancel() {
        stopRecording()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        resetRecordButton()
    }

    private func resetRecordButton() { recordButton.setTitle("按住说话", for: .normal) }

    private func startRecording() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            guard granted else { return }
            DispatchQueue.main.async {
                try? AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
                try? AVAudioSession.sharedInstance().setActive(true)
                let fileName = "voice-\(Int(Date().timeIntervalSince1970)).m4a"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                self.recordingURL = url
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                ]
                self.audioRecorder = try? AVAudioRecorder(url: url, settings: settings)
                self.audioRecorder?.record()
            }
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Panel visibility
    private func setPanelState(_ state: PanelState, animated: Bool) {
        panelState = state
        let newHeight: CGFloat
        switch state {
        case .none: newHeight = 0
        case .emoji: newHeight = EmojiPanelView.panelHeight
        case .ext: newHeight = ExtPanelView.panelHeight
        }
        panelContainerHeightConstraint.constant = newHeight
        emojiPanel.isHidden = state != .emoji
        extPanel.isHidden = state != .ext
        emojiButton.setImage(UIImage(systemName: state == .emoji ? "keyboard" : "face.smiling"), for: .normal)
        if animated {
            UIView.animate(withDuration: 0.25) { self.window?.layoutIfNeeded() }
        }
    }

    private func updateSendExtVisibility() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isHidden = !hasText
        extButton.isHidden = hasText
    }

    private func updateHeight() {
        let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        let capped = min(max(size.height, 36), 120)
        textView.isScrollEnabled = size.height > 120
        textViewHeightConstraint.constant = capped
    }
}

// MARK: - UITextViewDelegate
extension MessageInputBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateSendExtVisibility()
        updateHeight()
        if textView.text.hasSuffix("@") { onMentionTriggered?() }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if panelState != .none { setPanelState(.none, animated: false) }
    }
}
