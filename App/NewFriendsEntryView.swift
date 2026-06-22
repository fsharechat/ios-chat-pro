// App/NewFriendsEntryView.swift
import UIKit

/// The "新的朋友" row pinned above the A-Z contact list, WeChat-style:
/// icon + title + unread-count badge + chevron. Used as
/// `ContactListViewController`'s `tableView.tableHeaderView`, which (unlike
/// a normal Auto-Layout-managed view) UIKit only sizes from its explicit
/// `frame` — `ContactListViewController.viewDidLayoutSubviews()` re-sets
/// that frame on every layout pass to track the table's current width.
final class NewFriendsEntryView: UIView {
    var onTapped: (() -> Void)?

    private let iconBackgroundView = UIView()
    private let iconImageView = UIImageView(image: UIImage(systemName: "person.badge.plus"))
    private let titleLabel = UILabel()
    private let badgeLabel = UILabel()
    private let chevronImageView = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        iconBackgroundView.backgroundColor = Theme.accent
        iconBackgroundView.layer.cornerRadius = 8
        iconBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        iconImageView.tintColor = Theme.textOnAccent
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "新的朋友"
        titleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        badgeLabel.textColor = Theme.textOnAccent
        badgeLabel.backgroundColor = Theme.accent
        badgeLabel.textAlignment = .center
        badgeLabel.layer.cornerRadius = 9
        badgeLabel.layer.masksToBounds = true
        badgeLabel.isHidden = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        chevronImageView.tintColor = Theme.backgroundTertiary
        chevronImageView.contentMode = .scaleAspectFit
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconImageView)
        addSubview(titleLabel)
        addSubview(badgeLabel)
        addSubview(chevronImageView)

        NSLayoutConstraint.activate([
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 32),
            iconBackgroundView.heightAnchor.constraint(equalToConstant: 32),
            iconBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconBackgroundView.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 18),
            iconImageView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronImageView.widthAnchor.constraint(equalToConstant: 12),
            chevronImageView.heightAnchor.constraint(equalToConstant: 12),

            badgeLabel.trailingAnchor.constraint(equalTo: chevronImageView.leadingAnchor, constant: -8),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.heightAnchor.constraint(equalToConstant: 18),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
    }

    func setUnreadCount(_ count: Int) {
        badgeLabel.isHidden = count <= 0
        badgeLabel.text = count > 99 ? "99+" : "\(count)"
    }

    @objc private func handleTap() {
        onTapped?()
    }
}
