import UIKit

final class MessageInputBar: UIView {
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let imageButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private var textViewHeightConstraint: NSLayoutConstraint!

    private var mentionedType: Int32 = 0
    private var mentionedTargets: [String] = []

    var onSendText: ((_ text: String, _ mentionedType: Int32, _ mentionedTargets: [String]) -> Void)?
    var onPickImage: (() -> Void)?
    /// Fired the moment the user types a trailing "@" — the app presents a
    /// member picker and calls `insertMention(uid:displayName:)` with the
    /// result.
    var onMentionTriggered: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        imageButton.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        imageButton.tintColor = Theme.accent
        imageButton.addTarget(self, action: #selector(imageTapped), for: .touchUpInside)
        imageButton.translatesAutoresizingMaskIntoConstraints = false

        textView.font = .systemFont(ofSize: 16)
        textView.backgroundColor = Theme.backgroundTertiary
        textView.layer.cornerRadius = Theme.cardCornerRadius
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.text = "发消息..."
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        sendButton.setTitle("发送", for: .normal)
        sendButton.tintColor = Theme.accent
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageButton)
        addSubview(textView)
        textView.addSubview(placeholderLabel)
        addSubview(sendButton)

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)

        NSLayoutConstraint.activate([
            imageButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            imageButton.widthAnchor.constraint(equalToConstant: 28),
            imageButton.heightAnchor.constraint(equalToConstant: 28),

            textView.leadingAnchor.constraint(equalTo: imageButton.trailingAnchor, constant: 8),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            textViewHeightConstraint,

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 8),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.topAnchor, constant: 18),

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
        ])
    }

    /// Called by the host view controller once the user picks a member (or
    /// "所有人") from the mention picker presented in response to
    /// `onMentionTriggered`. `uid == nil` means "mention all".
    func insertMention(uid: String?, displayName: String) {
        textView.text += "@\(displayName) "
        if let uid {
            if mentionedType != 2 {
                mentionedType = 1
                mentionedTargets.append(uid)
            }
        } else {
            mentionedType = 2
            mentionedTargets = []
        }
        textViewDidChange(textView)
    }

    /// Called by the host view controller when the mention picker is
    /// dismissed via cancel (not a selection) — strips the trailing "@"
    /// that triggered the picker so it doesn't dangle unresolved in the
    /// composer, and so `textViewDidChange` doesn't re-trigger the picker
    /// on a later edit that happens to end in "@" again.
    func removeTrailingMentionTrigger() {
        guard textView.text.hasSuffix("@") else { return }
        textView.text.removeLast()
        textViewDidChange(textView)
    }

    @objc private func imageTapped() { onPickImage?() }

    @objc private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSendText?(text, mentionedType, mentionedTargets)
        textView.text = ""
        mentionedType = 0
        mentionedTargets = []
        placeholderLabel.isHidden = false
        updateHeight()
    }

    private func updateHeight() {
        let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        let cappedHeight = min(max(size.height, 36), 120)
        textView.isScrollEnabled = size.height > 120
        textViewHeightConstraint.constant = cappedHeight
    }
}

extension MessageInputBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateHeight()
        if textView.text.hasSuffix("@") {
            onMentionTriggered?()
        }
    }
}
