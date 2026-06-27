// App/GroupInfoViewController.swift
import UIKit
import Combine
import IMKit
import IMStorage

final class GroupInfoViewController: UIViewController {

    // MARK: - Navigation Callbacks (wired from SceneDelegate)
    var onAddMembersTapped: (() -> Void)?
    var onRemoveMembersTapped: (() -> Void)?
    var onMemberTapped: ((String) -> Void)?
    var onQRCodeTapped: (() -> Void)?
    var onGroupNoticeTapped: (() -> Void)?
    var onSearchMessagesTapped: (() -> Void)?

    // MARK: - Section / Row Model

    private enum Section: Int, CaseIterable {
        case groupInfo
        case messageActions
        case conversationSettings
        case personalSettings
        case dangerZone
    }

    private enum Row: Hashable {
        case groupName(String)
        case qrCode
        case groupNotice
        case searchMessages
        case mute(Bool)
        case stickTop(Bool)
        case saveToContacts(Bool)
        case myNickname
        case showMemberNicknames(Bool)
        case clearMessages
    }

    // MARK: - Properties

    private let viewModel: GroupInfoViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Section, Row>!
    private var showMemberNicknames: Bool {
        get { UserDefaults.standard.bool(forKey: showMemberNicknamesKey) }
        set { UserDefaults.standard.set(newValue, forKey: showMemberNicknamesKey) }
    }
    private var showMemberNicknamesKey: String { "showMemberNicknames_\(viewModel.group?.groupId ?? "")" }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let memberGridView = GroupMemberGridView()
    private let bottomButton = UIButton(type: .system)

    // MARK: - Init

    init(viewModel: GroupInfoViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "会话详情"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        layoutViews()
        configureDataSource()
        bindViewModel()
        viewModel.refresh()
    }

    // MARK: - Layout

    private func layoutViews() {
        // Member grid as table header
        memberGridView.onAddTapped = { [weak self] in self?.onAddMembersTapped?() }
        memberGridView.onRemoveTapped = { [weak self] in self?.onRemoveMembersTapped?() }
        memberGridView.onMemberTapped = { [weak self] uid in self?.onMemberTapped?(uid) }

        // Table view
        tableView.register(ToggleSwitchCell.self, forCellReuseIdentifier: ToggleSwitchCell.reuseIdentifier)
        tableView.register(NavigationRowCell.self, forCellReuseIdentifier: NavigationRowCell.reuseIdentifier)
        tableView.register(TextValueRowCell.self, forCellReuseIdentifier: TextValueRowCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 0)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom button
        bottomButton.setTitle("退出群组", for: .normal)
        bottomButton.setTitleColor(.white, for: .normal)
        bottomButton.backgroundColor = .systemRed
        bottomButton.layer.cornerRadius = 4
        bottomButton.titleLabel?.font = .systemFont(ofSize: 16)
        bottomButton.addTarget(self, action: #selector(bottomButtonTapped), for: .touchUpInside)
        bottomButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(bottomButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomButton.topAnchor, constant: -8),

            bottomButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bottomButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bottomButton.heightAnchor.constraint(equalToConstant: 44),
            bottomButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - DataSource

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView)
        }
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        switch row {
        case .groupName(let name):
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "群聊名称", detail: name)
            return cell

        case .qrCode:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            let qrIcon = UIImageView(image: UIImage(systemName: "qrcode"))
            qrIcon.tintColor = .label
            cell.configure(title: "二维码", detail: nil, rightView: qrIcon)
            return cell

