// App/SearchUserViewController.swift
import UIKit
import Combine
import IMKit

final class SearchUserViewController: UIViewController {
    private let viewModel: SearchUserViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, ContactRow>!
    private var searchGeneration = 0

    private let searchBar = UISearchBar()
    private let tableView = UITableView()

    init(viewModel: SearchUserViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "添加朋友"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        configureDataSource()
        bindViewModel()
    }

    private func layoutViews() {
        searchBar.placeholder = "搜索 UID 或手机号"
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false

        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchBar)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: row)
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$results
            .sink { [weak self] results in self?.applySnapshot(results: results) }
            .store(in: &cancellables)
    }

    private func applySnapshot(results: [ContactRow]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ContactRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(results, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func presentReasonPrompt(for row: ContactRow) {
        let alert = UIAlertController(title: "添加朋友", message: "向 \(row.displayName) 发送好友请求", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "验证消息（可选）"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "发送", style: .default) { [weak self, weak alert] _ in
            let reason = alert?.textFields?.first?.text ?? ""
            self?.sendFriendRequest(to: row.uid, reason: reason)
        })
        present(alert, animated: true)
    }

    private func sendFriendRequest(to uid: String, reason: String) {
        viewModel.sendFriendRequest(to: uid, reason: reason) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.presentResultAlert(title: "已发送", message: "好友请求已发送", dismissAfter: true)
                case .failure:
                    self?.presentResultAlert(title: "发送失败", message: "请稍后重试", dismissAfter: false)
                }
            }
        }
    }

    private func presentResultAlert(title: String, message: String, dismissAfter: Bool) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            if dismissAfter { self?.navigationController?.popViewController(animated: true) }
        })
        present(alert, animated: true)
    }
}

extension SearchUserViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchGeneration += 1
        let generation = searchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.searchGeneration == generation else { return }
            self.viewModel.search(keyword: searchText)
        }
    }
}

extension SearchUserViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        presentReasonPrompt(for: row)
    }
}
