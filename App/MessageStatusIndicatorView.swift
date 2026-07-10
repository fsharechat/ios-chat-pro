// App/MessageStatusIndicatorView.swift
import UIKit

/// 气泡左侧的发送状态指示器（微信风格）：发送中显示旋转的环形圆圈，
/// 发送失败显示红色感叹号（可点击重发）。空闲时整体隐藏。
final class MessageStatusIndicatorView: UIView {
    enum Status {
        case none
        case sending
        case failed
    }

    var onRetry: (() -> Void)?

    private let ringLayer = CAShapeLayer()
    private let retryButton = UIButton(type: .system)
    private var status: Status = .none

    private static let side: CGFloat = 22
    private static let ringDiameter: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)

        let side = Self.side
        let ring = Self.ringDiameter
        // 3/4 圆弧描边，旋转起来就是环形加载圈。
        let rect = CGRect(x: (side - ring) / 2, y: (side - ring) / 2, width: ring, height: ring)
        ringLayer.path = UIBezierPath(ovalIn: rect).cgPath
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.lineWidth = 2
        ringLayer.lineCap = .round
        ringLayer.strokeStart = 0
        ringLayer.strokeEnd = 0.75
        ringLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        layer.addSublayer(ringLayer)

        retryButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        retryButton.tintColor = .systemRed
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(retryButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            retryButton.topAnchor.constraint(equalTo: topAnchor),
            retryButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            retryButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyRingColor()
        apply(.none)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ status: Status) {
        self.status = status
        isHidden = status == .none
        ringLayer.isHidden = status != .sending
        retryButton.isHidden = status != .failed
        if status == .sending { startSpinning() } else { stopSpinning() }
    }

    /// 离屏（cell 复用/退后台）会移除 layer 动画，回到窗口时按当前状态补回。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, status == .sending { startSpinning() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyRingColor()
        }
    }

    private func applyRingColor() {
        ringLayer.strokeColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
    }

    private func startSpinning() {
        guard ringLayer.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        ringLayer.add(spin, forKey: "spin")
    }

    private func stopSpinning() {
        ringLayer.removeAnimation(forKey: "spin")
    }

    @objc private func retryTapped() { onRetry?() }
}
