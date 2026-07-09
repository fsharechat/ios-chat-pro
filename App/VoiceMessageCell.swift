import UIKit
import IMKit

final class VoiceMessageCell: UITableViewCell {
    static let reuseIdentifier = "VoiceMessageCell"

    var onTapped: (() -> Void)?

    private let bubbleView = UIView()
    private let iconView = UIImageView()
    private let durationLabel = UILabel()
    private let avatarView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    private var bubbleWidthConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
        let tap = UITapGestureRecognizer(target: self, action: #selector(bubbleTapped))
        bubbleView.isUserInteractionEnabled = true
        bubbleView.addGestureRecognizer(tap)
    }

    @objc private func bubbleTapped() { onTapped?() }

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

        // 时长驱动的目标宽度。优先级低于「≥80」和「≤行宽60%」两条 required
        // 约束，超长语音时被 60% 上限压住，内容更宽时被内容撑开。
        bubbleWidthConstraint = bubbleView.widthAnchor.constraint(equalToConstant: 80)
        bubbleWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            hStack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 10),
            hStack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10),
            hStack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 14),
            hStack.trailingAnchor.constraint(lessThanOrEqualTo: bubbleView.trailingAnchor, constant: -14),
            bubbleView.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            bubbleWidthConstraint,
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

    func setPlaying(_ playing: Bool) {
        if playing {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.15
            anim.duration = 0.5
            anim.autoreverses = true
            anim.repeatCount = .infinity
            iconView.layer.add(anim, forKey: "playing")
        } else {
            iconView.layer.removeAnimation(forKey: "playing")
        }
    }

    func configure(with row: StoredMessageRow) {
        let isOutgoing = row.isOutgoing
        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.incomingBubble
        iconView.tintColor = isOutgoing ? .white : Theme.accent
        durationLabel.textColor = isOutgoing ? .white : .label

        let duration = row.voiceDuration ?? 0
        durationLabel.text = "\(duration)秒"

        // 对齐 Android（AudioMessageContentViewHolder.onBind）：
        // 宽度 = 基础宽 + 半屏 × 时长/120s，120s 与 Config.DEFAULT_MAX_AUDIO_RECORD_TIME_SECOND 一致。
        let maxDuration: CGFloat = 120
        let extra = UIScreen.main.bounds.width / 2 * min(CGFloat(duration), maxDuration) / maxDuration
        bubbleWidthConstraint.constant = 80 + extra

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
