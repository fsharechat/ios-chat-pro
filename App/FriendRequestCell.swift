// App/FriendRequestCell.swift
import UIKit
import IMKit

final class FriendRequestCell: UITableViewCell {
    static let reuseIdentifier = "FriendRequestCell"

    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()
    private let reasonLabel = UILabel()
    private let acceptButton = UIButton(type: .system)

    var onAcceptTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 16, weight: .regular)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        reasonLabel.font = .systemFont(ofSize: 13, weight: .regular)
        reasonLabel.textColor = .secondaryLabel
        reasonLabel.translatesAutoresizingMaskIntoConstraints = false

        acceptButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        acceptButton.addTarget(self, action: #selector(handleAcceptTapped), for: .touchUpInside)
        acceptButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarImageView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(reasonLabel)
        contentView.addSubview(acceptButton)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 40),
            avatarImageView.heightAnchor.constraint(equalToConstant: 40),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            avatarImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            acceptButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            acceptButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: acceptButton.leadingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: avatarImageView.topAnchor),

            reasonLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            reasonLabel.trailingAnchor.constraint(lessThanOrEqualTo: acceptButton.leadingAnchor, constant: -8),
            reasonLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
        ])
    }

    func configure(with row: NewFriendsViewModel.FriendRequestRow) {
        avatarImageView.setAvatar(urlString: row.avatarURL, displayName: row.displayName)
        nameLabel.text = row.displayName
        reasonLabel.text = row.reason.isEmpty ? "请求添加你为朋友" : row.reason
        if row.isAccepted {
            acceptButton.setTitle("已添加", for: .normal)
            acceptButton.isEnabled = false
            acceptButton.setTitleColor(.secondaryLabel, for: .normal)
        } else {
            acceptButton.setTitle("接受", for: .normal)
            acceptButton.isEnabled = true
            acceptButton.setTitleColor(Theme.accent, for: .normal)
        }
    }

    @objc private func handleAcceptTapped() {
        acceptButton.isEnabled = false
        onAcceptTapped?()
    }
}
