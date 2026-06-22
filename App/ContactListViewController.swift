// App/ContactListViewController.swift
import UIKit
import Combine
import IMKit

/// `UITableViewDiffableDataSource` doesn't provide section headers or the
/// native A-Z index sidebar by default — both require overriding these
/// three `UITableViewDataSource` methods on a subclass (per Apple's
/// documented pattern for diffable data sources + index titles).
final class ContactListDataSource: UITableViewDiffableDataSource<String, ContactRow> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        snapshot().sectionIdentifiers[section]
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        let titles = snapshot().sectionIdentifiers
        return titles.isEmpty ? nil : titles
    }

    override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        snapshot().sectionIdentifiers.firstIndex(of: title) ?? 0
    }
}

final class ContactListViewController: UIViewController {
    private let viewModel: ContactListViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: ContactListDataSource!

    private let tableView = UITableView()
    private let newFriendsEntryView = NewFriendsEntryView()

    /// Set by `SceneDelegate` — pushes the chat screen for the tapped contact.
    var onContactSelected: ((ContactRow) -> Void)?

    /// Set by `SceneDelegate` — pushes `NewFriendsViewController`.
    var onNewFriendsEntryTapped: (() -> Void)?

    init(viewModel: ContactListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "联系人"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutTableView()
        configureDataSource()
        bindViewModel()
        newFriendsEntryView.onTapped = { [weak self] in self?.onNewFriendsEntryTapped?() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        newFriendsEntryView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 56)
        tableView.tableHeaderView = newFriendsEntryView
    }

    private func layoutTableView() {
        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.sectionIndexColor = Theme.accent
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
        dataSource = ContactListDataSource(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: row)
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$sections
            .sink { [weak self] sections in self?.applySnapshot(sections: sections) }
            .store(in: &cancellables)
        viewModel.$unreadFriendRequestCount
            .sink { [weak self] count in self?.newFriendsEntryView.setUnreadCount(count) }
            .store(in: &cancellables)
    }

    private func applySnapshot(sections: [(letter: String, rows: [ContactRow])]) {
        var snapshot = NSDiffableDataSourceSnapshot<String, ContactRow>()
        snapshot.appendSections(sections.map { $0.letter })
        for section in sections {
            snapshot.appendItems(section.rows, toSection: section.letter)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

extension ContactListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        onContactSelected?(row)
    }
}
