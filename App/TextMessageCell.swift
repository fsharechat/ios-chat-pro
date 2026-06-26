// App/TextMessageCell.swift
import UIKit
import IMKit

final class TextMessageCell: UITableViewCell {
    static let reuseIdentifier = "TextMessageCell"

    private let bubbleView = UIView()
    private let messageTextLabel = UILabel()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let senderNameLabel = UILabel()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()

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
        messageTextLabel.numberOfLines = 0
        messageTextLabel.font = .systemFont(ofSize: 16)
        messageTextLabel.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.layer.cornerRadius = Theme.bubbleCornerRadius
        bubbleView.addSubview(messageTextLabel)
        NSLayoutConstraint.activate([
            messageTextLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            messageTextLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            messageTextLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            messageTextLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
        ])

        senderNameLabel.font = .systemFont(ofSize: 12)
        senderNameLabel.textColor = Theme.textPrimary.withAlphaComponent(0.6)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel

        retryButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        retryButton.tintColor = .systemRed
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        // bubbleColumn stacks sender name + bubble + status vertically
        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(senderNameLabel)
        bubbleColumn.addArrangedSubview(bubbleView)
        bubbleColumn.addArrangedSubview(statusLabel)

        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        // bubbleColumn must be in the view hierarchy before the width constraint
        // referencing contentView is activated — they need a common ancestor.
        rowStack.addArrangedSubview(bubbleColumn)

        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubbleColumn.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.65),
        ])
    }

    func configure(with row: StoredMessageRow) {
        messageTextLabel.text = row.text

        let isOutgoing = row.isOutgoing
        let showsSender = !isOutgoing && row.senderDisplayName != nil

        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? row.senderDisplayName : nil

        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.incomingBubble
        messageTextLabel.textColor = isOutgoing ? Theme.textOnAccent : Theme.textPrimary
        bubbleColumn.alignment = isOutgoing ? .trailing : .leading
        statusLabel.textAlignment = isOutgoing ? .right : .left

        switch row.status {
        case .sending: statusLabel.text = "发送中"
        case .sendFailure: statusLabel.text = "发送失败"
        default: statusLabel.text = nil
        }
        statusLabel.isHidden = statusLabel.text == nil

        // Reset rowStack: keep bubbleColumn in the hierarchy (its width
        // constraint to contentView must stay valid); remove everything else.
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        retryButton.removeFromSuperview()
        senderAvatarImageView.removeFromSuperview()

        if isOutgoing {
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
            if row.status == .sendFailure { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(senderAvatarImageView)
            senderAvatarImageView.setAvatar(urlString: row.senderAvatarURL, displayName: "我")
        } else {
            rowStack.addArrangedSubview(senderAvatarImageView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            senderAvatarImageView.setAvatar(
                urlString: row.senderAvatarURL,
                displayName: row.senderDisplayName ?? ""
            )
        }
    }

    @objc private func retryTapped() { onRetryTapped?() }
}
