// App/NewFriendsViewController.swift
import UIKit
import Combine
import IMKit

final class NewFriendsViewController: UIViewController {
    private let viewModel: NewFriendsViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, NewFriendsViewModel.FriendRequestRow>!

    private let tableView = UITableView()

    /// Set by `SceneDelegate` — pushes `SearchUserViewController`.
    var onAddFriendTapped: (() -> Void)?

    init(viewModel: NewFriendsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "新的朋友"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(handleAddTapped))
        layoutTableView()
        configureDataSource()
        bindViewModel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.refresh()
    }

    private func layoutTableView() {
        tableView.register(FriendRequestCell.self, forCellReuseIdentifier: FriendRequestCell.reuseIdentifier)
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: FriendRequestCell.reuseIdentifier, for: indexPath) as! FriendRequestCell
            cell.configure(with: row)
            cell.onAcceptTapped = { self?.viewModel.accept(fromUid: row.fromUid) }
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$rows
            .sink { [weak self] rows in self?.applySnapshot(rows: rows) }
            .store(in: &cancellables)
    }

    private func applySnapshot(rows: [NewFriendsViewModel.FriendRequestRow]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, NewFriendsViewModel.FriendRequestRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @objc private func handleAddTapped() {
        onAddFriendTapped?()
    }
}
