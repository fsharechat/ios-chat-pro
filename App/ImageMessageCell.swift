// App/ImageMessageCell.swift
import UIKit
import IMKit

struct ImageBubbleData: Equatable {
    let thumbnail: Data?
    let remoteURL: String?
    let isOutgoing: Bool
    let isUploading: Bool
    let isFailed: Bool
    let senderDisplayName: String?
    let senderAvatarURL: String?

    init(thumbnail: Data?, remoteURL: String? = nil, isOutgoing: Bool, isUploading: Bool, isFailed: Bool, senderDisplayName: String? = nil, senderAvatarURL: String? = nil) {
        self.thumbnail = thumbnail
        self.remoteURL = remoteURL
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
    private let statusIndicator = MessageStatusIndicatorView()
    private let senderNameLabel = UILabel()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()

    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?
    /// 复用竞态防护：异步原图回来时若 cell 已被复用绑定到别的 URL，丢弃结果。
    private var currentRemoteURL: String?
    /// 气泡宽高按原图比例算出后写回这两个约束的 constant（layoutViews 里
    /// 激活一次，之后每次 configure 只改 constant，不重新创建约束）。
    private var bubbleWidthConstraint: NSLayoutConstraint!
    private var bubbleHeightConstraint: NSLayoutConstraint!

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
        statusIndicator.apply(.none)
        currentRemoteURL = nil
    }

    private func layoutViews() {
        bubbleImageView.contentMode = .scaleAspectFill
        bubbleImageView.clipsToBounds = true
        bubbleImageView.layer.cornerRadius = Theme.bubbleCornerRadius
        bubbleImageView.backgroundColor = Theme.backgroundTertiary
        bubbleImageView.isUserInteractionEnabled = true
        bubbleImageView.translatesAutoresizingMaskIntoConstraints = false
        bubbleImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        statusIndicator.onRetry = { [weak self] in self?.onRetryTapped?() }

        senderNameLabel.font = .systemFont(ofSize: 12)
        senderNameLabel.textColor = Theme.textPrimary.withAlphaComponent(0.6)

        // bubbleColumn stacks sender name + image bubble vertically
        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(senderNameLabel)
        bubbleColumn.addArrangedSubview(bubbleImageView)

        rowStack.axis = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        // bubbleColumn must be in the view hierarchy before activating the
        // width constraint that references contentView.
        rowStack.addArrangedSubview(bubbleColumn)

        // 状态指示器不入 stack：直接钉在气泡左侧、垂直居中。
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusIndicator)

        bubbleWidthConstraint = bubbleImageView.widthAnchor.constraint(equalToConstant: ImageBubbleSizing.fallbackSize.width)
        bubbleHeightConstraint = bubbleImageView.heightAnchor.constraint(equalToConstant: ImageBubbleSizing.fallbackSize.height)

        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),

            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            bubbleWidthConstraint,
            bubbleHeightConstraint,

            statusIndicator.trailingAnchor.constraint(equalTo: bubbleImageView.leadingAnchor, constant: -6),
            statusIndicator.centerYAnchor.constraint(equalTo: bubbleImageView.centerYAnchor),
        ])
    }

    func configure(with data: ImageBubbleData) {
        let showsSender = !data.isOutgoing && data.senderDisplayName != nil

        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? data.senderDisplayName : nil

        let thumbnailImage = data.thumbnail.flatMap { UIImage(data: $0) }
        bubbleImageView.image = thumbnailImage
        currentRemoteURL = data.remoteURL

        let displaySize = thumbnailImage.map { ImageBubbleSizing.displaySize(forNaturalSize: $0.size) }
            ?? ImageBubbleSizing.fallbackSize
        bubbleWidthConstraint.constant = displaySize.width
        bubbleHeightConstraint.constant = displaySize.height
        if let remoteURL = data.remoteURL {
            Task { [weak self] in
                guard let original = await ImageLoader.shared.loadImageData(from: remoteURL),
                      let image = UIImage(data: original) else { return }
                guard let self, self.currentRemoteURL == remoteURL else { return }
                UIView.transition(with: self.bubbleImageView, duration: 0.2, options: .transitionCrossDissolve) {
                    self.bubbleImageView.image = image
                }
            }
        }
        if data.isOutgoing, data.isUploading {
            statusIndicator.apply(.sending)
        } else if data.isOutgoing, data.isFailed {
            statusIndicator.apply(.failed)
        } else {
            statusIndicator.apply(.none)
        }

        // Reset rowStack: keep bubbleColumn in the hierarchy.
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        senderAvatarImageView.removeFromSuperview()

        if data.isOutgoing {
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
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
}
