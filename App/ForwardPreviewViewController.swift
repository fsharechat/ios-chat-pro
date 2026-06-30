// App/ForwardPreviewViewController.swift
import UIKit
import IMKit

final class ForwardPreviewViewController: UIViewController {
    private let targetRow: ConversationRow
    private let sourceMessage: StoredMessageRow

    /// Called when the user taps "发送". Argument is the optional 留言 text.
    var onSend: ((String?) -> Void)?

    private let recipientLabel = UILabel()
    private let avatarImageView = AvatarImageView(loader: AvatarLoader.shared)
    private let previewContainer = UIView()
    private let noteField = UITextField()

    init(targetRow: ConversationRow, sourceMessage: StoredMessageRow) {
        self.targetRow = targetRow
        self.sourceMessage = sourceMessage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        configureContent()
    }

    private func layoutViews() {
        // Header: recipient info
        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .center

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 44),
            avatarImageView.heightAnchor.constraint(equalToConstant: 44),
        ])

        let sendToLabel = UILabel()
        sendToLabel.text = "发送给："
        sendToLabel.font = .systemFont(ofSize: 15)
        sendToLabel.textColor = Theme.textPrimary

        recipientLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        recipientLabel.textColor = Theme.textPrimary

        headerStack.addArrangedSubview(sendToLabel)
        headerStack.addArrangedSubview(avatarImageView)
        headerStack.addArrangedSubview(recipientLabel)
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        // Preview area
        previewContainer.backgroundColor = Theme.backgroundSecondary
        previewContainer.layer.cornerRadius = 8
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        // Note field
        noteField.placeholder = "给朋友留言"
        noteField.font = .systemFont(ofSize: 15)
        noteField.borderStyle = .none
        noteField.translatesAutoresizingMaskIntoConstraints = false

        let separator = UIView()
        separator.backgroundColor = Theme.backgroundTertiary
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Buttons
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let sendButton = UIButton(type: .system)
        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [cancelButton, sendButton])
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonSeparator = UIView()
        buttonSeparator.backgroundColor = Theme.backgroundTertiary
        buttonSeparator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerStack)
        view.addSubview(previewContainer)
        view.addSubview(noteField)
        view.addSubview(separator)
        view.addSubview(buttonSeparator)
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            previewContainer.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 16),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            noteField.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 16),
            noteField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            noteField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            noteField.heightAnchor.constraint(equalToConstant: 44),

            separator.topAnchor.constraint(equalTo: noteField.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            buttonSeparator.bottomAnchor.constraint(equalTo: buttonStack.topAnchor),
            buttonSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            buttonSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttonSeparator.heightAnchor.constraint(equalToConstant: 0.5),

            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttonStack.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    private func configureContent() {
        recipientLabel.text = targetRow.displayName
        avatarImageView.setAvatar(urlString: targetRow.avatarURL, displayName: targetRow.displayName)
        addPreviewContent()
    }

    private func addPreviewContent() {
        let msg = sourceMessage
        if let thumbnail = msg.imageThumbnail {
            let imageView = UIImageView(image: UIImage(data: thumbnail))
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
                imageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8),
                imageView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
                imageView.heightAnchor.constraint(equalToConstant: 120),
                imageView.widthAnchor.constraint(lessThanOrEqualTo: previewContainer.widthAnchor, constant: -16),
            ])
        } else {
            let previewText: String
            if msg.voiceDuration != nil { previewText = "🎤 语音消息" }
            else if let name = msg.fileName { previewText = "📄 \(name)" }
            else if msg.locationLat != nil { previewText = "📍 \(msg.text ?? "位置")" }
            else { previewText = msg.text.map { String($0.prefix(50)) } ?? "" }

            let label = UILabel()
            label.text = previewText
            label.font = .systemFont(ofSize: 14)
            label.textColor = Theme.textPrimary
            label.numberOfLines = 2
            label.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -12),
                label.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -12),
            ])
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func sendTapped() {
        let note = noteField.text?.trimmingCharacters(in: .whitespaces)
        dismiss(animated: true) { [weak self] in
            self?.onSend?(note?.isEmpty == false ? note : nil)
        }
    }
}
