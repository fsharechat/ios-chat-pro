// App/ThemeViewController.swift
import UIKit
import AppCore

final class ThemeViewController: UIViewController {
    private let store: ThemePreferenceStore
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private static let titles: [ThemeMode: String] = [.light: "浅色", .dark: "深色", .system: "跟随系统"]

    /// Fired immediately after the user picks a new mode, so `SceneDelegate`
    /// can apply `window.overrideUserInterfaceStyle` without this view
    /// controller needing a `UIWindow` reference of its own.
    var onModeChanged: ((ThemeMode) -> Void)?

    init(store: ThemePreferenceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "主题"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension ThemeViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { ThemeMode.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        let mode = ThemeMode.allCases[indexPath.row]
        cell.textLabel?.text = Self.titles[mode]
        cell.textLabel?.textColor = Theme.textPrimary
        cell.accessoryType = (mode == store.mode) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let mode = ThemeMode.allCases[indexPath.row]
        store.mode = mode
        tableView.reloadData()
        onModeChanged?(mode)
    }
}
