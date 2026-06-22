import UIKit

/// Presented when the composer detects a trailing "@". `uid == nil` in the
/// callback means the user picked "所有人" (mention all).
final class MentionPickerViewController: UIViewController {
    private let members: [(uid: String, displayName: String)]
    private let tableView = UITableView()

    var onPicked: ((_ uid: String?, _ displayName: String) -> Void)?
    /// Fired when the picker is dismissed via its own cancel button (as
    /// opposed to a selection) — lets the presenter clean up the dangling
    /// trailing "@" left in the composer.
    var onCancelled: (() -> Void)?

    init(members: [(uid: String, displayName: String)]) {
        self.members = members
        super.init(nibName: nil, bundle: nil)
        title = "选择提醒的人"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func cancelTapped() {
        onCancelled?()
        dismiss(animated: true)
    }
}

extension MentionPickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        members.count + 1 // +1 for "所有人"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.backgroundColor = Theme.backgroundSecondary
        cell.textLabel?.textColor = Theme.textPrimary
        cell.textLabel?.text = indexPath.row == 0 ? "所有人" : members[indexPath.row - 1].displayName
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            onPicked?(nil, "所有人")
        } else {
            let member = members[indexPath.row - 1]
            onPicked?(member.uid, member.displayName)
        }
    }
}
