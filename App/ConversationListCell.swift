// App/ConversationListCell.swift
import UIKit
import IMKit

final class ConversationListCell: UITableViewCell {
    static let reuseIdentifier = "ConversationListCell"

    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()
    private let timestampLabel = UILabel()
    private let previewLabel = UILabel()
    private let unreadBadge = UILabel()
    private let muteIcon = UIImageView(image: UIImage(systemName: "bell.slash.fill"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = Theme.textPrimary

        timestampLabel.font = .systemFont(ofSize: 12, weight: .regular)
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.setContentHuggingPriority(.required, for: .horizontal)

        previewLabel.font = .systemFont(ofSize: 14, weight: .regular)
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 1

        unreadBadge.font = .systemFont(ofSize: 12, weight: .semibold)
        unreadBadge.textColor = Theme.textOnAccent
        unreadBadge.backgroundColor = Theme.accent
        unreadBadge.textAlignment = .center
        unreadBadge.layer.cornerRadius = 9
        unreadBadge.clipsToBounds = true
        unreadBadge.setContentHuggingPriority(.required, for: .horizontal)

        muteIcon.tintColor = .secondaryLabel
        muteIcon.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = UIStackView(arrangedSubviews: [nameLabel, timestampLabel])
        topRow.axis = .horizontal
        topRow.spacing = Theme.standardSpacing

        let bottomRow = UIStackView(arrangedSubviews: [previewLabel, muteIcon, unreadBadge])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 6
        bottomRow.alignment = .center

        let textStack = UIStackView(arrangedSubviews: [topRow, bottomRow])
        textStack.axis = .vertical
        textStack.spacing = 4

        let rowStack = UIStackView(arrangedSubviews: [avatarImageView, textStack])
        rowStack.axis = .horizontal
        rowStack.spacing = Theme.standardSpacing
        rowStack.alignment = .center
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 48),
            avatarImageView.heightAnchor.constraint(equalToConstant: 48),
            unreadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            unreadBadge.heightAnchor.constraint(equalToConstant: 18),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(with row: ConversationRow) {
        avatarImageView.setAvatar(urlString: row.avatarURL, displayName: row.displayName)
        nameLabel.text = row.displayName
        timestampLabel.text = Self.formattedTimestamp(row.timestamp)

        switch row.lastMessageStatus {
        case .sending:
            previewLabel.text = "发送中... " + row.previewText
        case .sendFailure:
            previewLabel.text = "发送失败 " + row.previewText
        default:
            previewLabel.text = row.previewText
        }

        muteIcon.isHidden = !row.isMuted
        if row.unreadCount > 0 {
            unreadBadge.text = " \(row.unreadCount) "
            unreadBadge.isHidden = false
        } else {
            unreadBadge.isHidden = true
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func formattedTimestamp(_ millis: Int64) -> String {
        formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}
