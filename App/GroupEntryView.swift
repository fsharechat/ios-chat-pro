// App/GroupEntryView.swift
import UIKit

final class GroupEntryView: UIView {
    var onTapped: (() -> Void)?

    private let iconBackgroundView = UIView()
    private let iconImageView = UIImageView(image: UIImage(systemName: "person.3.fill"))
    private let titleLabel = UILabel()
    private let chevronImageView = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func layoutViews() {
        iconBackgroundView.backgroundColor = .systemBlue
        iconBackgroundView.layer.cornerRadius = 8
        iconBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        iconImageView.tintColor = Theme.textOnAccent
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "群聊"
        titleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        chevronImageView.tintColor = Theme.backgroundTertiary
        chevronImageView.contentMode = .scaleAspectFit
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconImageView)
        addSubview(titleLabel)
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
        ])
    }

    @objc private func handleTap() { onTapped?() }
}
