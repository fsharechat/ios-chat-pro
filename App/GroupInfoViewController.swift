// App/GroupInfoViewController.swift
import UIKit
import Combine
import IMKit

final class GroupInfoViewController: UIViewController {
    private let viewModel: GroupInfoViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, GroupInfoViewModel.MemberRow>!

    private let tableView = UITableView()
    private let quitButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private lazy var addMembersButton = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addMembersTapped))

    /// Fired when the user taps the add-members bar button. The actual
    /// `AddGroupMemberViewModel`/`AddGroupMemberViewController` construction
    /// happens in `SceneDelegate` (this view controller only holds a
    /// `GroupInfoViewModel`, which doesn't expose the storage/acting/syncing
    /// dependencies needed to build them) — matching the established
    /// "closure wired from SceneDelegate" cross-screen navigation pattern
    /// used elsewhere in this codebase.
    var onAddMembersTapped: (() -> Void)?

    init(viewModel: GroupInfoViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "群信息"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        configureDataSource()
        bindViewModel()
        viewModel.refresh()
    }

    private func layoutViews() {
        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.translatesAutoresizingMaskIntoConstraints = false

        quitButton.setTitle("退出该群", for: .normal)
        quitButton.setTitleColor(.systemRed, for: .normal)
        quitButton.addTarget(self, action: #selector(quitTapped), for: .touchUpInside)
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.setTitle("解散该群", for: .normal)
        dismissButton.setTitleColor(.systemRed, for: .normal)
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(quitButton)
        view.addSubview(dismissButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: quitButton.topAnchor, constant: -8),

            quitButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            quitButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            quitButton.heightAnchor.constraint(equalToConstant: 44),

            dismissButton.topAnchor.constraint(equalTo: quitButton.bottomAnchor, constant: 4),
            dismissButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            dismissButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            dismissButton.heightAnchor.constraint(equalToConstant: 44),
            dismissButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, GroupInfoViewModel.MemberRow>(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: ContactRow(uid: row.uid, displayName: row.isOwner ? "👑 \(row.displayName)" : row.displayName, avatarURL: row.avatarURL, sectionLetter: ""))
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$members
            .sink { [weak self] members in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, GroupInfoViewModel.MemberRow>()
                snapshot.appendSections([0])
                snapshot.appendItems(members, toSection: 0)
                self.dataSource.apply(snapshot, animatingDifferences: true)
            }
            .store(in: &cancellables)

        viewModel.$group
            .sink { [weak self] group in self?.title = group?.name ?? "群信息" }
            .store(in: &cancellables)

        viewModel.$canDismiss
            .sink { [weak self] canDismiss in self?.dismissButton.isHidden = !canDismiss }
            .store(in: &cancellables)

        viewModel.$canAddMembers
            .sink { [weak self] canAddMembers in
                guard let self else { return }
                self.navigationItem.rightBarButtonItem = canAddMembers ? self.addMembersButton : nil
            }
            .store(in: &cancellables)

        // Quit is always allowed per the design doc's permission matrix
        // (every `GroupType` permits self-removal) — `quitButton` has no
        // corresponding `@Published` gate to hide it.
    }

    @objc private func addMembersTapped() {
        onAddMembersTapped?()
    }

    @objc private func quitTapped() {
        viewModel.quitGroup { [weak self] result in
            switch result {
            case .success:
                self?.navigationController?.popViewController(animated: true)
            case .failure:
                self?.presentResultAlert(title: "退出失败", message: "请稍后重试")
            }
        }
    }

    @objc private func dismissTapped() {
        viewModel.dismissGroup { [weak self] result in
            switch result {
            case .success:
                self?.navigationController?.popViewController(animated: true)
            case .failure:
                self?.presentResultAlert(title: "解散失败", message: "请稍后重试")
            }
        }
    }

    private func presentResultAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

extension GroupInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard viewModel.canKickMembers, let row = dataSource.itemIdentifier(for: indexPath), !row.isOwner else { return nil }
        let kick = UIContextualAction(style: .destructive, title: "移出") { [weak self] _, _, completion in
            self?.viewModel.kickMember(row.uid) { result in
                if case .failure = result {
                    self?.presentResultAlert(title: "移出失败", message: "请稍后重试")
                }
                completion(true)
            }
        }
        return UISwipeActionsConfiguration(actions: [kick])
    }
}
