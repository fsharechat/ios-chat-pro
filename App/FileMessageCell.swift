import UIKit
import IMKit

/// 微信风格文件消息卡片：白色卡片（收发双方一致），左侧 44×44 扩展名
/// 色块图标（带右上折角），右侧文件名两行中间截断 + 「大小 下载状态」。
final class FileMessageCell: UITableViewCell {
    static let reuseIdentifier = "FileMessageCell"

    var onTapped: (() -> Void)?
    /// 群聊里长按对方头像 → 会话页在输入框插入 @；自己发的消息不绑定。
    var onAvatarLongPressed: (() -> Void)?

    private let bubbleView = UIView()
    private let badgeView = UIView()
    private let badgeLabel = UILabel()
    private let foldLayer = CAShapeLayer()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let avatarView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    private var sizeText = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTapped = nil
        onAvatarLongPressed = nil
    }

    private func layoutViews() {
        bubbleView.layer.cornerRadius = 16
        bubbleView.layer.borderWidth = 0.5
        bubbleView.layer.borderColor = Theme.separator.cgColor
        bubbleView.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .white
        }
        bubbleView.isUserInteractionEnabled = true
        bubbleView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bubbleTapped)))

        badgeView.layer.cornerRadius = 8
        badgeView.layer.masksToBounds = true
        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.adjustsFontSizeToFitWidth = true
        badgeLabel.minimumScaleFactor = 0.7
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(badgeLabel)

        let fold = UIBezierPath()
        fold.move(to: CGPoint(x: 30, y: 0))
        fold.addLine(to: CGPoint(x: 44, y: 14))
        fold.addLine(to: CGPoint(x: 44, y: 0))
        fold.close()
        foldLayer.path = fold.cgPath
        foldLayer.fillColor = UIColor(white: 1, alpha: 0.35).cgColor
        badgeView.layer.addSublayer(foldLayer)

        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textColor = Theme.textPrimary

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Theme.textSecondary

        let textStack = UIStackView(arrangedSubviews: [nameLabel, statusLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading

        let hStack = UIStackView(arrangedSubviews: [badgeView, textStack])
        hStack.axis = .horizontal
        hStack.spacing = 10
        hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(hStack)

        NSLayoutConstraint.activate([
            badgeView.widthAnchor.constraint(equalToConstant: 44),
            badgeView.heightAnchor.constraint(equalToConstant: 44),
            badgeLabel.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            badgeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 40),
            hStack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 12),
            hStack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -12),
            hStack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 14),
            hStack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -14),
        ])

        bubbleColumn.axis = .vertical
        bubbleColumn.addArrangedSubview(bubbleView)

        avatarView.isUserInteractionEnabled = true
        let avatarPress = UILongPressGestureRecognizer(target: self, action: #selector(avatarLongPressed(_:)))
        // 比表格整行长按菜单手势（默认 0.5s）先识别，长按头像走 @ 而非弹菜单
        avatarPress.minimumPressDuration = 0.4
        avatarView.addGestureRecognizer(avatarPress)

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        rowStack.addArrangedSubview(bubbleColumn)

        NSLayoutConstraint.activate([
            // 与 TextMessageCell 同款自适应：气泡随内容伸展，封顶为屏宽减去
            // 头像/边距/对侧留白（104pt）
            bubbleColumn.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -104),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    @objc private func bubbleTapped() { onTapped?() }
    @objc private func avatarLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onAvatarLongPressed?()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        bubbleView.layer.borderColor = Theme.separator.cgColor
    }

    func configure(with row: StoredMessageRow, state: FileDownloadState) {
        let name = row.fileName ?? ""
        nameLabel.text = name
        let ext = (name as NSString).pathExtension.lowercased()
        badgeLabel.text = ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4))
        badgeView.backgroundColor = Self.badgeColor(forExtension: ext)
        sizeText = ByteCountFormatter.string(fromByteCount: Int64(row.fileSize ?? 0), countStyle: .file)
        update(state: state)

        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        avatarView.removeFromSuperview()

        if row.isOutgoing {
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(avatarView)
            avatarView.setAvatar(urlString: row.senderAvatarURL, displayName: "我")
        } else {
            rowStack.addArrangedSubview(avatarView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            avatarView.setAvatar(urlString: row.senderAvatarURL, displayName: row.senderDisplayName ?? "")
        }
    }

    func update(state: FileDownloadState) {
        switch state {
        case .notDownloaded:
            statusLabel.text = "\(sizeText) 未下载"
        case .downloading(let progress):
            statusLabel.text = "下载中 \(Int(progress * 100))%"
        case .downloaded:
            statusLabel.text = "\(sizeText) 已下载"
        }
    }

    private static func badgeColor(forExtension ext: String) -> UIColor {
        switch ext {
        case "pdf": return UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 1)
        case "doc", "docx", "pages": return UIColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1)
        case "xls", "xlsx", "csv", "numbers": return UIColor(red: 0.13, green: 0.66, blue: 0.42, alpha: 1)
        case "ppt", "pptx", "key": return UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        case "zip", "rar", "7z", "tar", "gz": return UIColor(red: 0.55, green: 0.50, blue: 0.75, alpha: 1)
        case "txt", "md", "rtf": return UIColor(red: 0.45, green: 0.55, blue: 0.62, alpha: 1)
        case "exe", "msi", "dmg", "pkg", "apk", "ipa": return UIColor(red: 0.20, green: 0.60, blue: 0.65, alpha: 1)
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp": return UIColor(red: 0.90, green: 0.42, blue: 0.60, alpha: 1)
        case "mp3", "wav", "m4a", "flac", "aac", "amr": return UIColor(red: 0.42, green: 0.44, blue: 0.88, alpha: 1)
        case "mp4", "mov", "mkv", "avi", "wmv", "flv": return UIColor(red: 0.62, green: 0.40, blue: 0.90, alpha: 1)
        default: return UIColor(red: 0.60, green: 0.63, blue: 0.68, alpha: 1)
        }
    }
}
