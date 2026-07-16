// App/GroupMemberGridView.swift
import UIKit
import IMKit

final class GroupMemberGridView: UIView {

    var onAddTapped: (() -> Void)?
    var onRemoveTapped: (() -> Void)?
    var onMemberTapped: ((String) -> Void)?

    private enum Item: Hashable {
        case member(String)   // uid
        case add
        case remove
    }

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var members: [GroupInfoViewModel.MemberRow] = []
    private var canAdd = false
    private var canRemove = false

    private static let columns = 5
    private static let cellSize: CGFloat = 60
    private static let spacing: CGFloat = 4
    private static let hPadding: CGFloat = 20
    private static let vPadding: CGFloat = 12

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.itemSize = CGSize(width: Self.cellSize, height: Self.cellSize + 20)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        backgroundColor = .systemGroupedBackground
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.isScrollEnabled = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor, constant: Self.vPadding),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPadding),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hPadding),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.vPadding),
        ])
        collectionView.register(MemberCell.self, forCellWithReuseIdentifier: "MemberCell")
        collectionView.register(ActionCell.self, forCellWithReuseIdentifier: "ActionCell")
        collectionView.delegate = self

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, indexPath, item in
            switch item {
            case .member(let uid):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "MemberCell", for: indexPath) as! MemberCell
                let member = self?.members.first { $0.uid == uid }
                cell.configure(displayName: member?.displayName ?? uid, avatarURL: member?.avatarURL, isOwner: member?.isOwner ?? false)
                return cell
            case .add:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "ActionCell", for: indexPath) as! ActionCell
                cell.configure(systemName: "plus")
                return cell
            case .remove:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "ActionCell", for: indexPath) as! ActionCell
                cell.configure(systemName: "minus")
                return cell
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(members: [GroupInfoViewModel.MemberRow], canAdd: Bool, canRemove: Bool) {
        self.members = members
        self.canAdd = canAdd
        self.canRemove = canRemove
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(members.map { .member($0.uid) })
        if canAdd { snapshot.appendItems([.add]) }
        if canRemove { snapshot.appendItems([.remove]) }
        dataSource.apply(snapshot, animatingDifferences: false)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let totalItems = members.count + (canAdd ? 1 : 0) + (canRemove ? 1 : 0)
        let rows = max(1, Int(ceil(Double(totalItems) / Double(Self.columns))))
        let cellHeight = Self.cellSize + 20
        let height = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * Self.spacing + Self.vPadding * 2
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }
}

extension GroupMemberGridView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .member(let uid): onMemberTapped?(uid)
        case .add: onAddTapped?()
        case .remove: onRemoveTapped?()
        }
    }
}

// MARK: - Private Cells

private final class MemberCell: UICollectionViewCell {
    private let avatarView = AvatarImageView(loader: AvatarLoader.shared)
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarView)
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            avatarView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 48),
            avatarView.heightAnchor.constraint(equalToConstant: 48),
            nameLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(displayName: String, avatarURL: String?, isOwner: Bool) {
        avatarView.setAvatar(urlString: avatarURL, displayName: displayName)
        nameLabel.text = isOwner ? "👑\(displayName)" : displayName
    }
}

private final class ActionCell: UICollectionViewCell {
    private let iconContainer = UIView()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconContainer.layer.cornerRadius = 24
        iconContainer.layer.borderWidth = 1
        iconContainer.layer.borderColor = UIColor.separator.cgColor
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .label
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconContainer)
        iconContainer.addSubview(imageView)
        NSLayoutConstraint.activate([
            iconContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            iconContainer.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 48),
            iconContainer.heightAnchor.constraint(equalToConstant: 48),
            imageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(systemName: String) {
        imageView.image = UIImage(systemName: systemName)
    }
}
