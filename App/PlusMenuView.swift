// App/PlusMenuView.swift
import UIKit

/// WeChat-style popup menu anchored below the nav-bar "+" button: a rounded
/// card at the top-right with icon+title rows, dismissed by tapping anywhere
/// outside. Shown over the navigation controller's view so it floats above
/// the list content.
final class PlusMenuView: UIView {
    struct Item {
        let symbolName: String
        let title: String
        let handler: () -> Void
    }

    private let card = UIView()
    private var items: [Item] = []

    private static let cardWidth: CGFloat = 160
    private static let rowHeight: CGFloat = 52

    static func show(in hostView: UIView, items: [Item]) {
        let menu = PlusMenuView(frame: hostView.bounds)
        menu.items = items
        menu.buildCard(in: hostView)
        hostView.addSubview(menu)
        menu.animateIn()
    }

    private func buildCard(in hostView: UIView) {
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear

        card.backgroundColor = Theme.popupCard
        card.layer.cornerRadius = Theme.cardCornerRadius
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 16
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.frame = CGRect(
            x: hostView.bounds.width - Self.cardWidth - 8,
            y: hostView.safeAreaInsets.top + 6,
            width: Self.cardWidth,
            height: Self.rowHeight * CGFloat(items.count)
        )
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

        let icon = UIImageView(image: UIImage(systemName: item.symbolName))
        icon.tintColor = Theme.textPrimary
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = item.title
        label.font = .systemFont(ofSize: 16)
        label.textColor = Theme.textPrimary
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

    private func animateIn() {
        // Scale up from the card's top-right corner, like WeChat.
        let target = card.frame
        card.layer.anchorPoint = CGPoint(x: 1, y: 0)
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
