import UIKit
import IMKit

struct LocationBubbleData: Equatable {
    let thumbnail: Data?
    let title: String
    let isOutgoing: Bool
    let senderDisplayName: String?
    let senderAvatarURL: String?

    init(thumbnail: Data?, title: String, isOutgoing: Bool,
         senderDisplayName: String? = nil, senderAvatarURL: String? = nil) {
        self.thumbnail = thumbnail
        self.title = title
        self.isOutgoing = isOutgoing
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
    }
}

final class LocationMessageCell: UITableViewCell {
    static let reuseIdentifier = "LocationMessageCell"

    private let mapImageView = UIImageView()
    private let titleLabel = UILabel()
    private let bubbleStack = UIStackView()
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    private let senderNameLabel = UILabel()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader.shared)

    var onTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        bubbleStack.addGestureRecognizer(tap)
        bubbleStack.isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTapped = nil
        mapImageView.image = nil
        titleLabel.text = nil
    }

    private func layoutViews() {
        mapImageView.contentMode = .scaleAspectFill
        mapImageView.clipsToBounds = true
        mapImageView.layer.cornerRadius = 8
        mapImageView.backgroundColor = Theme.backgroundTertiary
        mapImageView.tintColor = .secondaryLabel
        mapImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mapImageView.widthAnchor.constraint(equalToConstant: 200),
            mapImageView.heightAnchor.constraint(equalToConstant: 120),
        ])

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        bubbleStack.axis = .vertical
        bubbleStack.spacing = 6
        bubbleStack.layer.cornerRadius = 12
        bubbleStack.clipsToBounds = true
        bubbleStack.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        bubbleStack.isLayoutMarginsRelativeArrangement = true
        bubbleStack.addArrangedSubview(mapImageView)
        bubbleStack.addArrangedSubview(titleLabel)

        senderNameLabel.font = .systemFont(ofSize: 11)
        senderNameLabel.textColor = .secondaryLabel
        senderAvatarImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),
        ])

        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 4
        bubbleColumn.addArrangedSubview(senderNameLabel)
        bubbleColumn.addArrangedSubview(bubbleStack)

        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
        ])
    }

    func configure(with data: LocationBubbleData) {
        titleLabel.text = data.title
        titleLabel.textColor = data.isOutgoing ? .white : Theme.textPrimary

        if let thumbData = data.thumbnail, let img = UIImage(data: thumbData) {
            mapImageView.image = img
        } else {
            mapImageView.image = UIImage(systemName: "mappin.and.ellipse")
        }

        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        senderNameLabel.isHidden = data.senderDisplayName == nil

        if data.isOutgoing {
            bubbleStack.backgroundColor = Theme.accent
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
            senderAvatarImageView.setAvatar(urlString: data.senderAvatarURL, displayName: "我")
        } else {
            bubbleStack.backgroundColor = Theme.backgroundTertiary
            senderNameLabel.text = data.senderDisplayName
            rowStack.addArrangedSubview(senderAvatarImageView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            senderAvatarImageView.setAvatar(urlString: data.senderAvatarURL, displayName: data.senderDisplayName ?? "")
        }
    }

    @objc private func handleTap() { onTapped?() }
}
