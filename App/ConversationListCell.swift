// App/ConversationListCell.swift
import UIKit
import IMKit

final class ConversationListCell: UITableViewCell {
    static let reuseIdentifier = "ConversationListCell"

    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()
    private let timestampLabel = UILabel()
    private let previewLabel = UILabel()
    private let unreadBadge = BadgeLabel()
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
        unreadBadge.textColor = .white
        unreadBadge.backgroundColor = .systemRed
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

        let mentionPrefix = row.hasUnreadMention ? "[有人@我] " : ""
        switch row.lastMessageStatus {
        case .sending:
            previewLabel.text = mentionPrefix + "发送中... " + row.previewText
        case .sendFailure:
            previewLabel.text = mentionPrefix + "发送失败 " + row.previewText
        default:
            previewLabel.text = mentionPrefix + row.previewText
        }

        backgroundColor = row.isTop ? Theme.backgroundTertiary : Theme.backgroundSecondary
        muteIcon.isHidden = !row.isMuted
        if row.unreadCount > 0 {
            unreadBadge.text = row.unreadCount > 99 ? "99+" : "\(row.unreadCount)"
            unreadBadge.isHidden = false
        } else {
            unreadBadge.isHidden = true
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy/M/d"
        return f
    }()

    /// 未读数胶囊角标：在文字宽度上补两侧内边距，保证多位数不贴边、
    /// 单位数配合外部的 18pt 最小宽/高约束成正圆且数字居中。
    private final class BadgeLabel: UILabel {
        override var intrinsicContentSize: CGSize {
            var size = super.intrinsicContentSize
            size.width += 10
            return size
        }
    }

    private static func formattedTimestamp(_ millis: Int64) -> String {
        guard millis > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "昨天"
        } else if let daysAgo = calendar.dateComponents([.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)).day, daysAgo < 7 {
            return weekdayFormatter.string(from: date)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return shortDateFormatter.string(from: date)
        } else {
            return fullDateFormatter.string(from: date)
        }
    }
}
