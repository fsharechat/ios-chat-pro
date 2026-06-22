// App/TextMessageCell.swift
import UIKit
import IMKit

final class TextMessageCell: UITableViewCell {
    static let reuseIdentifier = "TextMessageCell"

    private let bubbleView = UIView()
    private let messageTextLabel = UILabel()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader())
    private let senderNameLabel = UILabel()
    private var senderRowTopConstraint: NSLayoutConstraint!
    private var senderAvatarHeightConstraint: NSLayoutConstraint!

    var onRetryTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetryTapped = nil
    }

    private func layoutViews() {
        bubbleView.layer.cornerRadius = Theme.bubbleCornerRadius
        messageTextLabel.numberOfLines = 0
        messageTextLabel.font = .systemFont(ofSize: 16)
        messageTextLabel.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(messageTextLabel)
        NSLayoutConstraint.activate([
            messageTextLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            messageTextLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            messageTextLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            messageTextLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
        ])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel

        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(bubbleView)
        bubbleColumn.addArrangedSubview(statusLabel)

        retryButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        retryButton.tintColor = .systemRed
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)

        senderAvatarImageView.translatesAutoresizingMaskIntoConstraints = false
        senderNameLabel.font = .systemFont(ofSize: 12)
        senderNameLabel.textColor = Theme.textPrimary.withAlphaComponent(0.6)
        senderNameLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(senderAvatarImageView)
        contentView.addSubview(senderNameLabel)

        senderAvatarHeightConstraint = senderAvatarImageView.heightAnchor.constraint(equalToConstant: 28)
        senderRowTopConstraint = senderAvatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4)

        NSLayoutConstraint.activate([
            senderAvatarHeightConstraint,
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 28),
            senderAvatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            senderRowTopConstraint,

            senderNameLabel.leadingAnchor.constraint(equalTo: senderAvatarImageView.trailingAnchor, constant: 6),
            senderNameLabel.centerYAnchor.constraint(equalTo: senderAvatarImageView.centerYAnchor),

            rowStack.topAnchor.constraint(equalTo: senderAvatarImageView.bottomAnchor, constant: 2),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bubbleColumn.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.7),
        ])
    }

    func configure(with row: StoredMessageRow) {
        messageTextLabel.text = row.text

        let showsSender = row.senderDisplayName != nil
        senderAvatarImageView.isHidden = !showsSender
        senderNameLabel.isHidden = !showsSender
        senderRowTopConstraint.constant = showsSender ? 4 : 0
        senderAvatarHeightConstraint.constant = showsSender ? 28 : 0
        if showsSender {
            senderNameLabel.text = row.senderDisplayName
            senderAvatarImageView.setAvatar(urlString: row.senderAvatarURL, displayName: row.senderDisplayName ?? "")
        }

        let isOutgoing = row.isOutgoing
        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.incomingBubble
        messageTextLabel.textColor = isOutgoing ? Theme.textOnAccent : Theme.textPrimary
        bubbleColumn.alignment = isOutgoing ? .trailing : .leading
        statusLabel.textAlignment = isOutgoing ? .right : .left

        switch row.status {
        case .sending: statusLabel.text = "发送中"
        case .sendFailure: statusLabel.text = "发送失败"
        default: statusLabel.text = nil
        }

        rowStack.arrangedSubviews.forEach { rowStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        retryButton.removeFromSuperview()

        if isOutgoing {
            rowStack.addArrangedSubview(spacer)
            if row.status == .sendFailure { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(bubbleColumn)
        } else {
            rowStack.addArrangedSubview(bubbleColumn)
            if row.status == .sendFailure { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(spacer)
        }
    }

    @objc private func retryTapped() { onRetryTapped?() }
}
