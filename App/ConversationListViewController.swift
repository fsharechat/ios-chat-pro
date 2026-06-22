// App/ConversationListViewController.swift
import UIKit
import Combine
import IMKit

final class ConversationListViewController: UIViewController {
    private let viewModel: ConversationListViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, ConversationRow>!

    private let tableView = UITableView()

    /// Set by `SceneDelegate` — pushes the chat screen for the tapped row.
    /// A placeholder until a later plan builds the real one.
    var onConversationSelected: ((ConversationRow) -> Void)?

    /// Set by `SceneDelegate` — pushes the create-group flow.
    var onCreateGroupTapped: (() -> Void)?

    init(viewModel: ConversationListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "消息"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(createGroupTapped))
        layoutTableView()
        configureDataSource()
        bindViewModel()
    }

    @objc private func createGroupTapped() { onCreateGroupTapped?() }

    private func layoutTableView() {
        tableView.register(ConversationListCell.self, forCellReuseIdentifier: ConversationListCell.reuseIdentifier)
        tableView.delegate = self
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
        dataSource = UITableViewDiffableDataSource<Int, ConversationRow>(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ConversationListCell.reuseIdentifier, for: indexPath) as! ConversationListCell
            cell.configure(with: row)
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$rows
            .sink { [weak self] rows in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, ConversationRow>()
                snapshot.appendSections([0])
                snapshot.appendItems(rows, toSection: 0)
                self.dataSource.apply(snapshot, animatingDifferences: true)
            }
            .store(in: &cancellables)
    }
}

extension ConversationListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        onConversationSelected?(row)
    }
}
