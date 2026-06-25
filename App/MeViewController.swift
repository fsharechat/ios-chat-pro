// App/MeViewController.swift
import UIKit
import Combine
import IMKit

final class MeViewController: UIViewController {
    private let viewModel: MyProfileViewModel
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerView = UIView()
    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let displayNameLabel = UILabel()

    /// Set by `SceneDelegate` — pushes `MyProfileViewController`.
    var onProfileCardTapped: (() -> Void)?

    /// Set by `SceneDelegate` — pushes `SettingsViewController`.
    var onSettingsTapped: (() -> Void)?

    init(viewModel: MyProfileViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "我的"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        bindViewModel()
    }

    private func layoutViews() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        displayNameLabel.font = .systemFont(ofSize: 17, weight: .medium)
        displayNameLabel.textColor = Theme.textPrimary
        displayNameLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.isUserInteractionEnabled = true
        headerView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(profileCardTapped)))
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(avatarImageView)
        headerView.addSubview(displayNameLabel)
        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            avatarImageView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 56),
            avatarImageView.heightAnchor.constraint(equalToConstant: 56),

            displayNameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            displayNameLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
        ])
        headerView.frame = CGRect(x: 0, y: 0, width: 0, height: 88)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.tableHeaderView = headerView
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard tableView.tableHeaderView?.frame.width != tableView.bounds.width else { return }
        headerView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 88)
        tableView.tableHeaderView = headerView
    }

    private func bindViewModel() {
        viewModel.$displayName
            .combineLatest(viewModel.$avatarURL)
            .sink { [weak self] displayName, avatarURL in
                guard let self else { return }
                self.displayNameLabel.text = displayName
                self.avatarImageView.setAvatar(urlString: avatarURL, displayName: displayName)
            }
            .store(in: &cancellables)
    }

    @objc private func profileCardTapped() {
        onProfileCardTapped?()
    }
}

extension MeViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        cell.textLabel?.text = "设置"
        cell.textLabel?.textColor = Theme.textPrimary
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSettingsTapped?()
    }
}
