// App/ImageMessageCell.swift
import UIKit
import IMKit

struct ImageBubbleData: Equatable {
    let thumbnail: Data?
    let isOutgoing: Bool
    let isUploading: Bool
    let isFailed: Bool
    let senderDisplayName: String?
    let senderAvatarURL: String?

    init(thumbnail: Data?, isOutgoing: Bool, isUploading: Bool, isFailed: Bool, senderDisplayName: String? = nil, senderAvatarURL: String? = nil) {
        self.thumbnail = thumbnail
        self.isOutgoing = isOutgoing
        self.isUploading = isUploading
        self.isFailed = isFailed
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
    }
}

final class ImageMessageCell: UITableViewCell {
    static let reuseIdentifier = "ImageMessageCell"

    private let bubbleImageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let senderNameLabel = UILabel()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()

    var onTapped: (() -> Void)?
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
        onTapped = nil
        onRetryTapped = nil
        bubbleImageView.image = nil
        activityIndicator.stopAnimating()
    }

    private func layoutViews() {
        bubbleImageView.contentMode = .scaleAspectFill
        bubbleImageView.clipsToBounds = true
        bubbleImageView.layer.cornerRadius = Theme.bubbleCornerRadius
        bubbleImageView.backgroundColor = Theme.backgroundTertiary
        bubbleImageView.isUserInteractionEnabled = true
        bubbleImageView.translatesAutoresizingMaskIntoConstraints = false
        bubbleImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        bubbleImageView.addSubview(activityIndicator)

        retryButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        retryButton.tintColor = .systemRed
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        senderNameLabel.font = .systemFont(ofSize: 12)
        senderNameLabel.textColor = Theme.textPrimary.withAlphaComponent(0.6)

        // bubbleColumn stacks sender name + image bubble vertically
        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(senderNameLabel)
        bubbleColumn.addArrangedSubview(bubbleImageView)

        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        // bubbleColumn must be in the view hierarchy before activating the
        // width constraint that references contentView.
        rowStack.addArrangedSubview(bubbleColumn)

        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),

            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            bubbleImageView.widthAnchor.constraint(equalToConstant: 160),
            bubbleImageView.heightAnchor.constraint(equalToConstant: 160),

            activityIndicator.centerXAnchor.constraint(equalTo: bubbleImageView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: bubbleImageView.centerYAnchor),
        ])
    }

    func configure(with data: ImageBubbleData) {
        let showsSender = !data.isOutgoing && data.senderDisplayName != nil

        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? data.senderDisplayName : nil

        bubbleImageView.image = data.thumbnail.flatMap { UIImage(data: $0) }
        activityIndicator.isHidden = !data.isUploading
        if data.isUploading { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }

        // Reset rowStack: keep bubbleColumn in the hierarchy.
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        retryButton.removeFromSuperview()
        senderAvatarImageView.removeFromSuperview()

        if data.isOutgoing {
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
            if data.isFailed { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(senderAvatarImageView)
            senderAvatarImageView.setAvatar(urlString: data.senderAvatarURL, displayName: "我")
        } else {
            rowStack.addArrangedSubview(senderAvatarImageView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            senderAvatarImageView.setAvatar(
                urlString: data.senderAvatarURL,
                displayName: data.senderDisplayName ?? ""
            )
        }
    }

    @objc private func tapped() { onTapped?() }
    @objc private func retryTapped() { onRetryTapped?() }
}
