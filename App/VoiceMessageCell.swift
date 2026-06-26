import UIKit
import IMKit

final class VoiceMessageCell: UITableViewCell {
    static let reuseIdentifier = "VoiceMessageCell"

    private let bubbleView = UIView()
    private let iconView = UIImageView()
    private let durationLabel = UILabel()
    private let avatarView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func layoutViews() {
        bubbleView.layer.cornerRadius = 16
        iconView.image = UIImage(systemName: "waveform")
        iconView.contentMode = .scaleAspectFit
        durationLabel.font = .systemFont(ofSize: 15)

        let hStack = UIStackView(arrangedSubviews: [iconView, durationLabel])
        hStack.axis = .horizontal
        hStack.spacing = 6
        hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(hStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            hStack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 10),
            hStack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10),
            hStack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 14),
            hStack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -14),
            bubbleView.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        bubbleColumn.axis = .vertical
        bubbleColumn.addArrangedSubview(bubbleView)

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        rowStack.addArrangedSubview(bubbleColumn)

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubbleColumn.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.6),
        ])
    }

    func configure(with row: StoredMessageRow) {
        let isOutgoing = row.isOutgoing
        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.incomingBubble
        iconView.tintColor = isOutgoing ? .white : Theme.accent
        durationLabel.textColor = isOutgoing ? .white : .label

        let text = row.text ?? ""
        let parts = text.components(separatedBy: " ")
        durationLabel.text = parts.count > 1 ? parts[1] : text

        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        avatarView.removeFromSuperview()

        if isOutgoing {
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
}
