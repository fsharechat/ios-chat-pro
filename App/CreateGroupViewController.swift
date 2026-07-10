// App/CreateGroupViewController.swift
import UIKit
import Combine
import IMKit

/// "发起聊天" contact picker, aligned with Android's
/// `CreateConversationActivity`: picking one contact opens a single chat,
/// picking several auto-names and creates a group (no name field).
final class CreateGroupViewController: UIViewController {
    /// Same three overrides as `ContactListDataSource` — section headers and
    /// the native A-Z index sidebar require subclassing the diffable data
    /// source (Apple's documented pattern).
    private final class DataSource: UITableViewDiffableDataSource<String, CreateGroupViewModel.SelectableRow> {
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

    private let viewModel: CreateGroupViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: DataSource!

    private let tableView = UITableView()

    /// Exactly one contact picked — caller opens the single chat.
    var onSinglePicked: ((_ uid: String) -> Void)?

    /// `groupId`/`name` of the newly created group, for the caller to push
    /// straight into its chat screen.
    var onGroupCreated: ((_ groupId: String, _ name: String) -> Void)?

    init(viewModel: CreateGroupViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "发起聊天"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "确定", style: .done, target: self, action: #selector(confirmTapped))
        navigationItem.rightBarButtonItem?.isEnabled = false
        layoutViews()
        configureDataSource()
        bindViewModel()
    }

    private func layoutViews() {
        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.sectionIndexColor = Theme.accent
        tableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = DataSource(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: row.contact)
            cell.accessoryType = row.isSelected ? .checkmark : .none
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$sections
            .sink { [weak self] sections in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<String, CreateGroupViewModel.SelectableRow>()
                snapshot.appendSections(sections.map { $0.letter })
                for section in sections {
                    snapshot.appendItems(section.rows, toSection: section.letter)
                }
                self.dataSource.apply(snapshot, animatingDifferences: false)
            }
            .store(in: &cancellables)
        viewModel.$selectedCount
            .sink { [weak self] count in
                self?.navigationItem.rightBarButtonItem?.isEnabled = count > 0
                self?.navigationItem.rightBarButtonItem?.title = count > 1 ? "确定(\(count))" : "确定"
            }
            .store(in: &cancellables)
    }

    @objc private func confirmTapped() {
        navigationItem.rightBarButtonItem?.isEnabled = false
        viewModel.startChat { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.single(let uid)):
                self.onSinglePicked?(uid)
            case .success(.group(let groupId, let name)):
                self.onGroupCreated?(groupId, name)
            case .failure:
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.presentResultAlert(title: "创建失败", message: "请稍后重试")
            }
        }
    }

    private func presentResultAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

extension CreateGroupViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.toggleSelection(uid: row.contact.uid)
    }
}
