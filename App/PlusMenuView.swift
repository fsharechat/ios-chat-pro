// App/PlusMenuView.swift
import UIKit

/// WeChat-style popup menu: a rounded card with icon+title rows, dismissed by
/// tapping anywhere outside. Two anchoring modes:
/// - `show(in:items:)` pins the card below the nav-bar "+" button (top-right);
/// - `show(in:anchorRect:items:)` pops the card next to a long-pressed row.
/// Shown over the navigation controller's view so it floats above the content.
final class PlusMenuView: UIView {
    struct Item {
        let symbolName: String
        let title: String
        let isDestructive: Bool
        let handler: () -> Void

        init(symbolName: String, title: String, isDestructive: Bool = false, handler: @escaping () -> Void) {
            self.symbolName = symbolName
            self.title = title
            self.isDestructive = isDestructive
            self.handler = handler
        }
    }

    private let card = UIView()
    private var items: [Item] = []

    private static let cardWidth: CGFloat = 160
    private static let rowHeight: CGFloat = 52
    private static let margin: CGFloat = 8

    static func show(in hostView: UIView, items: [Item]) {
        let frame = CGRect(
            x: hostView.bounds.width - cardWidth - margin,
            y: hostView.safeAreaInsets.top + 6,
            width: cardWidth,
            height: rowHeight * CGFloat(items.count)
        )
        show(in: hostView, items: items, cardFrame: frame, animationAnchor: CGPoint(x: 1, y: 0))
    }

    /// Pops the card near `anchorRect` (in `hostView` coordinates): below it when
    /// there is room, otherwise above, horizontally centered on it and clamped
    /// to the host bounds.
    static func show(in hostView: UIView, anchorRect: CGRect, items: [Item]) {
        let height = rowHeight * CGFloat(items.count)
        let x = min(max(anchorRect.midX - cardWidth / 2, margin), hostView.bounds.width - cardWidth - margin)

        let maxY = hostView.bounds.height - hostView.safeAreaInsets.bottom - margin
        let minY = hostView.safeAreaInsets.top + margin
        let below = anchorRect.maxY + margin
        let showsBelow = below + height <= maxY
        let y = showsBelow ? below : max(anchorRect.minY - margin - height, minY)

        let frame = CGRect(x: x, y: y, width: cardWidth, height: height)
        let anchorX = min(max((anchorRect.midX - frame.minX) / cardWidth, 0), 1)
        let anchor = CGPoint(x: anchorX, y: showsBelow ? 0 : 1)
        show(in: hostView, items: items, cardFrame: frame, animationAnchor: anchor)
    }

    private static func show(in hostView: UIView, items: [Item], cardFrame: CGRect, animationAnchor: CGPoint) {
        let menu = PlusMenuView(frame: hostView.bounds)
        menu.items = items
        menu.buildCard(frame: cardFrame)
        hostView.addSubview(menu)
        menu.animateIn(anchor: animationAnchor)
    }

    private func buildCard(frame cardFrame: CGRect) {
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear

        card.backgroundColor = Theme.popupCard
        card.layer.cornerRadius = Theme.cardCornerRadius
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 16
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.frame = cardFrame
        addSubview(card)

        for (index, item) in items.enumerated() {
            let row = makeRow(item: item, index: index)
            row.frame = CGRect(x: 0, y: Self.rowHeight * CGFloat(index), width: Self.cardWidth, height: Self.rowHeight)
            card.addSubview(row)

            if index > 0 {
                let separator = UIView(frame: CGRect(x: 20, y: row.frame.minY, width: Self.cardWidth - 20, height: 1 / UIScreen.main.scale))
                separator.backgroundColor = Theme.backgroundTertiary
                card.addSubview(separator)
            }
        }

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backdropTapped(_:))))
    }

    private func makeRow(item: Item, index: Int) -> UIControl {
        let row = UIButton(type: .system)
        row.tag = index
        let tint = item.isDestructive ? UIColor.systemRed : Theme.textPrimary

        let icon = UIImageView(image: UIImage(systemName: item.symbolName))
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = item.title
        label.font = .systemFont(ofSize: 16)
        label.textColor = tint
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(icon)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
        return row
    }

    @objc private func rowTapped(_ sender: UIControl) {
        let handler = items[sender.tag].handler
        animateOut { handler() }
    }

    @objc private func backdropTapped(_ recognizer: UITapGestureRecognizer) {
        guard !card.frame.contains(recognizer.location(in: self)) else { return }
        animateOut()
    }

    private func animateIn(anchor: CGPoint) {
        // Scale up from the corner nearest the anchor, like WeChat.
        let target = card.frame
        card.layer.anchorPoint = anchor
        card.frame = target
        card.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        card.alpha = 0
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.card.transform = .identity
            self.card.alpha = 1
        }
    }

    private func animateOut(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.15, animations: {
            self.card.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
            self.card.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
            completion?()
        })
    }
}
