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

    /// Set by `SceneDelegate` — the three "+" menu entries.
    var onStartChatTapped: (() -> Void)?
    var onAddFriendTapped: (() -> Void)?
    var onScanTapped: (() -> Void)?

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
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(plusTapped))
        layoutTableView()
        configureDataSource()
        bindViewModel()
    }

    @objc private func plusTapped() {
        guard let hostView = navigationController?.view else { return }
        PlusMenuView.show(in: hostView, items: [
            .init(symbolName: "ellipsis.message", title: "发起聊天") { [weak self] in self?.onStartChatTapped?() },
            .init(symbolName: "person.badge.plus", title: "添加朋友") { [weak self] in self?.onAddFriendTapped?() },
            .init(symbolName: "qrcode.viewfinder", title: "扫一扫") { [weak self] in self?.onScanTapped?() },
        ])
    }

    private func layoutTableView() {
        tableView.register(ConversationListCell.self, forCellReuseIdentifier: ConversationListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(rowLongPressed(_:))))
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.showsVerticalScrollIndicator = false
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
                // 微信风格：来新消息/顺序变化直接刷新，不带切换动画。
                self.dataSource.apply(snapshot, animatingDifferences: false)
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

private extension ConversationListViewController {
    @objc func rowLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let indexPath = tableView.indexPathForRow(at: recognizer.location(in: tableView)),
              let row = dataSource.itemIdentifier(for: indexPath),
              let hostView = navigationController?.view else { return }
        let anchorRect = tableView.convert(tableView.rectForRow(at: indexPath), to: hostView)
        PlusMenuView.show(in: hostView, anchorRect: anchorRect, items: makeMenuItems(for: row))
    }

    func makeMenuItems(for row: ConversationRow) -> [PlusMenuView.Item] {
        let pinTitle = row.isTop ? "取消置顶" : "置顶"
        let pinSymbol = row.isTop ? "pin.slash" : "pin"
        return [
            .init(symbolName: pinSymbol, title: pinTitle) { [weak self] in
                do {
                    try self?.viewModel.setTop(!row.isTop, for: row)
                } catch {
                    self?.showStorageError(error)
                }
            },
            .init(symbolName: "trash", title: "清空会话", isDestructive: true) { [weak self] in
                self?.confirmDestructive(title: "清空会话") {
                    try self?.viewModel.clearConversation(row)
                }
            },
            .init(symbolName: "xmark.circle", title: "删除会话", isDestructive: true) { [weak self] in
                self?.confirmDestructive(title: "删除会话") {
                    try self?.viewModel.deleteConversation(row)
                }
            },
        ]
    }

    func confirmDestructive(title: String, action: @escaping () throws -> Void) {
        let alert = UIAlertController(title: title, message: "此操作不可撤销。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .destructive) { [weak self] _ in
            do {
                try action()
            } catch {
                self?.showStorageError(error)
            }
        })
        present(alert, animated: true)
    }

    func showStorageError(_ error: Error) {
        let alert = UIAlertController(title: "操作失败", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
