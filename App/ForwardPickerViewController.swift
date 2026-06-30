// App/ForwardPickerViewController.swift
import UIKit
import Combine
import IMKit

final class ForwardPickerViewController: UIViewController {
    private let sourceMessage: StoredMessageRow
    private let viewModel: ConversationListViewModel
    private var cancellables = Set<AnyCancellable>()
    private var allRows: [ConversationRow] = []
    private var dataSource: UITableViewDiffableDataSource<Int, ConversationRow>!

    private let tableView = UITableView()
    private let searchBar = UISearchBar()

    /// Called after the user confirms the forward (preview sheet sent).
    /// Arguments: target conversation row, optional 留言 note.
    var onConfirmForward: ((ConversationRow, String?) -> Void)?

    init(sourceMessage: StoredMessageRow, viewModel: ConversationListViewModel) {
        self.sourceMessage = sourceMessage
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "转发"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )
        layoutViews()
        configureDataSource()
        bindViewModel()
    }

    @objc private func cancelTapped() {
        navigationController?.popViewController(animated: true)
    }

    private func layoutViews() {
        searchBar.placeholder = "搜索"
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false

        tableView.register(ConversationListCell.self, forCellReuseIdentifier: ConversationListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchBar)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rows in
                self?.allRows = rows
                self?.applyFilter(query: self?.searchBar.text ?? "")
            }
            .store(in: &cancellables)
    }

    private func applyFilter(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? allRows : allRows.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
        var snapshot = NSDiffableDataSourceSnapshot<Int, ConversationRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(filtered)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension ForwardPickerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let targetRow = dataSource.itemIdentifier(for: indexPath) else { return }
        let previewVC = ForwardPreviewViewController(targetRow: targetRow, sourceMessage: sourceMessage)
        previewVC.onSend = { [weak self] note in
            self?.onConfirmForward?(targetRow, note)
        }
        present(previewVC, animated: true)
    }
}

extension ForwardPickerViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applyFilter(query: searchText)
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
