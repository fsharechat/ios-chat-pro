// App/MeViewController.swift
import UIKit
import Combine
import IMKit

/// Owns its own `AvatarImageView`/name label so each dequeued instance is
/// self-contained — sharing one avatar/label across cell instances (moving
/// them between `contentView`s) leaves stale Auto Layout constraints
/// pointing at a previous cell's `contentView`, which UIKit rejects at
/// activation time ("no common ancestor").
private final class ProfileCell: UITableViewCell {
    private let avatarImageView = AvatarImageView(loader: AvatarLoader.shared)
    private let displayNameLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        displayNameLabel.font = .systemFont(ofSize: 17, weight: .medium)
        displayNameLabel.textColor = Theme.textPrimary
        displayNameLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarImageView)
        contentView.addSubview(displayNameLabel)
        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 56),
            avatarImageView.heightAnchor.constraint(equalToConstant: 56),

            displayNameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            displayNameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        accessoryType = .disclosureIndicator
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(displayName: String, avatarURL: String?) {
        displayNameLabel.text = displayName
        avatarImageView.setAvatar(urlString: avatarURL, displayName: displayName)
    }
}

final class MeViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case profile
        case settings
    }

    private let viewModel: MyProfileViewModel
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

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
        tableView.register(ProfileCell.self, forCellReuseIdentifier: "profile")
        tableView.dataSource = self
        tableView.delegate = self
        // The "list" tier — distinct from the cards' "card" tier below — is
        // what makes the profile card and the settings card read as two
        // separate, separated sections instead of one undifferentiated block.
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

    private func bindViewModel() {
        viewModel.$displayName
            .combineLatest(viewModel.$avatarURL)
            .sink { [weak self] _, _ in
                self?.tableView.reloadRows(at: [IndexPath(row: 0, section: Section.profile.rawValue)], with: .none)
            }
            .store(in: &cancellables)
    }
}

extension MeViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        Section(rawValue: indexPath.section) == .profile ? 76 : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        switch Section(rawValue: indexPath.section)! {
        case .profile:
            let profileCell = tableView.dequeueReusableCell(withIdentifier: "profile", for: indexPath) as! ProfileCell
            profileCell.configure(displayName: viewModel.displayName, avatarURL: viewModel.avatarURL)
            cell = profileCell
        case .settings:
            cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
            cell.textLabel?.text = "设置"
            cell.textLabel?.textColor = Theme.textPrimary
            cell.accessoryType = .disclosureIndicator
        }
        cell.backgroundColor = Theme.backgroundTertiary
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .profile: onProfileCardTapped?()
        case .settings: onSettingsTapped?()
        }
    }
}
