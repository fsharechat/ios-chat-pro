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
    private let expandButton = UIButton(type: .system)

    var onRetryTapped: (() -> Void)?
    var onExpandTapped: (() -> Void)?
    /// Kept so a light/dark switch can re-render: markdown attributes (and
    /// the table bitmap especially) bake in colors resolved at configure
    /// time — dynamic colors can't adapt inside a drawn image.
    private var lastConfiguredRow: StoredMessageRow?

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
        onExpandTapped = nil
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

        expandButton.setTitle("查看全文", for: .normal)
        expandButton.titleLabel?.font = .systemFont(ofSize: 13)
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        expandButton.isHidden = true

        // bubbleColumn stacks sender name + bubble + expand + status vertically
        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(senderNameLabel)
        bubbleColumn.addArrangedSubview(bubbleView)
        bubbleColumn.addArrangedSubview(expandButton)
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
            // Bubble may grow until its far edge aligns with where the
            // opposite party's avatar sits: 2×(8pt row inset + 36pt avatar
            // + 8pt gap) = 104pt reserved. Wider than the old 65% cap —
            // gives tables room to render as a real grid.
            bubbleColumn.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -Self.reservedHorizontalSpace),
        ])
    }

    /// 8pt row inset + 36pt avatar + 8pt gap, mirrored on both sides.
    private static let reservedHorizontalSpace: CGFloat = 104
    /// Widest the label content can be: bubble max width minus the bubble's
    /// 12pt+12pt text insets. Used as the markdown table's render width.
    static var maxContentWidth: CGFloat { UIScreen.main.bounds.width - reservedHorizontalSpace - 24 }

    func configure(with row: StoredMessageRow) {
        lastConfiguredRow = row
        let isOutgoing = row.isOutgoing
        // Collapse very long text — a single self-sizing label holding a
        // multi-thousand-character message makes the bubble taller than the
        // GPU's maximum texture size and stalls open/scroll on TextKit
        // layout. Full text remains available via 查看全文/copy/forward.
        let preview = LongTextPreview.preview(for: row.text ?? "")
        // Resolve the dynamic color against this cell's traits *now*: the
        // table renderer bakes it into a bitmap (which can't re-resolve),
        // and the resolved value keys the render cache per appearance.
        let textColor = (isOutgoing ? Theme.textOnAccent : Theme.textPrimary)
            .resolvedColor(with: traitCollection)
        messageTextLabel.attributedText = MarkdownRenderer.render(
            preview.text,
            textColor: textColor,
            availableWidth: Self.maxContentWidth
        )
        expandButton.isHidden = !preview.isTruncated
        let showsSender = !isOutgoing && row.senderDisplayName != nil

        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? row.senderDisplayName : nil

        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.incomingBubble
        // No textColor assignment here: setting UILabel.textColor after
        // attributedText repaints the whole string, clobbering the per-run
        // colors (quote/divider alpha) MarkdownRenderer produced.
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection),
              let row = lastConfiguredRow else { return }
        // Callbacks (onRetryTapped etc.) are untouched — re-running
        // configure only refreshes the appearance-dependent content.
        configure(with: row)
    }

    @objc private func retryTapped() { onRetryTapped?() }
    @objc private func expandTapped() { onExpandTapped?() }
}
