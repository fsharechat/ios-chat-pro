import UIKit
import IMKit
import AVFoundation

struct VideoBubbleData: Equatable {
    let thumbnail: Data?
    let duration: Int
    let isOutgoing: Bool
    let isUploading: Bool
    let isFailed: Bool
    let senderDisplayName: String?
    let senderAvatarURL: String?
}

final class VideoMessageCell: UITableViewCell {
    static let reuseIdentifier = "VideoMessageCell"

    private let bubbleContainer = UIView()
    private let thumbnailView = UIImageView()
    private let playCircle = UIView()
    private let playIcon = UIImageView(image: UIImage(systemName: "play.fill"))
    private let durationLabel = UILabel()
    private let statusIndicator = MessageStatusIndicatorView()
    private let senderNameLabel = UILabel()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    /// 气泡宽高按原图比例算出后写回这两个约束的 constant（layoutViews 里
    /// 激活一次，之后每次 configure 只改 constant，不重新创建约束）。
    private var bubbleWidthConstraint: NSLayoutConstraint!
    private var bubbleHeightConstraint: NSLayoutConstraint!

    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?
    /// 群聊里长按对方头像 → 会话页在输入框插入 @；自己发的消息不绑定。
    var onAvatarLongPressed: (() -> Void)?

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
        onAvatarLongPressed = nil
        thumbnailView.image = nil
        statusIndicator.apply(.none)
    }

    private func layoutViews() {
        // Thumbnail fills the bubble
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.backgroundColor = Theme.backgroundTertiary

        // Play button circle (semi-transparent black, centered)
        playCircle.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        playCircle.layer.cornerRadius = 22
        playCircle.isUserInteractionEnabled = false
        playCircle.translatesAutoresizingMaskIntoConstraints = false

        playIcon.tintColor = .white
        playIcon.contentMode = .scaleAspectFit
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playCircle.addSubview(playIcon)

        // Duration label (bottom-right)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        durationLabel.layer.cornerRadius = 4
        durationLabel.clipsToBounds = true
        durationLabel.textAlignment = .center
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        statusIndicator.onRetry = { [weak self] in self?.onRetryTapped?() }

        senderAvatarImageView.isUserInteractionEnabled = true
        let avatarPress = UILongPressGestureRecognizer(target: self, action: #selector(avatarLongPressed(_:)))
        // 比表格整行长按菜单手势（默认 0.5s）先识别，长按头像走 @ 而非弹菜单
        avatarPress.minimumPressDuration = 0.4
        senderAvatarImageView.addGestureRecognizer(avatarPress)

        // Bubble container holds thumbnail + overlays
        bubbleContainer.layer.cornerRadius = Theme.bubbleCornerRadius
        bubbleContainer.clipsToBounds = true
        bubbleContainer.isUserInteractionEnabled = true
        bubbleContainer.translatesAutoresizingMaskIntoConstraints = false
        bubbleContainer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        bubbleContainer.addSubview(thumbnailView)
        bubbleContainer.addSubview(playCircle)
        bubbleContainer.addSubview(durationLabel)

        senderNameLabel.font = .systemFont(ofSize: 12)
        senderNameLabel.textColor = Theme.textPrimary.withAlphaComponent(0.6)

        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(senderNameLabel)
        bubbleColumn.addArrangedSubview(bubbleContainer)

        rowStack.axis = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        rowStack.addArrangedSubview(bubbleColumn)

        // 状态指示器不入 stack：直接钉在气泡左侧、垂直居中。
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusIndicator)

        bubbleWidthConstraint = bubbleContainer.widthAnchor.constraint(equalToConstant: ImageBubbleSizing.fallbackSize.width)
        bubbleHeightConstraint = bubbleContainer.heightAnchor.constraint(equalToConstant: ImageBubbleSizing.fallbackSize.height)

        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),

            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            bubbleWidthConstraint,
            bubbleHeightConstraint,

            thumbnailView.topAnchor.constraint(equalTo: bubbleContainer.topAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor),

            playCircle.centerXAnchor.constraint(equalTo: bubbleContainer.centerXAnchor),
            playCircle.centerYAnchor.constraint(equalTo: bubbleContainer.centerYAnchor),
            playCircle.widthAnchor.constraint(equalToConstant: 44),
            playCircle.heightAnchor.constraint(equalToConstant: 44),

            playIcon.centerXAnchor.constraint(equalTo: playCircle.centerXAnchor, constant: 2),
            playIcon.centerYAnchor.constraint(equalTo: playCircle.centerYAnchor),
            playIcon.widthAnchor.constraint(equalToConstant: 20),
            playIcon.heightAnchor.constraint(equalToConstant: 20),

            durationLabel.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -6),
            durationLabel.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -6),
            durationLabel.heightAnchor.constraint(equalToConstant: 20),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            statusIndicator.trailingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: -6),
            statusIndicator.centerYAnchor.constraint(equalTo: bubbleContainer.centerYAnchor),
        ])
    }

    func configure(with data: VideoBubbleData) {
        let thumbnailImage = data.thumbnail.flatMap { UIImage(data: $0) }
        thumbnailView.image = thumbnailImage

        let displaySize = thumbnailImage.map { ImageBubbleSizing.displaySize(forNaturalSize: $0.size) }
            ?? ImageBubbleSizing.fallbackSize
        bubbleWidthConstraint.constant = displaySize.width
        bubbleHeightConstraint.constant = displaySize.height

        durationLabel.text = " \(formatDuration(data.duration)) "
        if data.isOutgoing, data.isUploading {
            statusIndicator.apply(.sending)
        } else if data.isOutgoing, data.isFailed {
            statusIndicator.apply(.failed)
        } else {
            statusIndicator.apply(.none)
        }

        let showsSender = !data.isOutgoing && data.senderDisplayName != nil
        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? data.senderDisplayName : nil

        applyLayout(isOutgoing: data.isOutgoing,
                    avatarURL: data.senderAvatarURL, displayName: data.senderDisplayName ?? "")
    }

    func configurePending(_ pending: PendingVideoUpload) {
        configure(with: VideoBubbleData(
            thumbnail: pending.thumbnail,
            duration: pending.duration,
            isOutgoing: true,
            isUploading: pending.state == .uploading,
            isFailed: pending.state == .failed,
            senderDisplayName: nil,
            senderAvatarURL: nil
        ))
    }

    private func applyLayout(isOutgoing: Bool, avatarURL: String?, displayName: String) {
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        senderAvatarImageView.removeFromSuperview()

        if isOutgoing {
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(senderAvatarImageView)
            senderAvatarImageView.setAvatar(urlString: avatarURL, displayName: "我")
        } else {
            rowStack.addArrangedSubview(senderAvatarImageView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            senderAvatarImageView.setAvatar(urlString: avatarURL, displayName: displayName)
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    @objc private func tapped() { onTapped?() }
    @objc private func avatarLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onAvatarLongPressed?()
    }
}
