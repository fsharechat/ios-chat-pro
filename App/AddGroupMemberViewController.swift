// App/AddGroupMemberViewController.swift
import UIKit
import Combine
import IMKit

final class AddGroupMemberViewController: UIViewController {
    private let viewModel: AddGroupMemberViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, AddGroupMemberViewModel.SelectableRow>!

    private let tableView = UITableView()

    /// Fired after a successful `addSelectedMembers` call, so the caller
    /// (`GroupInfoViewController`) can dismiss this screen.
    var onMembersAdded: (() -> Void)?

    init(viewModel: AddGroupMemberViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "添加成员"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "添加", style: .done, target: self, action: #selector(addTapped))
        navigationItem.rightBarButtonItem?.isEnabled = false
        layoutViews()
        configureDataSource()
        bindViewModel()
    }

    private func layoutViews() {
        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
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
        dataSource = UITableViewDiffableDataSource<Int, AddGroupMemberViewModel.SelectableRow>(tableView: tableView) { tableView, indexPath, row in
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
                var snapshot = NSDiffableDataSourceSnapshot<Int, AddGroupMemberViewModel.SelectableRow>()
                snapshot.appendSections([0])
                snapshot.appendItems(rows, toSection: 0)
                self.dataSource.apply(snapshot, animatingDifferences: true)
            }
            .store(in: &cancellables)
        viewModel.$selectedCount
            .sink { [weak self] count in self?.navigationItem.rightBarButtonItem?.isEnabled = count > 0 }
            .store(in: &cancellables)
    }

    @objc private func addTapped() {
        navigationItem.rightBarButtonItem?.isEnabled = false
        viewModel.addSelectedMembers { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.onMembersAdded?()
            case .failure:
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.presentResultAlert(title: "添加失败", message: "请稍后重试")
            }
        }
    }

    private func presentResultAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

extension AddGroupMemberViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.toggleSelection(uid: row.contact.uid)
    }
}
