// App/SingleConversationInfoViewController.swift
import UIKit
import Combine
import IMKit
import IMStorage

final class SingleConversationInfoViewController: UIViewController {

    var onAvatarTapped: (() -> Void)?
    var onSearchMessagesTapped: (() -> Void)?

    private let viewModel: SingleConversationInfoViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Section, Row>!

    private enum Section: Int, CaseIterable { case toggles, actions }
    private enum Row: Hashable {
        case mute(Bool)
        case stickTop(Bool)
        case searchMessages
        case clearMessages
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()

    init(viewModel: SingleConversationInfoViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "会话详情"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        layoutViews()
        configureDataSource()
        bindViewModel()
        populateHeader()
    }

    private func layoutViews() {
        // Header
        let headerView = UIView()
        avatarImageView.layer.cornerRadius = 35
        avatarImageView.clipsToBounds = true
        avatarImageView.isUserInteractionEnabled = true
        avatarImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .secondaryLabel
        nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(avatarImageView)
        headerView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
            avatarImageView.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 70),
            avatarImageView.heightAnchor.constraint(equalToConstant: 70),
            nameLabel.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 6),
            nameLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -12),
        ])
        headerView.frame = CGRect(x: 0, y: 0, width: 0, height: 120)

        // Table
        tableView.register(ToggleSwitchCell.self, forCellReuseIdentifier: ToggleSwitchCell.reuseIdentifier)
        tableView.register(NavigationRowCell.self, forCellReuseIdentifier: NavigationRowCell.reuseIdentifier)
        tableView.tableHeaderView = headerView
        tableView.delegate = self
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 0)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView, header.frame.width != tableView.bounds.width else { return }
        header.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 120)
        tableView.tableHeaderView = header
    }

    private func populateHeader() {
        let user = viewModel.userInfo()
        let displayName = user?.displayName ?? user?.name ?? viewModel.userId
        avatarImageView.setAvatar(urlString: user?.portrait, displayName: displayName)
        nameLabel.text = displayName
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView)
        }
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        switch row {
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
        case .searchMessages:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "查找聊天记录", detail: nil)
            return cell
        case .clearMessages:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "清空聊天记录", detail: nil)
            return cell
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.mute(viewModel.isMuted), .stickTop(viewModel.isTop)], toSection: .toggles)
        snapshot.appendItems([.searchMessages, .clearMessages], toSection: .actions)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func bindViewModel() {
        Publishers.Merge(
            viewModel.$isTop.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isMuted.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.applySnapshot() }
        .store(in: &cancellables)
    }

    private func handleClearMessagesTapped() {
        let alert = UIAlertController(title: "清空聊天记录", message: "清空后不可恢复，确认操作？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .destructive) { [weak self] _ in
            self?.viewModel.clearMessages { result in
                DispatchQueue.main.async {
                    if case .failure = result {
                        let err = UIAlertController(title: "清空失败", message: "请稍后重试", preferredStyle: .alert)
                        err.addAction(UIAlertAction(title: "好", style: .default))
                        self?.present(err, animated: true)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    @objc private func avatarTapped() { onAvatarTapped?() }
}

extension SingleConversationInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 50 }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { nil }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 0 : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .searchMessages: onSearchMessagesTapped?()
        case .clearMessages: handleClearMessagesTapped()
        default: break
        }
    }
}
