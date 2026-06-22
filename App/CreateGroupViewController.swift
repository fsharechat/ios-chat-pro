// App/CreateGroupViewController.swift
import UIKit
import Combine
import IMKit

final class CreateGroupViewController: UIViewController {
    private let viewModel: CreateGroupViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, CreateGroupViewModel.SelectableRow>!

    private let tableView = UITableView()
    private let nameField = UITextField()

    /// `groupId`/`name` of the newly created group, for the caller to push
    /// straight into its chat screen.
    var onGroupCreated: ((_ groupId: String, _ name: String) -> Void)?

    init(viewModel: CreateGroupViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "创建群聊"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "创建", style: .done, target: self, action: #selector(createTapped))
        navigationItem.rightBarButtonItem?.isEnabled = false
        layoutViews()
        configureDataSource()
        bindViewModel()
    }

    private func layoutViews() {
        nameField.placeholder = "群聊名称"
        nameField.borderStyle = .roundedRect
        nameField.backgroundColor = Theme.backgroundSecondary
        nameField.translatesAutoresizingMaskIntoConstraints = false

        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(nameField)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, CreateGroupViewModel.SelectableRow>(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: row.contact)
            cell.accessoryType = row.isSelected ? .checkmark : .none
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$rows
            .sink { [weak self] rows in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, CreateGroupViewModel.SelectableRow>()
                snapshot.appendSections([0])
                snapshot.appendItems(rows, toSection: 0)
                self.dataSource.apply(snapshot, animatingDifferences: true)
            }
            .store(in: &cancellables)
        viewModel.$selectedCount
            .sink { [weak self] count in self?.navigationItem.rightBarButtonItem?.isEnabled = count > 0 }
            .store(in: &cancellables)
    }

    @objc private func createTapped() {
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return }
        navigationItem.rightBarButtonItem?.isEnabled = false
        viewModel.createGroup(name: name) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let groupId):
                self.onGroupCreated?(groupId, name)
            case .failure:
                self.navigationItem.rightBarButtonItem?.isEnabled = true
            }
        }
    }
}

extension CreateGroupViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.toggleSelection(uid: row.contact.uid)
    }
}
