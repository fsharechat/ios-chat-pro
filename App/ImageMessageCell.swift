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
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader())
    private let senderNameLabel = UILabel()

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
        retryButton.isHidden = true
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

        bubbleColumn.axis = .vertical
        bubbleColumn.addArrangedSubview(bubbleImageView)

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

        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 28),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 28),
            senderAvatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            senderAvatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),

            senderNameLabel.leadingAnchor.constraint(equalTo: senderAvatarImageView.trailingAnchor, constant: 6),
            senderNameLabel.centerYAnchor.constraint(equalTo: senderAvatarImageView.centerYAnchor),

            rowStack.topAnchor.constraint(equalTo: senderAvatarImageView.bottomAnchor, constant: 2),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            bubbleImageView.widthAnchor.constraint(equalToConstant: 160),
            bubbleImageView.heightAnchor.constraint(equalToConstant: 160),

            activityIndicator.centerXAnchor.constraint(equalTo: bubbleImageView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: bubbleImageView.centerYAnchor),
        ])
    }

    func configure(with data: ImageBubbleData) {
        let showsSender = data.senderDisplayName != nil
        senderAvatarImageView.isHidden = !showsSender
        senderNameLabel.isHidden = !showsSender
        if showsSender {
            senderNameLabel.text = data.senderDisplayName
            senderAvatarImageView.setAvatar(urlString: data.senderAvatarURL, displayName: data.senderDisplayName ?? "")
        }

        bubbleImageView.image = data.thumbnail.flatMap { UIImage(data: $0) }
        activityIndicator.isHidden = !data.isUploading
        if data.isUploading { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        retryButton.isHidden = !data.isFailed

        rowStack.arrangedSubviews.forEach { rowStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        retryButton.removeFromSuperview()

        if data.isOutgoing {
            rowStack.addArrangedSubview(spacer)
            if data.isFailed { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(bubbleColumn)
        } else {
            rowStack.addArrangedSubview(bubbleColumn)
            if data.isFailed { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(spacer)
        }
    }

    @objc private func tapped() { onTapped?() }
    @objc private func retryTapped() { onRetryTapped?() }
}
