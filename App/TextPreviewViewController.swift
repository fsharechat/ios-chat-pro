// App/TextPreviewViewController.swift
import UIKit

/// Read-only full-text page for a collapsed long message ("查看全文").
/// UITextView lays out lazily as the user scrolls, so arbitrarily long text
/// stays smooth — unlike the chat bubble's fully-laid-out UILabel.
final class TextPreviewViewController: UIViewController {
    private let text: String
    private let textView = UITextView()

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        title = "全文"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary

        textView.isEditable = false
        renderContent()
        // Color only, no underline — matches the bubble's link treatment.
        textView.linkTextAttributes = [.foregroundColor: UIColor.systemBlue]
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Colors are resolved to concrete values at render time (the table
    /// bitmap can't hold dynamic colors), so a light/dark switch re-renders.
    private func renderContent() {
        // 34 = textContainerInset (12+12) + lineFragmentPadding (5×2).
        textView.attributedText = MarkdownRenderer.render(
            text,
            textColor: Theme.textPrimary.resolvedColor(with: traitCollection),
            availableWidth: UIScreen.main.bounds.width - 34
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            renderContent()
        }
    }
}
