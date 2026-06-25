// App/SettingsViewController.swift
import UIKit

final class SettingsViewController: UIViewController {
    private enum Row: Int, CaseIterable {
        case theme
        case about
        case logout
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// Set by `SceneDelegate` — pushes `ThemeViewController`.
    var onThemeTapped: (() -> Void)?

    /// Set by `SceneDelegate` — pushes `AboutViewController`.
    var onAboutTapped: (() -> Void)?

    /// Set by `SceneDelegate` — fired only after the user confirms the
    /// "退出登录" alert below, never on the bare tap.
    var onLogoutConfirmed: (() -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "设置"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundSecondary
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func logoutTapped() {
        let alert = UIAlertController(title: "退出登录", message: "确定要退出登录吗?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "退出", style: .destructive) { [weak self] _ in
            self?.onLogoutConfirmed?()
        })
        present(alert, animated: true)
    }
}

extension SettingsViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Row.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        switch Row(rawValue: indexPath.row)! {
        case .theme:
            cell.textLabel?.text = "主题"
            cell.textLabel?.textColor = Theme.textPrimary
            cell.accessoryType = .disclosureIndicator
        case .about:
            cell.textLabel?.text = "关于"
            cell.textLabel?.textColor = Theme.textPrimary
            cell.accessoryType = .disclosureIndicator
        case .logout:
            cell.textLabel?.text = "退出登录"
            cell.textLabel?.textColor = .systemRed
            cell.accessoryType = .none
        }
        cell.backgroundColor = Theme.backgroundTertiary
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row)! {
        case .theme: onThemeTapped?()
        case .about: onAboutTapped?()
        case .logout: logoutTapped()
        }
    }
}
