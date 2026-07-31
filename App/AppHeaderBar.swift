// App/AppHeaderBar.swift
import UIKit

/// 三个 tab 共用的固定顶栏：左侧标题「飞享IM」（连接异常时附带状态），
/// 右侧加号菜单入口。挂在 `MainTabBarController.view` 上、与 tabBar 同级，
/// 因此左右滑动切 tab 时不参与转场、始终不动——对齐 Android 版顶部 toolbar。
final class AppHeaderBar: UIView {
    /// 状态栏之下的内容高度，与系统导航栏保持一致。
    static let contentHeight: CGFloat = 44

    var onPlusTapped: (() -> Void)?

    /// 点击标题的动作（弹出连接服务弹窗），由 `SceneDelegate` 注入。
    var onTitleTapped: (() -> Void)?

    var title: String? {
        get { titleLabel.text }
        set { titleLabel.text = newValue }
    }

    /// 加号按钮在 `view` 坐标系中的位置，供弹出菜单锚定。
    func plusButtonFrame(in view: UIView) -> CGRect {
        plusButton.convert(plusButton.bounds, to: view)
    }

    private let titleLabel = UILabel()
    private let plusButton = UIButton(type: .system)

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = Theme.backgroundPrimary

        titleLabel.text = title
        titleLabel.textColor = Theme.textPrimary
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.7
        // 手势只挂在 label 上、不挂整个顶栏：否则标题右侧那片空白也会
        // 变成可点区域，与 Android 版把监听挂在 Toolbar 标题 TextView 上
        // 而不是 Toolbar 本身的理由一致。
        titleLabel.isUserInteractionEnabled = true
        titleLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(titleTapped)))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        plusButton.setImage(
            UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)),
            for: .normal
        )
        plusButton.tintColor = Theme.textPrimary
        plusButton.addTarget(self, action: #selector(plusTapped), for: .touchUpInside)
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusButton)

        let separator = UIView()
        separator.backgroundColor = Theme.separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            // 顶栏整体从屏幕顶端起算（含状态栏），内容垂直居中于底部 44pt 区域。
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Self.contentHeight / 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: plusButton.leadingAnchor, constant: -8),

            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            plusButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 44),
            plusButton.heightAnchor.constraint(equalToConstant: 44),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func plusTapped() {
        onPlusTapped?()
    }

    @objc private func titleTapped() {
        onTitleTapped?()
    }
}
