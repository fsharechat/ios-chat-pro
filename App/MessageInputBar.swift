import UIKit
import IMKit

final class MessageInputBar: UIView {
    var onSendText: ((_ text: String, _ mentionedType: Int32, _ mentionedTargets: [String]) -> Void)?
    var onPickImage: (() -> Void)?
    var onCamera: (() -> Void)?
    var onPickFile: (() -> Void)?
    var onPickLocation: (() -> Void)?
    var onAudioCall: (() -> Void)?
    var onVideoCall: (() -> Void)?
    var onSendVoice: ((_ audioData: Data, _ duration: Int, _ fileName: String, _ localM4AURL: URL?) -> Void)?
    var onMentionTriggered: (() -> Void)?

    private var state = ComposerState()
    private let glass = ComposerGlassBackgroundView()
    private let plusGlass = ComposerGlassBackgroundView()
    private let dock = UIView()
    private let editingHost = UIView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let recordButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    private let voiceRow = UIStackView()
    private let emojiButton = UIButton(type: .system)
    private let extButton = UIButton(type: .system)
    private let voiceButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let sendCircle = UIView()
    private let tailHost = UIView()
    private var editorHeight: NSLayoutConstraint!
    private var placeholderCenterY: NSLayoutConstraint!
    private let panelContainer = UIView()
    private var panelHeight: NSLayoutConstraint!
    private let emojiPanel = EmojiPanelView()
    private let extPanel = ExtPanelView()
    private let recording = VoiceRecordingController()
    private let noticeLabel = UILabel()
    private var noticeTask: DispatchWorkItem?
    private var keyboardHeight: CGFloat = 0
    private var lastKeyboardHeight: CGFloat = 260
    private var keyboardReservation: CGFloat = 0
    private var transitionID = 0
    private var justTypedMention = false
    private var recordStartY: CGFloat = 0
    private var lastEditorWidth: CGFloat = 0
    private var isLayingOut = false

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: Theme.textPrimary]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupInputRow()
        setupPanelContainer()
        wireCallbacks()
        NotificationCenter.default.addObserver(self, selector: #selector(contentSizeChanged),
            name: UIContentSizeCategory.didChangeNotification, object: nil)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var showsCallItems: Bool {
        get { extPanel.showsCallItems }
        set { extPanel.showsCallItems = newValue }
    }

    // Mention metadata lives on text ranges, so cursor edits and selection replacement stay in sync.
    func insertMention(uid: String?, displayName: String) {
        if state.mode == .voice {
            recording.finish(cancelled: true)
            state.show(.keyboard)
            state.collapse()
        }
        var attributes = textAttributes
        attributes[ComposerMentions.attributeKey] = ComposerMentions.Reference(uid: uid)
        let mention = NSAttributedString(string: "@\(displayName) ", attributes: attributes)
        let range = textView.selectedRange
        textView.textStorage.replaceCharacters(in: range, with: mention)
        textView.selectedRange = NSRange(location: range.location + mention.length, length: 0)
        textView.typingAttributes = textAttributes
        textViewDidChange(textView)
    }

    func removeTrailingMentionTrigger() {
        let position = textView.selectedRange.location
        let text = textView.text as NSString
        guard position > 0, position <= text.length, text.substring(with: NSRange(location: position - 1, length: 1)) == "@" else { return }
        textView.textStorage.deleteCharacters(in: NSRange(location: position - 1, length: 1))
        textView.selectedRange = NSRange(location: position - 1, length: 0)
        textViewDidChange(textView)
    }

    func collapseInput() {
        recording.finish(cancelled: true)
        state.collapse()
        keyboardReservation = 0
        textView.resignFirstResponder()
        render(animated: true)
    }

    /// Called when leaving the page. Submitted conversions cannot deliver into another conversation.
    func cancelRecording() { recording.cancelAll() }

    /// A single spacer hosts either IME or a custom panel, never the sum of their heights.
    func updateKeyboard(height: CGFloat) {
        if height > 0, keyboardHeight == 0, !textView.isFirstResponder { return }
        keyboardHeight = max(0, height)
        if height > 0 {
            lastKeyboardHeight = height
            keyboardReservation = 0
        } else if state.surface == .keyboard, !textView.isFirstResponder {
            state.collapse()
        }
        render()
    }

    private func setupInputRow() {
        addSubview(dock)
        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.addSubview(plusGlass)
        dock.addSubview(glass)
        dock.addSubview(extButton)
        let stack = UIStackView(arrangedSubviews: [editingHost, emojiButton, tailHost])
        stack.spacing = 0
        glass.isUserInteractionEnabled = true
        glass.addSubview(stack)
        editingHost.addSubview(textView)
        editingHost.addSubview(voiceRow)
        voiceRow.axis = .horizontal
        voiceRow.addArrangedSubview(keyboardButton)
        voiceRow.addArrangedSubview(recordButton)
        tailHost.addSubview(sendCircle)
        tailHost.addSubview(voiceButton)
        tailHost.addSubview(sendButton)
        for v in [plusGlass, glass, extButton, stack, textView, voiceRow, keyboardButton,
                  emojiButton, tailHost, voiceButton, sendButton, sendCircle] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = Theme.textPrimary
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = "消息输入框"
        textView.returnKeyType = .default
        textView.typingAttributes = textAttributes
        placeholderLabel.text = "发消息…"
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)

        configureButton(extButton, symbol: "plus", label: "更多功能", action: #selector(extTapped))
        configureButton(emojiButton, symbol: "face.smiling", label: "表情", action: #selector(emojiTapped))
        configureButton(voiceButton, symbol: "waveform", label: "语音输入", action: #selector(voiceTapped))
        // Waveform has a larger visual footprint than the face at the same point size.
        let voiceSymbol = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        voiceButton.setImage(UIImage(systemName: "waveform", withConfiguration: voiceSymbol), for: .normal)
        voiceButton.setPreferredSymbolConfiguration(voiceSymbol, forImageIn: .normal)
        voiceButton.imageView?.contentMode = .center
        voiceButton.accessibilityHint = "切换到按住说话，发送语音消息"
        configureButton(keyboardButton, symbol: "keyboard", label: "键盘输入", action: #selector(keyboardTapped))
        // The keyboard symbol is wider than the face symbol at the same point size.
        let keyboardSymbol = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        keyboardButton.setImage(UIImage(systemName: "keyboard", withConfiguration: keyboardSymbol), for: .normal)
        keyboardButton.setPreferredSymbolConfiguration(keyboardSymbol, forImageIn: .normal)
        keyboardButton.imageView?.contentMode = .center
        configureButton(sendButton, symbol: "arrow.up", label: "发送", action: #selector(sendTapped))
        let sendSymbol = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: sendSymbol), for: .normal)
        sendButton.setPreferredSymbolConfiguration(sendSymbol, forImageIn: .normal)
        sendButton.imageView?.contentMode = .center
        sendButton.tintColor = Theme.textOnAccent
        sendCircle.backgroundColor = Theme.accent
        sendCircle.layer.cornerRadius = 18
        sendCircle.isUserInteractionEnabled = false
        recordButton.setTitle("按住说话", for: .normal)
        recordButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        recordButton.titleLabel?.adjustsFontForContentSizeCategory = true
        recordButton.titleLabel?.numberOfLines = 2
        recordButton.titleLabel?.textAlignment = .center
        recordButton.setTitleColor(Theme.textPrimary, for: .normal)
        recordButton.accessibilityLabel = "按住说话"
        recordButton.accessibilityHint = "按住录音，松开发送，上滑取消；也可使用辅助操作开始和停止"
        recordButton.addTarget(self, action: #selector(recordDown(_:event:)), for: .touchDown)
        recordButton.addTarget(self, action: #selector(recordMoved(_:event:)), for: [.touchDragInside, .touchDragOutside])
        recordButton.addTarget(self, action: #selector(recordUp), for: [.touchUpInside, .touchUpOutside])
        recordButton.addTarget(self, action: #selector(recordCancel), for: .touchCancel)
        recordButton.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "开始录音", target: self, selector: #selector(accessibleRecordStart)),
            UIAccessibilityCustomAction(name: "停止并发送", target: self, selector: #selector(accessibleRecordSend)),
            UIAccessibilityCustomAction(name: "取消录音", target: self, selector: #selector(accessibleRecordCancel))
        ]
        let tailWidth = tailHost.widthAnchor.constraint(equalToConstant: 44)
        tailWidth.priority = UILayoutPriority(999)
        editorHeight = textView.heightAnchor.constraint(equalToConstant: 44)
        placeholderCenterY = placeholderLabel.centerYAnchor.constraint(equalTo: textView.topAnchor, constant: 22)
        NSLayoutConstraint.activate([
            dock.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            dock.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dock.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            glass.topAnchor.constraint(equalTo: dock.topAnchor),
            glass.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: extButton.trailingAnchor, constant: 8),
            glass.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
            extButton.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
            extButton.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
            extButton.widthAnchor.constraint(equalToConstant: 48),
            extButton.heightAnchor.constraint(equalToConstant: 48),
            plusGlass.leadingAnchor.constraint(equalTo: extButton.leadingAnchor),
            plusGlass.trailingAnchor.constraint(equalTo: extButton.trailingAnchor),
            plusGlass.topAnchor.constraint(equalTo: extButton.topAnchor),
            plusGlass.bottomAnchor.constraint(equalTo: extButton.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: glass.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -4),
            textView.leadingAnchor.constraint(equalTo: editingHost.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: editingHost.trailingAnchor),
            textView.topAnchor.constraint(equalTo: editingHost.topAnchor),
            textView.bottomAnchor.constraint(equalTo: editingHost.bottomAnchor), editorHeight,
            voiceRow.leadingAnchor.constraint(equalTo: editingHost.leadingAnchor),
            voiceRow.trailingAnchor.constraint(equalTo: editingHost.trailingAnchor),
            voiceRow.topAnchor.constraint(equalTo: editingHost.topAnchor),
            voiceRow.bottomAnchor.constraint(equalTo: editingHost.bottomAnchor),
            keyboardButton.widthAnchor.constraint(equalToConstant: 44),
            emojiButton.widthAnchor.constraint(equalToConstant: 44),
            tailWidth,
            sendCircle.widthAnchor.constraint(equalToConstant: 36),
            sendCircle.heightAnchor.constraint(equalToConstant: 36),
            sendCircle.centerXAnchor.constraint(equalTo: tailHost.centerXAnchor),
            sendCircle.bottomAnchor.constraint(equalTo: tailHost.bottomAnchor, constant: -4),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 4),
            placeholderCenterY
        ])
        for button in [voiceButton, sendButton] {
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: tailHost.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: tailHost.trailingAnchor),
                button.bottomAnchor.constraint(equalTo: tailHost.bottomAnchor),
                button.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
        // Keep the emoji aligned with the bottom line as the text grows upwards.
        emojiButton.contentVerticalAlignment = .bottom
        emojiButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 11, right: 0)
        plusGlass.cornerRadius = 24
        noticeLabel.textAlignment = .center
        noticeLabel.font = .preferredFont(forTextStyle: .footnote)
        noticeLabel.numberOfLines = 0
        noticeLabel.backgroundColor = Theme.popupCard
        noticeLabel.textColor = Theme.textPrimary
        noticeLabel.layer.cornerRadius = 12
        noticeLabel.clipsToBounds = true
        noticeLabel.isHidden = true
        noticeLabel.isUserInteractionEnabled = false
        addSubview(noticeLabel)
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noticeLabel.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -8),
            noticeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            noticeLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            noticeLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
    }

    private func configureButton(_ button: UIButton, symbol: String, label: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)), for: .normal)
        button.tintColor = Theme.textPrimary
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func setupPanelContainer() {
        panelContainer.clipsToBounds = true
        panelContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panelContainer)
        panelHeight = panelContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            panelContainer.topAnchor.constraint(equalTo: dock.bottomAnchor, constant: 8),
            panelContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            panelContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            panelContainer.bottomAnchor.constraint(equalTo: bottomAnchor), panelHeight
        ])
        for panel in [emojiPanel, extPanel] as [UIView] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            panelContainer.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
                panel.topAnchor.constraint(equalTo: panelContainer.topAnchor),
                panel.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor)
            ])
        }
    }

    private func wireCallbacks() {
        emojiPanel.onEmojiTapped = { [weak self] emoji in self?.textView.insertText(emoji) }
        emojiPanel.onDeleteTapped = { [weak self] in self?.textView.deleteBackward() }
        // Keep MORE in state while an external picker is presented. Its return restores the panel,
        // with no keyboard resurrection and with the same text view/selection/mention attributes.
        extPanel.onAlbum = { [weak self] in self?.onPickImage?() }
        extPanel.onCamera = { [weak self] in self?.onCamera?() }
        extPanel.onFile = { [weak self] in self?.onPickFile?() }
        extPanel.onLocation = { [weak self] in self?.onPickLocation?() }
        extPanel.onAudioCall = { [weak self] in
            self?.collapseInput(); self?.onAudioCall?()
        }
        extPanel.onVideoCall = { [weak self] in
            self?.collapseInput(); self?.onVideoCall?()
        }
        extPanel.onVoiceMessage = { [weak self] in self?.voiceTapped() }
        recording.onSend = { [weak self] data, duration, name, url in self?.onSendVoice?(data, duration, name, url) }
        recording.onNotice = { [weak self] in self?.showNotice($0) }
        recording.onUpdate = { [weak self] title, active in
            guard let self else { return }
            self.recordButton.setTitle(title, for: .normal)
            self.recordButton.accessibilityValue = active ? title : nil
            self.extButton.isEnabled = !active
            self.emojiButton.isEnabled = !active
            self.keyboardButton.isEnabled = !active
        }
    }

    private func render(animated: Bool = false) {
        let voice = state.mode == .voice
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        textView.isHidden = voice
        voiceRow.isHidden = !voice
        tailHost.isHidden = voice
        sendButton.isHidden = !hasText
        sendCircle.isHidden = !hasText
        voiceButton.isHidden = hasText
        placeholderLabel.isHidden = !textView.text.isEmpty
        extButton.setImage(UIImage(systemName: state.surface == .more ? "xmark" : "plus"), for: .normal)
        extButton.accessibilityLabel = state.surface == .more ? "收起更多" : "更多功能"
        emojiButton.setImage(UIImage(systemName: state.surface == .emoji ? "keyboard" : "face.smiling"), for: .normal)
        emojiButton.accessibilityLabel = state.surface == .emoji ? "键盘输入" : "表情"
        emojiPanel.isHidden = state.surface != .emoji || keyboardHeight > 0
        extPanel.isHidden = state.surface != .more || keyboardHeight > 0
        let maximum = max(120, (window?.bounds.height ?? 600) * 0.45)
        let custom: CGFloat = (state.surface == .emoji || state.surface == .more) ? min(max(lastKeyboardHeight, 220), maximum) : 0
        panelHeight.constant = CGFloat(ComposerState.occupiedHeight(keyboard: Double(keyboardHeight), panel: Double(max(custom, keyboardReservation))))
        updateHeight()
        setNeedsLayout()
        if animated, let host = superview {
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { host.layoutIfNeeded() }
        }
    }

    private func showKeyboard() {
        transitionID += 1
        let id = transitionID
        keyboardReservation = panelHeight.constant
        state.show(.keyboard)
        render()
        textView.becomeFirstResponder()
        // Hardware keyboards may not deliver an IME frame notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.transitionID == id, self.state.surface == .keyboard else { return }
            self.keyboardReservation = 0
            self.render(animated: true)
        }
    }

    @objc private func voiceTapped() {
        state.enterVoice()
        keyboardReservation = 0
        transitionID += 1
        textView.resignFirstResponder()
        render(animated: true)
    }

    @objc private func keyboardTapped() { showKeyboard() }

    @objc private func emojiTapped() {
        guard !recording.isRecording else { return }
        if state.surface == .emoji { showKeyboard(); return }
        transitionID += 1
        keyboardReservation = 0
        state.show(.emoji)
        textView.resignFirstResponder()
        render(animated: true)
    }

    @objc private func extTapped() {
        guard !recording.isRecording else { return }
        transitionID += 1
        keyboardReservation = 0
        if state.surface == .more { collapseInput(); return }
        state.show(.more)
        textView.resignFirstResponder()
        render(animated: true)
    }

    @objc private func sendTapped() {
        guard textView.markedTextRange == nil else { return }
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let recipients = ComposerMentions.recipients(in: textView.textStorage)
        onSendText?(text, recipients.type, recipients.targets)
        textView.text = ""
        textView.typingAttributes = textAttributes
        render(animated: true)
    }

    @objc private func recordDown(_ sender: UIButton, event: UIEvent) {
        recordStartY = event.touches(for: sender)?.first?.location(in: self).y ?? 0
        recording.begin()
    }

    @objc private func recordMoved(_ sender: UIButton, event: UIEvent) {
        guard let touch = event.touches(for: sender)?.first else { return }
        recording.move(upwardDistance: recordStartY - touch.location(in: self).y)
    }

    @objc private func recordUp() { recording.finish(cancelled: false) }
    @objc private func recordCancel() { recording.finish(cancelled: true) }
    @objc private func accessibleRecordStart() -> Bool { recording.begin(); return true }
    @objc private func accessibleRecordSend() -> Bool { recording.finish(cancelled: false); return true }
    @objc private func accessibleRecordCancel() -> Bool { recording.finish(cancelled: true); return true }

    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        noticeLabel.text = "  \(text)  "
        noticeLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
        let task = DispatchWorkItem { [weak self] in self?.noticeLabel.isHidden = true }
        noticeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    @objc private func contentSizeChanged() {
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        textView.textStorage.addAttributes(textAttributes, range: NSRange(location: 0, length: textView.textStorage.length))
        textView.typingAttributes = textAttributes
        render()
    }

    private func updateHeight() {
        guard editorHeight != nil else { return }
        let font = UIFont.preferredFont(forTextStyle: .body)
        let size = textView.sizeThatFits(CGSize(width: max(textView.bounds.width, 50), height: .greatestFiniteMagnitude))
        // Measure the text independently of the previous centering padding so height cannot drift
        // when a one-line draft wraps, shrinks again, or changes Dynamic Type size.
        let textHeight = max(font.lineHeight, size.height - textView.textContainerInset.top - textView.textContainerInset.bottom)
        let maximum = min(max(120, font.lineHeight * 5 + 20), (window?.bounds.height ?? 600) * 0.3)
        let height = state.mode == .voice ? max(44, UIFont.preferredFont(forTextStyle: .subheadline).lineHeight * 2 + 8) : min(max(ceil(textHeight) + 20, 44), maximum)
        let verticalPadding = max(10, (height - textHeight) / 2)
        let insets = UIEdgeInsets(top: verticalPadding, left: 4, bottom: verticalPadding, right: 0)
        if textView.textContainerInset != insets { textView.textContainerInset = insets }
        placeholderCenterY.constant = height / 2
        textView.isScrollEnabled = textHeight + 20 > maximum && state.mode == .text
        if abs(editorHeight.constant - height) > 0.5 { editorHeight.constant = height }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        if abs(lastEditorWidth - textView.bounds.width) > 0.5 {
            lastEditorWidth = textView.bounds.width
            render()
        }
    }

    // Transparent gaps and the keyboard spacer must not eat message-list touches.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        for child in [panelContainer, dock] where !child.isHidden {
            let converted = child.convert(point, from: self)
            guard child.bounds.contains(converted) else { continue }
            if child === dock {
                for control in [extButton, glass] {
                    let local = control.convert(point, from: self)
                    let radius: CGFloat = control === extButton ? 24 : 26
                    guard UIBezierPath(roundedRect: control.bounds, cornerRadius: radius).contains(local) else { continue }
                    if let hit = control.hitTest(local, with: event) { return hit }
                }
            } else if state.surface == .emoji || state.surface == .more {
                return child.hitTest(converted, with: event)
            }
        }
        return nil
    }
}

extension MessageInputBar: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        justTypedMention = text == "@"
        let expanded = ComposerMentions.expandedRange(for: range, in: textView.textStorage)
        guard expanded != range else { return true }
        textView.textStorage.replaceCharacters(in: expanded, with: NSAttributedString(string: text, attributes: textAttributes))
        textView.selectedRange = NSRange(location: expanded.location + (text as NSString).length, length: 0)
        textViewDidChange(textView)
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        textView.typingAttributes = textAttributes
        render(animated: true)
        if justTypedMention { onMentionTriggered?() }
        justTypedMention = false
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView.markedTextRange == nil { textView.typingAttributes = textAttributes }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if state.surface != .keyboard { showKeyboard() }
    }
}
