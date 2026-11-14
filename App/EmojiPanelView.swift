// App/EmojiPanelView.swift
import UIKit

final class EmojiPanelView: UIView {
    static let panelHeight: CGFloat = 260

    var onEmojiTapped: ((String) -> Void)?
    var onDeleteTapped: (() -> Void)?

    private static let emojis: [String] = [
        "😃","😀","😊","☺️","😉","😍","😘","😙","😜","😝","😒","😌","😔","😞","😟",
        "😠","😡","😢","😂","😪","😥","😰","😓","😭","😖","😣","😤","😩","😫","😨",
        "😱","😵","😲","😳","😯","😴","😷","😎","😆","😋","😛","😃","😀","😒","😏",
        "😸","😹","😺","😻","😼","😽","🙀","😿","😾","🙈","🙉","🙊","💀","👽","💩",
        "🔥","✨","🌟","💫","💥","💢","💦","💧","💤","👂","👀","👃","👅","👄","👍",
        "👎","👌","👊","✊","✌️","👋","✋","👐","👆","👇","👉","👈","🙌","🙏","☝️",
        "👏","💪","🚶","🏃","💃","👫","👪","👬","👭","💏","💑","👶","👦","👧","👱",
        "👩","👴","👵","👲","👳","👮","👷","💂","🎅","👸","👰","🎩","👑","💼","👜",
        "👝","🎒","💰","💳","📱","📷","📚","✏️","🏠","💡","📢","⏰","⏳","💣","💊","🌍"
    ]
    // 每页 20 个表情 + 1 退格键 = 21 格；7列 × 3行
    private static let columns = 7
    private static let rows = 3
    private static let perPage = columns * rows - 1  // 20

    private lazy var collectionView: UICollectionView = {
        let layout = EmojiPagedLayout()
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.isPagingEnabled = true
        cv.showsHorizontalScrollIndicator = false
        cv.backgroundColor = .clear
        cv.register(EmojiCell.self, forCellWithReuseIdentifier: "EmojiCell")
        cv.dataSource = self
        cv.delegate = self
        return cv
    }()

    private let pageControl = UIPageControl()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        layer.cornerRadius = 22
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true
        addSubview(collectionView)
        addSubview(pageControl)
        pageControl.currentPageIndicatorTintColor = Theme.accent
        pageControl.pageIndicatorTintColor = Theme.accent.withAlphaComponent(0.3)
        let pageCount = Int(ceil(Double(Self.emojis.count) / Double(Self.perPage)))
        pageControl.numberOfPages = pageCount
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        // These internal constraints must yield to panelContainer.height=0 (required).
        // Priority 999 lets the parent collapse to 0 without unsatisfiable-constraint warnings.
        let cvTop = collectionView.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        let cvBottom = collectionView.bottomAnchor.constraint(equalTo: pageControl.topAnchor, constant: -4)
        let pcBottom = pageControl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        let pcHeight = pageControl.heightAnchor.constraint(equalToConstant: 20)
        for c in [cvTop, cvBottom, pcBottom, pcHeight] { c.priority = UILayoutPriority(999) }
        NSLayoutConstraint.activate([
            cvTop,
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cvBottom,
            pageControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            pcBottom,
            pcHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }


}

extension EmojiPanelView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let pages = Int(ceil(Double(Self.emojis.count) / Double(Self.perPage)))
        return pages * (Self.perPage + 1)  // 每页 21 格（含退格）
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EmojiCell", for: indexPath) as! EmojiCell
        let pageIndex = indexPath.item / (Self.perPage + 1)
        let itemInPage = indexPath.item % (Self.perPage + 1)
        if itemInPage == Self.perPage {
            cell.configure(emoji: nil, isDelete: true)
        } else {
            let emojiIndex = pageIndex * Self.perPage + itemInPage
            let emoji = emojiIndex < Self.emojis.count ? Self.emojis[emojiIndex] : nil
            cell.configure(emoji: emoji, isDelete: false)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let itemInPage = indexPath.item % (Self.perPage + 1)
        if itemInPage == Self.perPage {
            onDeleteTapped?()
        } else {
            let pageIndex = indexPath.item / (Self.perPage + 1)
            let emojiIndex = pageIndex * Self.perPage + itemInPage
            guard emojiIndex < Self.emojis.count else { return }
            onEmojiTapped?(Self.emojis[emojiIndex])
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        let page = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        pageControl.currentPage = page
    }
}

private final class EmojiCell: UICollectionViewCell {
    private let label = UILabel()
    private let deleteLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 26)
        label.textAlignment = .center
        deleteLabel.text = "⌫"
        deleteLabel.font = .systemFont(ofSize: 20)
        deleteLabel.textAlignment = .center
        deleteLabel.textColor = Theme.textSecondary
        for v in [label, deleteLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                v.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(emoji: String?, isDelete: Bool) {
        label.isHidden = isDelete || emoji == nil
        deleteLabel.isHidden = !isDelete
        label.text = emoji
        isAccessibilityElement = emoji != nil || isDelete
        accessibilityLabel = isDelete ? "删除" : emoji
        accessibilityTraits = .button
    }
}

/// Row-major pages. A horizontal flow layout otherwise fills columns before rows and splits pages.
private final class EmojiPagedLayout: UICollectionViewLayout {
    private var attributes: [UICollectionViewLayoutAttributes] = []
    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let size = collectionView.bounds.size
        attributes = (0..<collectionView.numberOfItems(inSection: 0)).map { index in
            let item = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            let position = index % 21
            item.frame = CGRect(x: CGFloat(index / 21) * size.width + CGFloat(position % 7) * size.width / 7,
                                y: CGFloat(position / 7) * size.height / 3,
                                width: size.width / 7, height: size.height / 3)
            return item
        }
    }
    override var collectionViewContentSize: CGSize {
        guard let collectionView else { return .zero }
        let pages = (collectionView.numberOfItems(inSection: 0) + 20) / 21
        return CGSize(width: CGFloat(pages) * collectionView.bounds.width, height: collectionView.bounds.height)
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }
}
