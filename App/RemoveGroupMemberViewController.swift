// App/RemoveGroupMemberViewController.swift
import UIKit
import Combine
import IMKit

/// 群信息页减号进入的「移除成员」：多选当前群成员（不含群主和自己），确认后
/// 一次请求移出。成员列表直接复用群信息页的 `GroupInfoViewModel`，资料补全、
/// 成员变更都已经由它实时驱动，这里只多维护一份勾选状态。
final class RemoveGroupMemberViewController: UIViewController {
    private let viewModel: GroupInfoViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, GroupInfoViewModel.MemberRow>!
    private var selectedUids: Set<String> = []

    private let tableView = UITableView()

    /// 移除成功后回调，由调用方关闭本页。
    var onMembersRemoved: (() -> Void)?

    init(viewModel: GroupInfoViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "移除成员"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "移除", style: .done, target: self, action: #selector(removeTapped))
        navigationItem.rightBarButtonItem?.tintColor = .systemRed
        layoutViews()
        configureDataSource()
        bindViewModel()
        updateRemoveButton()
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
        dataSource = UITableViewDiffableDataSource<Int, GroupInfoViewModel.MemberRow>(tableView: tableView) { [weak self] tableView, indexPath, member in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: ContactRow(uid: member.uid, displayName: member.displayName, avatarURL: member.avatarURL, sectionLetter: ""))
            cell.accessoryType = self?.selectedUids.contains(member.uid) == true ? .checkmark : .none
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$members
            .sink { [weak self] _ in
                // `@Published` 在赋值前发出，`removableMembers` 要等到下一拍才读得到新值。
                DispatchQueue.main.async { self?.applyMembers() }
            }
            .store(in: &cancellables)
    }

    private func applyMembers() {
        let members = viewModel.removableMembers
        // 别人先一步把某个成员移走了：勾选里也去掉，免得按钮计数对不上。
        selectedUids.formIntersection(members.map(\.uid))
        var snapshot = NSDiffableDataSourceSnapshot<Int, GroupInfoViewModel.MemberRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(members, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        let count = selectedUids.count
        navigationItem.rightBarButtonItem?.title = count > 0 ? "移除(\(count))" : "移除"
        navigationItem.rightBarButtonItem?.isEnabled = count > 0
    }

    @objc private func removeTapped() {
        let uids = viewModel.removableMembers.map(\.uid).filter { selectedUids.contains($0) }
        guard !uids.isEmpty else { return }
        let alert = UIAlertController(title: nil, message: "确定将 \(uids.count) 位成员移出群聊？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
            self?.performRemove(uids)
        })
        present(alert, animated: true)
    }

    private func performRemove(_ uids: [String]) {
        navigationItem.rightBarButtonItem?.isEnabled = false
        viewModel.kickMembers(uids) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.onMembersRemoved?()
            case .failure:
                self.updateRemoveButton()
                let alert = UIAlertController(title: "移除失败", message: "请稍后重试", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                self.present(alert, animated: true)
            }
        }
    }
}

extension RemoveGroupMemberViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let member = dataSource.itemIdentifier(for: indexPath) else { return }
        if selectedUids.contains(member.uid) {
            selectedUids.remove(member.uid)
        } else {
            selectedUids.insert(member.uid)
        }
        tableView.cellForRow(at: indexPath)?.accessoryType = selectedUids.contains(member.uid) ? .checkmark : .none
        updateRemoveButton()
    }
}
