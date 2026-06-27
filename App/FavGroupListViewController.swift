// App/FavGroupListViewController.swift
import UIKit
import Combine
import IMKit
import IMStorage

final class FavGroupListViewController: UIViewController {

    var onGroupTapped: ((String) -> Void)?

    private let storage: IMStorage
    private var groups: [StoredGroup] = []
    private var cancellable: AnyCancellable?

    private let tableView = UITableView()

    init(storage: IMStorage) {
        self.storage = storage
        super.init(nibName: nil, bundle: nil)
        title = "群列表"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        setupTableView()
        bindStorage()
    }

    private func setupTableView() {
        tableView.register(FavGroupCell.self, forCellReuseIdentifier: FavGroupCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.rowHeight = 64
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func bindStorage() {
        cancellable = storage.groups.favGroupsPublisher()
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                self?.groups = groups
                self?.tableView.reloadData()
            }
    }
}

extension FavGroupListViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "群聊" }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FavGroupCell.reuseIdentifier, for: indexPath) as! FavGroupCell
        cell.configure(with: groups[indexPath.row])
        return cell
    }
}

extension FavGroupListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onGroupTapped?(groups[indexPath.row].groupId)
    }
}

// MARK: - Cell

final class FavGroupCell: UITableViewCell {
    static let reuseIdentifier = "FavGroupCell"

    private let avatarImageView: AvatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.backgroundPrimary

        nameLabel.font = .systemFont(ofSize: 16)
        nameLabel.textColor = Theme.textPrimary

        let stack = UIStackView(arrangedSubviews: [avatarImageView, nameLabel])
        stack.axis = NSLayoutConstraint.Axis.horizontal
        stack.spacing = 12
        stack.alignment = UIStackView.Alignment.center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 44),
            avatarImageView.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with group: StoredGroup) {
        avatarImageView.setAvatar(urlString: group.portrait, displayName: group.name)
        nameLabel.text = group.name
    }
}
