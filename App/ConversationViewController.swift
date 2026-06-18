// App/ConversationViewController.swift
import UIKit
import IMKit

/// Placeholder chat screen so this plan produces a complete, runnable,
/// tap-through app. A later plan replaces this with the real message thread.
final class ConversationViewController: UIViewController {
    private let row: ConversationRow

    init(row: ConversationRow) {
        self.row = row
        super.init(nibName: nil, bundle: nil)
        title = row.displayName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary

        let label = UILabel()
        label.text = "与 \(row.displayName) 的聊天界面将在 Plan H 中实现"
        label.textColor = Theme.textPrimary
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }
}
