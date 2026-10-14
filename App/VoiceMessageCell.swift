import UIKit
import IMKit

final class VoiceMessageCell: UITableViewCell {
    static let reuseIdentifier = "VoiceMessageCell"

    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?
    /// 群聊里长按对方头像 → 会话页在输入框插入 @；自己发的消息不绑定。
    var onAvatarLongPressed: (() -> Void)?
    var onTranscribeTapped: (() -> Void)?
    var onTranscriptRetryTapped: (() -> Void)?

    private let unplayedDot = UIView()
    private let transcribePill = UIButton(type: .system)
    private let transcriptLabel = PaddingLabel()
    private let bubbleRow = UIStackView()

    private let bubbleView = UIView()
    private let iconView = UIImageView()
    private let durationLabel = UILabel()
    private let senderNameLabel = UILabel()
    private let statusIndicator = MessageStatusIndicatorView()
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

    override func prepareForReuse() {
        super.prepareForReuse()
        onTapped = nil
        onRetryTapped = nil
        onAvatarLongPressed = nil
        onTranscribeTapped = nil
        onTranscriptRetryTapped = nil
        statusIndicator.apply(.none)
    }

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

        // 群聊接收方向的发送者昵称，样式与 TextMessageCell 一致。
        senderNameLabel.font = .systemFont(ofSize: 12)
        senderNameLabel.textColor = Theme.textPrimary.withAlphaComponent(0.6)

        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(senderNameLabel)
        unplayedDot.backgroundColor = .systemRed
        unplayedDot.layer.cornerRadius = 4
        unplayedDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            unplayedDot.widthAnchor.constraint(equalToConstant: 8),
            unplayedDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        transcribePill.setTitle("转文字", for: .normal)
        transcribePill.titleLabel?.font = .systemFont(ofSize: 12)
        transcribePill.setTitleColor(Theme.textSecondary, for: .normal)
        transcribePill.backgroundColor = Theme.backgroundTertiary
        transcribePill.layer.cornerRadius = 12
        transcribePill.contentEdgeInsets = UIEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        transcribePill.addTarget(self, action: #selector(pillTapped), for: .touchUpInside)

        bubbleRow.axis = .horizontal
        bubbleRow.spacing = 8
        bubbleRow.alignment = .center
        bubbleRow.addArrangedSubview(bubbleView)
        bubbleRow.addArrangedSubview(unplayedDot)
        bubbleRow.addArrangedSubview(transcribePill)

        transcriptLabel.numberOfLines = 0
        transcriptLabel.font = .systemFont(ofSize: 14)
        transcriptLabel.backgroundColor = Theme.backgroundTertiary
        transcriptLabel.layer.cornerRadius = 8
        transcriptLabel.layer.masksToBounds = true
        transcriptLabel.isUserInteractionEnabled = true
        transcriptLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(transcriptTapped)))

        bubbleColumn.addArrangedSubview(bubbleRow)
        bubbleColumn.addArrangedSubview(transcriptLabel)

        rowStack.axis = .horizontal
        // 头像与气泡顶部对齐(微信风格),同 TextMessageCell。
        rowStack.alignment = .top
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        rowStack.addArrangedSubview(bubbleColumn)

        avatarView.isUserInteractionEnabled = true
        let avatarPress = UILongPressGestureRecognizer(target: self, action: #selector(avatarLongPressed(_:)))
        // 比表格整行长按菜单手势（默认 0.5s）先识别，长按头像走 @ 而非弹菜单
        avatarPress.minimumPressDuration = 0.4
        avatarView.addGestureRecognizer(avatarPress)

        // 状态指示器不入 stack：直接钉在气泡左侧、垂直居中。
        statusIndicator.onRetry = { [weak self] in self?.onRetryTapped?() }
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusIndicator)

        NSLayoutConstraint.activate([
            statusIndicator.trailingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: -6),
            statusIndicator.centerYAnchor.constraint(equalTo: bubbleView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubbleColumn.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.6),
        ])
    }

    @objc private func avatarLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onAvatarLongPressed?()
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

    @objc private func pillTapped() { onTranscribeTapped?() }

    private var transcriptIsError = false
    @objc private func transcriptTapped() {
        if transcriptIsError { onTranscriptRetryTapped?() }
    }

    private func applyTranscript(isOutgoing: Bool, showDot: Bool, showPill: Bool, entry: TranscriptEngine.Entry?) {
        // 他人语音：气泡在左，红点/按钮在右；自己发的语音不显示红点/按钮
        unplayedDot.isHidden = isOutgoing || !showDot
        transcribePill.isHidden = isOutgoing || !showPill
        transcriptIsError = false
        switch VoiceTranscriptRules.block(entry) {
        case .none:
            transcriptLabel.isHidden = true
        case .loading:
            transcriptLabel.isHidden = false
            transcriptLabel.text = "转文字中…"
            transcriptLabel.textColor = Theme.textSecondary
        case .error:
            transcriptLabel.isHidden = false
            transcriptLabel.text = "转文字失败，点击重试"
            transcriptLabel.textColor = .systemRed
            transcriptIsError = true
        case .empty:
            transcriptLabel.isHidden = false
            transcriptLabel.text = "未识别到文字"
            transcriptLabel.textColor = Theme.textSecondary
        case .text:
            transcriptLabel.isHidden = false
            transcriptLabel.text = entry?.text
            transcriptLabel.textColor = Theme.textPrimary
        }
    }

    func configure(with row: StoredMessageRow, transcript: TranscriptEngine.Entry? = nil, showPill: Bool = false) {
        let status: MessageStatusIndicatorView.Status
        if row.isOutgoing, row.status == .sending {
            status = .sending
        } else if row.isOutgoing, row.status == .sendFailure {
            status = .failed
        } else {
            status = .none
        }
        applyBubble(
            isOutgoing: row.isOutgoing, duration: row.voiceDuration ?? 0, status: status,
            avatarURL: row.senderAvatarURL, senderDisplayName: row.senderDisplayName
        )
        applyTranscript(isOutgoing: row.isOutgoing, showDot: !row.isOutgoing && row.status != .played, showPill: showPill, entry: transcript)
    }

    /// 上传中/上传失败的占位行（尚未落库），与 pending 图片/视频同一生命周期。
    func configurePending(_ pending: PendingVoiceUpload) {
        applyBubble(
            isOutgoing: true, duration: pending.duration,
            status: pending.state == .uploading ? .sending : .failed,
            avatarURL: nil, senderDisplayName: nil
        )
        applyTranscript(isOutgoing: true, showDot: false, showPill: false, entry: nil)
    }

    private func applyBubble(isOutgoing: Bool, duration: Int, status: MessageStatusIndicatorView.Status, avatarURL: String?, senderDisplayName: String?) {
        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.incomingBubble
        iconView.tintColor = isOutgoing ? .white : Theme.accent
        durationLabel.textColor = isOutgoing ? .white : Theme.textPrimary
        statusIndicator.apply(status)

        durationLabel.text = "\(duration)秒"

        // 对齐 Android（AudioMessageContentViewHolder.onBind）：
        // 宽度 = 基础宽 + 半屏 × 时长/120s，120s 与 Config.DEFAULT_MAX_AUDIO_RECORD_TIME_SECOND 一致。
        let maxDuration: CGFloat = 120
        let extra = UIScreen.main.bounds.width / 2 * min(CGFloat(duration), maxDuration) / maxDuration
        bubbleWidthConstraint.constant = 80 + extra

        let showsSender = !isOutgoing && senderDisplayName != nil
        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? senderDisplayName : nil
        // .leading 让气泡保持自身宽度约束,长昵称不会把气泡拉宽(同
        // TextMessageCell 的 alignment 处理)。
        bubbleColumn.alignment = isOutgoing ? .trailing : .leading

        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        avatarView.removeFromSuperview()

        if isOutgoing {
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(avatarView)
            avatarView.setAvatar(urlString: avatarURL, displayName: "我")
        } else {
            rowStack.addArrangedSubview(avatarView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            avatarView.setAvatar(urlString: avatarURL, displayName: senderDisplayName ?? "")
        }
    }
}

/// 带内边距的 UILabel，用于转文字文字块
final class PaddingLabel: UILabel {
    var insets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}