        case .groupNotice:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "群公告", detail: nil)
            return cell

        case .searchMessages:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "查找聊天记录", detail: nil)
            return cell

        case .mute(let isOn):
            let cell = tableView.dequeueReusableCell(withIdentifier: ToggleSwitchCell.reuseIdentifier, for: indexPath) as! ToggleSwitchCell
            cell.configure(title: "消息免打扰", isOn: isOn)
            cell.onToggle = { [weak self] value in self?.viewModel.setMuted(value) }
            return cell

        case .stickTop(let isOn):
            let cell = tableView.dequeueReusableCell(withIdentifier: ToggleSwitchCell.reuseIdentifier, for: indexPath) as! ToggleSwitchCell
            cell.configure(title: "置顶聊天", isOn: isOn)
            cell.onToggle = { [weak self] value in self?.viewModel.setTop(value) }
            return cell

        case .saveToContacts(let isOn):
            let cell = tableView.dequeueReusableCell(withIdentifier: ToggleSwitchCell.reuseIdentifier, for: indexPath) as! ToggleSwitchCell
            cell.configure(title: "保存到通讯录", isOn: isOn)
            cell.onToggle = { [weak self] value in self?.viewModel.setFav(value) }
            return cell

        case .myNickname:
            let cell = tableView.dequeueReusableCell(withIdentifier: TextValueRowCell.reuseIdentifier, for: indexPath) as! TextValueRowCell
            cell.configure(title: "我在本群的昵称", value: nil)
            return cell

        case .showMemberNicknames(let isOn):
            let cell = tableView.dequeueReusableCell(withIdentifier: ToggleSwitchCell.reuseIdentifier, for: indexPath) as! ToggleSwitchCell
            cell.configure(title: "显示群成员昵称", isOn: isOn)
            cell.onToggle = { [weak self] value in
                self?.showMemberNicknames = value
                self?.applySnapshot()
            }
            return cell

        case .clearMessages:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "清空聊天记录", detail: nil)
            return cell
        }
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)

        snapshot.appendItems([
            .groupName(viewModel.group?.name ?? ""),
            .qrCode,
            .groupNotice,
        ], toSection: .groupInfo)

        snapshot.appendItems([.searchMessages], toSection: .messageActions)

        snapshot.appendItems([
            .mute(viewModel.isMuted),
            .stickTop(viewModel.isTop),
            .saveToContacts(viewModel.isFav),
        ], toSection: .conversationSettings)

        snapshot.appendItems([
            .myNickname,
            .showMemberNicknames(showMemberNicknames),
        ], toSection: .personalSettings)

        snapshot.appendItems([.clearMessages], toSection: .dangerZone)

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Binding

    private func bindViewModel() {
        Publishers.MergeMany(
            viewModel.$group.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isTop.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isMuted.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isFav.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.applySnapshot() }
        .store(in: &cancellables)

        viewModel.$members
            .combineLatest(viewModel.$canAddMembers, viewModel.$canKickMembers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] members, canAdd, canRemove in
                guard let self else { return }
                self.memberGridView.update(members: members, canAdd: canAdd, canRemove: canRemove)
                self.updateGridHeader()
            }
            .store(in: &cancellables)

        viewModel.$canDismiss
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canDismiss in
                self?.bottomButton.setTitle(canDismiss ? "解散群组" : "退出群组", for: .normal)
            }
            .store(in: &cancellables)
    }

    private func updateGridHeader() {
        memberGridView.invalidateIntrinsicContentSize()
        let size = memberGridView.intrinsicContentSize
        memberGridView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: size.height)
        tableView.tableHeaderView = memberGridView
    }

    // MARK: - Actions

    @objc private func bottomButtonTapped() {
        if viewModel.canDismiss {
            confirmAction(title: "解散群组", message: "解散后群组将不可恢复，请谨慎操作。") { [weak self] in
                self?.viewModel.dismissGroup { result in
                    DispatchQueue.main.async {
                        if case .failure = result {
                            self?.showAlert(title: "解散失败", message: "请稍后重试")
                        } else {
                            self?.navigationController?.popViewController(animated: true)
                        }
                    }
                }
            }
        } else {
            confirmAction(title: "退出群组", message: "确认退出此群组？") { [weak self] in
                self?.viewModel.quitGroup { result in
                    DispatchQueue.main.async {
                        if case .failure = result {
                            self?.showAlert(title: "退出失败", message: "请稍后重试")
                        } else {
                            self?.navigationController?.popViewController(animated: true)
                        }
                    }
                }
            }
        }
    }

    private func handleGroupNameTapped() {
        guard viewModel.canModifyInfo else { return }
        let alert = UIAlertController(title: "修改群名", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            tf.text = self?.viewModel.group?.name
            tf.placeholder = "群聊名称"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self?.viewModel.renameGroup(name) { result in
                DispatchQueue.main.async {
                    if case .failure = result { self?.showAlert(title: "修改失败", message: "请稍后重试") }
                }
            }
        })
        present(alert, animated: true)
    }

    private func handleMyNicknameTapped() {
        let alert = UIAlertController(title: "我在本群的昵称", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "输入昵称（仅本地展示）" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    private func handleClearMessagesTapped() {
        confirmAction(title: "清空聊天记录", message: "清空后不可恢复，确认操作？") { [weak self] in
            self?.viewModel.clearMessages { result in
                DispatchQueue.main.async {
                    if case .failure = result { self?.showAlert(title: "清空失败", message: "请稍后重试") }
                }
            }
        }
    }

    private func confirmAction(title: String, message: String, onConfirm: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .destructive) { _ in onConfirm() })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDelegate

extension GroupInfoViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 50 }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let spacer = UIView()
        spacer.backgroundColor = .systemGroupedBackground
        return spacer
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 0 : 10
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .groupName: handleGroupNameTapped()
        case .qrCode: onQRCodeTapped?()
        case .groupNotice: onGroupNoticeTapped?()
        case .searchMessages: onSearchMessagesTapped?()
        case .myNickname: handleMyNicknameTapped()
        case .clearMessages: handleClearMessagesTapped()
        default: break
        }
    }
}
