import UIKit

/// SDK-compatible material. A future native Liquid Glass implementation belongs here.
final class ComposerGlassBackgroundView: UIView {
    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    var cornerRadius: CGFloat = 26 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        material.clipsToBounds = true
        material.layer.cornerCurve = .continuous
        addSubview(material)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAppearance),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAppearance),
            name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        material.frame = bounds
        material.layer.cornerRadius = cornerRadius
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
    }

    @objc private func updateAppearance() {
        let dark = traitCollection.userInterfaceStyle == .dark
        material.effect = UIAccessibility.isReduceTransparencyEnabled ? nil : UIBlurEffect(style: .systemMaterial)
        material.contentView.backgroundColor = UIAccessibility.isReduceTransparencyEnabled
            ? Theme.composerOpaqueBackground : Theme.composerTint
        material.layer.borderWidth = UIAccessibility.isDarkerSystemColorsEnabled ? 1 : 1 / UIScreen.main.scale
        material.layer.borderColor = Theme.composerBorder.resolvedColor(with: traitCollection).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = dark ? 0.22 : 0.12
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }
}

/// Protects the home-indicator region without turning the floating composer into an opaque toolbar.
final class ComposerBottomProtectionView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        let color = Theme.backgroundSecondary.resolvedColor(with: traitCollection)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [color.withAlphaComponent(0).cgColor,
                           color.withAlphaComponent(0.12).cgColor,
                           color.withAlphaComponent(0.9).cgColor]
        gradient.locations = [0, 0.45, 1]
    }
}
