// App/GlassTabBar.swift
import UIKit

/// 仿 iOS 26 液态玻璃风格的悬浮底栏：圆角胶囊毛玻璃底 + 一块可滑动的选中块。
///
/// 系统原生 Liquid Glass 要 iOS 26 SDK（Xcode 26）编译才有，本机工具链到不了，
/// 这里用 iOS 15 起就有的材质模糊仿出外形和手感。以后升级工具链，只需把
/// `backgroundView` 的 effect 换成 `UIGlassEffect`，选中块与手势逻辑不用动。
///
/// 选中块的位置是一个连续值 `position`（0 ... 项数-1），而不是离散下标：
/// 按住拖动、左右横滑切页时它都停在两项之间的中间态，图标/文字颜色按与
/// 选中块的距离插值。位移由自带的弹簧积分（CADisplayLink）驱动，而不用
/// `UIView.animate`——后者只能插值 frame，颜色跟不上，也做不出移动中的拉伸。
final class GlassTabBar: UIView {
    static let height: CGFloat = 62

    /// 用户点按或拖动后松手选中某一项。
    var onSelect: ((Int) -> Void)?
    /// 当前真正选中的项，由外部同步；按住拖动被打断时选中块回到这里。
    var selectedIndex = 0

    private let shadowView = UIView()
    private let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let indicatorView = UIView()
    private var itemViews: [GlassTabBarItemView] = []
    /// 角标按下标暂存：未读数的订阅在 `setItems` 之前就会先推一次值。
    private var badges: [Int: String] = [:]

    /// 选中块当前位置与弹簧目标。
    private var position: CGFloat = 0
    private var targetPosition: CGFloat = 0
    private var velocity: CGFloat = 0
    /// 按住时选中块放大，同样走弹簧。
    private var pressScale: CGFloat = 1
    private var targetPressScale: CGFloat = 1
    private var pressVelocity: CGFloat = 0
    private var displayLink: CADisplayLink?

    private let selectionFeedback = UISelectionFeedbackGenerator()
    /// 拖动途中最近一次经过的项，换项时给一下轻震。
    private var lastHoveredIndex: Int?

