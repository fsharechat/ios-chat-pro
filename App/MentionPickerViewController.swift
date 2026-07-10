import UIKit
import IMKit

/// 输入框敲 "@" 后弹出的选人页，Android 样式：「所有人」置顶（空
/// section、不显示 header、不进右侧索引），成员按拼音首字母分组 +
/// 头像 + 右侧字母索引。回调里 `uid == nil` 表示选了「所有人」。
final class MentionPickerViewController: UIViewController {

    /// diffable 快照的行类型：置顶「所有人」或普通成员行。
    fileprivate enum Item: Hashable {
        case all
        case member(ContactRow)
    }

    /// 空字符串 section 承载「所有人」；header 与索引条都要跳过它，
    /// 这是不能用 `ContactListDataSource` 直接复用的原因。
    private final class DataSource: UITableViewDiffableDataSource<String, Item> {
        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            let id = snapshot().sectionIdentifiers[section]
            return id.isEmpty ? nil : id
        }

        override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
            let titles = snapshot().sectionIdentifiers.filter { !$0.isEmpty }
            return titles.isEmpty ? nil : titles
        }

        override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
            snapshot().sectionIdentifiers.firstIndex(of: title) ?? 0
        }
    }

    private let sections: [(letter: String, rows: [ContactRow])]
    private let tableView = UITableView()
    private var dataSource: DataSource!

    var onPicked: ((_ uid: String?, _ displayName: String) -> Void)?
    /// 通过取消按钮关闭（而非选中某行）时回调 — 让调用方清掉输入框里
    /// 悬空的触发 "@"。
    var onCancelled: (() -> Void)?

    init(members: [MentionCandidate]) {
        let rows = members.map { candidate in
            ContactRow(
                uid: candidate.uid,
                displayName: candidate.displayName,
                avatarURL: candidate.avatarURL,
                sectionLetter: PinyinIndexer.sectionLetter(for: candidate.displayName)
            )
        }
        sections = PinyinIndexer.sections(of: rows, name: \.displayName)
            .map { (letter: $0.letter, rows: $0.items) }
        super.init(nibName: nil, bundle: nil)
        title = "选择群成员"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.register(MentionAllCell.self, forCellReuseIdentifier: MentionAllCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.sectionIndexColor = Theme.accent
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        dataSource = DataSource(tableView: tableView) { tableView, indexPath, item in
            switch item {
            case .all:
                return tableView.dequeueReusableCell(withIdentifier: MentionAllCell.reuseIdentifier, for: indexPath)
            case .member(let row):
                let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
                cell.configure(with: row)
                return cell
            }
        }
        applySnapshot()
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
        snapshot.appendSections([""])
        snapshot.appendItems([.all], toSection: "")
        snapshot.appendSections(sections.map { $0.letter })
        for section in sections {
            snapshot.appendItems(section.rows.map { .member($0) }, toSection: section.letter)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func cancelTapped() {
        onCancelled?()
        dismiss(animated: true)
    }
}

extension MentionPickerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .all:
            onPicked?(nil, "所有人")
        case .member(let row):
            onPicked?(row.uid, row.displayName)
        }
    }
}

/// 置顶的「所有人」行：蓝底群像图标 + 文字，布局尺寸对齐 `ContactListCell`。
private final class MentionAllCell: UITableViewCell {
    static let reuseIdentifier = "MentionAllCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.backgroundSecondary

        let iconContainer = UIView()
        iconContainer.backgroundColor = .systemBlue
        iconContainer.layer.cornerRadius = 20
        iconContainer.clipsToBounds = true
        iconContainer.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(systemName: "person.3.fill"))
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        let nameLabel = UILabel()
        nameLabel.text = "所有人"
        nameLabel.font = .systemFont(ofSize: 16, weight: .regular)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconContainer)
        contentView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),
            iconContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            iconContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            nameLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
