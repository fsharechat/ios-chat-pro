// App/TextMessageCell.swift
import UIKit
import IMKit

final class TextMessageCell: UITableViewCell {
    static let reuseIdentifier = "TextMessageCell"

    private let bubbleView = UIView()
    private let messageTextLabel = TextKitLabel()
    private let statusIndicator = MessageStatusIndicatorView()
    private let senderNameLabel = UILabel()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    private let expandButton = UIButton(type: .system)

    var onRetryTapped: (() -> Void)?
    var onExpandTapped: (() -> Void)?
    /// 群聊里长按对方头像 → 会话页在输入框插入 @；自己发的消息不绑定。
    var onAvatarLongPressed: (() -> Void)?
    /// 消息里的链接被点击。`messageTextLabel` 是 UILabel，`.link` 属性本身不会
    /// 触发跳转（只有 UITextView 会拦截），需要自己命中测试后转发出去。
    var onLinkTapped: ((URL) -> Void)?
    /// 选字状态下拖动手柄开始 / 结束，会话页据此隐藏 / 重新定位菜单。
    var onSelectionDragBegan: (() -> Void)?
    var onSelectionDragEnded: (() -> Void)?
    /// 选区被 cell 自己清掉（复用、重新 configure）时回调，会话页据此关菜单。
    var onSelectionCleared: (() -> Void)?
    private lazy var textSelection: TextSelectionController = {
        let controller = TextSelectionController(label: messageTextLabel, handleHost: contentView)
        controller.onDragBegan = { [weak self] in self?.onSelectionDragBegan?() }
        controller.onDragEnded = { [weak self] in self?.onSelectionDragEnded?() }
        return controller
    }()
    /// Kept so a light/dark switch can re-render: markdown attributes (and
    /// the table bitmap especially) bake in colors resolved at configure
    /// time — dynamic colors can't adapt inside a drawn image.
    private var lastConfiguredRow: StoredMessageRow?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearSelection()
        onSelectionDragBegan = nil
        onSelectionDragEnded = nil
        onSelectionCleared = nil
        onRetryTapped = nil
        onExpandTapped = nil
        onAvatarLongPressed = nil
        onLinkTapped = nil
        setWaitingCursorBlink(false)
    }

    private static let cursorBlinkAnimationKey = "streamingCursorBlink"

    /// 流式占位气泡等待期(还没收到任何文本)让 ▌ 光标闪烁——此时没有
    /// delta 驱动刷新,纯静态文本会让用户以为卡住了。文本开始增长后由
    /// 调用方关掉(增长本身就是活跃反馈,整段文本闪烁反而晃眼)。
    func setWaitingCursorBlink(_ on: Bool) {
        if on {
            guard messageTextLabel.layer.animation(forKey: Self.cursorBlinkAnimationKey) == nil else { return }
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.2
            blink.duration = 0.5
            blink.autoreverses = true
            blink.repeatCount = .infinity
            messageTextLabel.layer.add(blink, forKey: Self.cursorBlinkAnimationKey)
        } else {
            messageTextLabel.layer.removeAnimation(forKey: Self.cursorBlinkAnimationKey)
        }
    }

    private func layoutViews() {
        messageTextLabel.numberOfLines = 0
        messageTextLabel.font = .systemFont(ofSize: 16)
        messageTextLabel.translatesAutoresizingMaskIntoConstraints = false
        messageTextLabel.isUserInteractionEnabled = true
        messageTextLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(messageTextTapped(_:))))
        bubbleView.layer.cornerRadius = Theme.bubbleCornerRadius
        bubbleView.addSubview(messageTextLabel)
        NSLayoutConstraint.activate([
            messageTextLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            messageTextLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            messageTextLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            messageTextLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
        ])

        senderNameLabel.font = .systemFont(ofSize: 12)
        senderNameLabel.textColor = Theme.textPrimary.withAlphaComponent(0.6)

        statusIndicator.onRetry = { [weak self] in self?.onRetryTapped?() }

        senderAvatarImageView.isUserInteractionEnabled = true
        let avatarPress = UILongPressGestureRecognizer(target: self, action: #selector(avatarLongPressed(_:)))
        // 比表格整行长按菜单手势（默认 0.5s）先识别，长按头像走 @ 而非弹菜单
        avatarPress.minimumPressDuration = 0.4
        senderAvatarImageView.addGestureRecognizer(avatarPress)

        expandButton.setTitle("查看全文", for: .normal)
        expandButton.titleLabel?.font = .systemFont(ofSize: 13)
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        expandButton.isHidden = true

        // bubbleColumn stacks sender name + bubble + expand vertically
        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(senderNameLabel)
        bubbleColumn.addArrangedSubview(bubbleView)
        bubbleColumn.addArrangedSubview(expandButton)

        rowStack.axis = .horizontal
        // 头像与气泡顶部对齐(微信风格),与 Image/Video cell 一致;多行长
        // 气泡时头像不能沉底。
        rowStack.alignment = .top
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        // bubbleColumn must be in the view hierarchy before the width constraint
        // referencing contentView is activated — they need a common ancestor.
        rowStack.addArrangedSubview(bubbleColumn)

        // 状态指示器不入 stack：直接钉在气泡左侧、垂直居中。
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusIndicator)

        NSLayoutConstraint.activate([
            statusIndicator.trailingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: -6),
            statusIndicator.centerYAnchor.constraint(equalTo: bubbleView.centerYAnchor),
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            // Bubble may grow until its far edge aligns with where the
            // opposite party's avatar sits: 2×(8pt row inset + 36pt avatar
            // + 8pt gap) = 104pt reserved. Wider than the old 65% cap —
            // gives tables room to render as a real grid.
            bubbleColumn.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -Self.reservedHorizontalSpace),
        ])
    }

    /// 8pt row inset + 36pt avatar + 8pt gap, mirrored on both sides.
    private static let reservedHorizontalSpace: CGFloat = 104
    /// Widest the label content can be: bubble max width minus the bubble's
    /// 12pt+12pt text insets. Used as the markdown table's render width.
    static var maxContentWidth: CGFloat { UIScreen.main.bounds.width - reservedHorizontalSpace - 24 }

    /// 文本气泡的展示形态:`folded` 超长时缩略+查看全文(默认);
    /// `fullText` 渲染全文不折叠——流式输出中 `showCollapse=false`(无按钮),
    /// 输出完毕后 `showCollapse=true`(超长时给"收起",点击回到 folded)。
    enum TextDisplayMode {
        case folded
        case fullText(showCollapse: Bool)
    }

    private var lastDisplayMode: TextDisplayMode = .folded

    func configure(with row: StoredMessageRow, displayMode: TextDisplayMode = .folded) {
        // 文字/排版可能变了，旧选区的字符位置不再可信。
        clearSelection()
        lastConfiguredRow = row
        lastDisplayMode = displayMode
        let isOutgoing = row.isOutgoing
        // Collapse very long text — a single self-sizing label holding a
        // multi-thousand-character message makes the bubble taller than the
        // GPU's maximum texture size and stalls open/scroll on TextKit
        // layout. Full text remains available via 查看全文/copy/forward.
        // (.fullText 模式跳过折叠:流式输出用户要求全程可见,展开态是
        // 用户主动点开,均以可接受的布局开销换完整呈现。)
        let rawText = row.text ?? ""
        let preview: (text: String, isTruncated: Bool)
        switch displayMode {
        case .folded: preview = LongTextPreview.preview(for: rawText)
        case .fullText: preview = (rawText, false)
        }
        // Resolve the dynamic color against this cell's traits *now*: the
        // table renderer bakes it into a bitmap (which can't re-resolve),
        // and the resolved value keys the render cache per appearance.
        let textColor = (isOutgoing ? Theme.textOnAccent : Theme.textPrimary)
            .resolvedColor(with: traitCollection)
        let linkColor = (isOutgoing ? Theme.linkOnAccent : Theme.link)
            .resolvedColor(with: traitCollection)
        messageTextLabel.attributedText = MarkdownRenderer.render(
            preview.text,
            textColor: textColor,
            linkColor: linkColor,
            linkAttributeKey: MarkdownRenderer.bubbleLinkAttributeKey,
            availableWidth: Self.maxContentWidth
        )
        switch displayMode {
        case .folded:
            expandButton.setTitle("查看全文", for: .normal)
            expandButton.isHidden = !preview.isTruncated
        case .fullText(let showCollapse):
            expandButton.setTitle("收起", for: .normal)
            expandButton.isHidden = !(showCollapse && rawText.count > LongTextPreview.characterLimit)
        }
        let showsSender = !isOutgoing && row.senderDisplayName != nil

        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? row.senderDisplayName : nil

        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.incomingBubble
        // No textColor assignment here: setting UILabel.textColor after
        // attributedText repaints the whole string, clobbering the per-run
        // colors (quote/divider alpha) MarkdownRenderer produced.
        bubbleColumn.alignment = isOutgoing ? .trailing : .leading

        switch (isOutgoing, row.status) {
        case (true, .sending): statusIndicator.apply(.sending)
        case (true, .sendFailure): statusIndicator.apply(.failed)
        default: statusIndicator.apply(.none)
        }

        // Reset rowStack: keep bubbleColumn in the hierarchy (its width
        // constraint to contentView must stay valid); remove everything else.
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        senderAvatarImageView.removeFromSuperview()

        if isOutgoing {
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(senderAvatarImageView)
            senderAvatarImageView.setAvatar(urlString: row.senderAvatarURL, displayName: "我")
        } else {
            rowStack.addArrangedSubview(senderAvatarImageView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            senderAvatarImageView.setAvatar(
                urlString: row.senderAvatarURL,
                displayName: row.senderDisplayName ?? ""
            )
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection),
              let row = lastConfiguredRow else { return }
        // Callbacks (onRetryTapped etc.) are untouched — re-running
        // configure only refreshes the appearance-dependent content.
        configure(with: row, displayMode: lastDisplayMode)
    }

    // MARK: - 选字

    /// 全选气泡文字并显示手柄；返回 false 表示没有可选的文字。
    @discardableResult
    func beginSelection() -> Bool {
        layoutIfNeeded()
        let isOutgoing = lastConfiguredRow?.isOutgoing ?? false
        let highlight = (isOutgoing ? Theme.textSelectionOnAccent : Theme.textSelection).resolvedColor(with: traitCollection)
        guard textSelection.selectAll(highlightColor: highlight, handleColor: Theme.textSelectionHandle) else { return false }
        // 手柄会探出 cell 底部，提到最前面，邻居 cell 才不会盖住它、抢走触摸。
        superview?.bringSubviewToFront(self)
        return true
    }

    func clearSelection() {
        guard textSelection.isActive else { return }
        textSelection.clear()
        onSelectionCleared?()
    }

    /// 部分选中时返回选中的显示文字；全选时返回 nil，由调用方复制消息原文
    /// （保留 Markdown 源文，且折叠态下也是全文）。
    var partiallySelectedText: String? {
        guard textSelection.isActive, !textSelection.isFullySelected else { return nil }
        return textSelection.selectedText
    }

    func selectionBounds(in view: UIView) -> CGRect? {
        textSelection.selectionBounds(in: view)
    }

    func selectionHandleContains(windowPoint: CGPoint) -> Bool {
        textSelection.handle(at: contentView.convert(windowPoint, from: nil)) != nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textSelection.layoutDidChange()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 手柄的触摸区会超出 cell 边界，默认的 hitTest 会在边界外直接放弃。
        if let handle = textSelection.handle(at: convert(point, to: contentView)) { return handle }
        return super.hitTest(point, with: event)
    }

    @objc private func expandTapped() { onExpandTapped?() }
    @objc private func avatarLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onAvatarLongPressed?()
    }

    @objc private func messageTextTapped(_ recognizer: UITapGestureRecognizer) {
        guard let url = link(at: recognizer.location(in: messageTextLabel)) else { return }
        onLinkTapped?(url)
    }

    /// UILabel has no built-in link hit-testing (that's a UITextView-only
    /// behavior) — lay the attributed text out through TextKit ourselves to
    /// find which `.link` run, if any, sits under the tap point.
    private func link(at point: CGPoint) -> URL? {
        // 与选字共用同一套排版（含补字体），命中位置和屏幕显示一致。
        guard let layout = LabelTextLayout(label: messageTextLabel), layout.length > 0 else { return nil }
        let glyphIndex = layout.layoutManager.glyphIndex(for: point, in: layout.textContainer)
        guard glyphIndex < layout.layoutManager.numberOfGlyphs else { return nil }
        // Reject taps that land in the trailing whitespace of a short line
        // rather than on an actual glyph.
        let glyphRect = layout.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: layout.textContainer)
        guard glyphRect.contains(point) else { return nil }

        let charIndex = layout.layoutManager.characterIndexForGlyph(at: glyphIndex)
        return layout.textStorage.attribute(MarkdownRenderer.bubbleLinkAttributeKey, at: charIndex, effectiveRange: nil) as? URL
    }
}