    private static let indicatorInset: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)

        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = 0.12
        shadowView.layer.shadowRadius = 16
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 6)
        addSubview(shadowView)

        backgroundView.clipsToBounds = true
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.layer.borderWidth = 1 / UIScreen.main.scale
        addSubview(backgroundView)

        // 选中块放在毛玻璃之外、不受裁剪：按住放大时允许略微探出胶囊边缘。
        indicatorView.isUserInteractionEnabled = false
        indicatorView.layer.cornerCurve = .continuous
        indicatorView.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.14)
                : UIColor.black.withAlphaComponent(0.06)
        }
        addSubview(indicatorView)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        // 按下即识别、移动不设上限：同一个手势同时覆盖点按与按住拖动。
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(press)

        updateBorderColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setItems(_ items: [UITabBarItem]) {
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = items.enumerated().map { index, item in
            let view = GlassTabBarItemView(item: item)
            view.onActivate = { [weak self] in self?.onSelect?(index) }
            view.badgeText = badges[index] ?? item.badgeValue
            addSubview(view)
            return view
        }
        setNeedsLayout()
        applyPosition()
    }

    func setBadge(_ text: String?, at index: Int) {
        badges[index] = text
        guard itemViews.indices.contains(index) else { return }
        itemViews[index].badgeText = text
    }

    /// 把选中块移到 `position`；非动画时立即到位，用于跟随页面横滑进度。
    func setPosition(_ position: CGFloat, animated: Bool) {
        targetPosition = position
        if animated {
            startDisplayLinkIfNeeded()
        } else {
            self.position = position
            velocity = 0
            applyPosition()
            stopDisplayLinkIfSettled()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        shadowView.frame = bounds
        shadowView.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        backgroundView.frame = bounds
        backgroundView.layer.cornerRadius = radius
        let slotWidth = self.slotWidth
        for (index, view) in itemViews.enumerated() {
            view.frame = CGRect(x: Self.indicatorInset + CGFloat(index) * slotWidth, y: 0, width: slotWidth, height: bounds.height)
        }
        applyPosition()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBorderColor()
        applyPosition()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyPosition()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { displayLink?.invalidate(); displayLink = nil }
    }

    private var slotWidth: CGFloat {
        guard !itemViews.isEmpty else { return 0 }
        return (bounds.width - Self.indicatorInset * 2) / CGFloat(itemViews.count)
    }

    /// 高光描边：浅色下是白边，压在浅灰毛玻璃上像玻璃的反光边；深色下收淡。
    private func updateBorderColor() {
        let dark = traitCollection.userInterfaceStyle == .dark
        backgroundView.layer.borderColor = UIColor.white.withAlphaComponent(dark ? 0.15 : 0.6).cgColor
        shadowView.layer.shadowOpacity = dark ? 0.35 : 0.12
    }

    // MARK: - 手势

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard !itemViews.isEmpty else { return }
        let fingerPosition = position(forX: gesture.location(in: self).x)

        switch gesture.state {
        case .began:
            selectionFeedback.prepare()
            lastHoveredIndex = Int(fingerPosition.rounded())
            targetPressScale = 1.12
            targetPosition = fingerPosition
            startDisplayLinkIfNeeded()

        case .changed:
            targetPosition = fingerPosition
            let hovered = Int(fingerPosition.rounded())
            if hovered != lastHoveredIndex {
                lastHoveredIndex = hovered
                selectionFeedback.selectionChanged()
            }
            startDisplayLinkIfNeeded()

        case .ended:
            let index = Int(fingerPosition.rounded())
            targetPressScale = 1
            targetPosition = CGFloat(index)
            startDisplayLinkIfNeeded()
            onSelect?(index)

        case .cancelled, .failed:
            // 被打断（来电、系统手势等）时回到松手前的选中项。
            targetPressScale = 1
            targetPosition = CGFloat(selectedIndex)
            startDisplayLinkIfNeeded()

        default:
            break
        }
    }

    private func position(forX x: CGFloat) -> CGFloat {
        let slotWidth = self.slotWidth
        guard slotWidth > 0 else { return 0 }
        let raw = (x - Self.indicatorInset - slotWidth / 2) / slotWidth
        return min(max(raw, 0), CGFloat(itemViews.count - 1))
    }

    // MARK: - 弹簧驱动

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil, window != nil else {
            if window == nil {
                // 不在屏幕上没必要动画，直接到位。
                position = targetPosition
                pressScale = targetPressScale
                velocity = 0
                pressVelocity = 0
                applyPosition()
            }
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLinkIfSettled() {
        guard isSettled else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    private var isSettled: Bool {
        abs(targetPosition - position) < 0.001 && abs(velocity) < 0.01
            && abs(targetPressScale - pressScale) < 0.001 && abs(pressVelocity) < 0.01
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt = min(CGFloat(link.targetTimestamp - link.timestamp), 1.0 / 30)
        // 欠阻尼一点点（阻尼比 0.75），停下前会轻微回弹，接近系统玻璃块的手感。
        let stiffness: CGFloat = 380
        let damping = 2 * stiffness.squareRoot() * 0.75
        velocity += (stiffness * (targetPosition - position) - damping * velocity) * dt
        position += velocity * dt
        pressVelocity += (stiffness * (targetPressScale - pressScale) - damping * pressVelocity) * dt
        pressScale += pressVelocity * dt

        if isSettled {
            position = targetPosition
            pressScale = targetPressScale
            velocity = 0
            pressVelocity = 0
        }
        applyPosition()
        stopDisplayLinkIfSettled()
    }

    // MARK: - 渲染

    private func applyPosition() {
        let slotWidth = self.slotWidth
        guard slotWidth > 0 else { return }
        let height = bounds.height - Self.indicatorInset * 2
        indicatorView.transform = .identity
        indicatorView.frame = CGRect(x: Self.indicatorInset + position * slotWidth, y: Self.indicatorInset, width: slotWidth, height: height)
        indicatorView.layer.cornerRadius = height / 2
        // 移动中沿运动方向拉长、纵向略压扁，像一滴被拖着走的液体。
        let stretch = min(abs(velocity) * 0.035, 0.22)
        indicatorView.transform = CGAffineTransform(scaleX: pressScale * (1 + stretch), y: pressScale * (1 - stretch * 0.4))

        let normal = Theme.textPrimary.resolvedColor(with: traitCollection)
        let selected = tintColor.resolvedColor(with: traitCollection)
        for (index, view) in itemViews.enumerated() {
            let weight = max(0, 1 - abs(position - CGFloat(index)))
            view.apply(color: normal.blended(to: selected, fraction: weight), selected: weight > 0.5)
        }
    }
}

/// 底栏中的一项：图标在上、文字在下，右上角挂未读角标。
private final class GlassTabBarItemView: UIView {
    var onActivate: (() -> Void)?

    var badgeText: String? {
        didSet {
            badgeLabel.text = badgeText
            badgeLabel.isHidden = badgeText == nil
            accessibilityValue = badgeText
            setNeedsLayout()
        }
    }

    private let item: UITabBarItem
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeLabel = UILabel()

    init(item: UITabBarItem) {
        self.item = item
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        imageView.contentMode = .center
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)
        addSubview(imageView)

        titleLabel.text = item.title
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.backgroundColor = .systemRed
        badgeLabel.clipsToBounds = true
        badgeLabel.isHidden = true
        addSubview(badgeLabel)

        isAccessibilityElement = true
        accessibilityLabel = item.title
        badgeText = item.badgeValue
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(color: UIColor, selected: Bool) {
        imageView.image = (selected ? item.selectedImage ?? item.image : item.image)?.withRenderingMode(.alwaysTemplate)
        imageView.tintColor = color
        titleLabel.textColor = color
        accessibilityTraits = selected ? [.button, .selected] : .button
    }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconHeight: CGFloat = 28
        let titleHeight = ceil(titleLabel.font.lineHeight)
        let top = (bounds.height - iconHeight - 2 - titleHeight) / 2
        imageView.frame = CGRect(x: 0, y: top, width: bounds.width, height: iconHeight)
        titleLabel.frame = CGRect(x: 0, y: top + iconHeight + 2, width: bounds.width, height: titleHeight)

        let badgeHeight: CGFloat = 16
        let badgeWidth = max(badgeHeight, badgeLabel.intrinsicContentSize.width + 10)
        badgeLabel.frame = CGRect(x: bounds.midX + 6, y: top - 2, width: badgeWidth, height: badgeHeight)
        badgeLabel.layer.cornerRadius = badgeHeight / 2
    }
}

private extension UIColor {
    /// 两个已解析颜色之间按 RGBA 线性插值。
    func blended(to other: UIColor, fraction: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = min(max(fraction, 0), 1)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
