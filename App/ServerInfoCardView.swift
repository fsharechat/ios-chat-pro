// App/ServerInfoCardView.swift
import UIKit
import IMClient

/// 连接服务弹窗的状态 1：一张只读的信息卡片。
///
/// 纯展示——不知道 `AppEnvironment`、不发起探测、不持有任何业务对象，
/// 全部数据由 `ServerInfoViewController` 喂进来。
final class ServerInfoCardView: UIView {
    var onSwitchTapped: (() -> Void)?
    var onCloseTapped: (() -> Void)?

    private let statusDot = UIView()
    private let addressValueLabel = UILabel()
    private let portValueLabel = UILabel()
    private let statusValueLabel = UILabel()
    private let latencyValueLabel = UILabel()
    private let latencySpinner = UIActivityIndicatorView(style: .medium)

    init() {
        super.init(frame: .zero)

        let titleLabel = UILabel()
        titleLabel.text = "当前连接服务"
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary

        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), statusDot])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8

        // 「服务名称」是固定文案：节点身份由「连接地址」行体现，不在此重复。
        let nameRow = Self.makeRow(label: "服务名称", valueLabel: Self.makeValueLabel(text: "飞享IM 消息服务"))
        let addressRow = Self.makeRow(label: "连接地址", valueLabel: addressValueLabel)
        let portRow = Self.makeRow(label: "端口", valueLabel: portValueLabel)
        let statusRow = Self.makeRow(label: "连接状态", valueLabel: statusValueLabel)

        [addressValueLabel, portValueLabel, statusValueLabel, latencyValueLabel].forEach(Self.styleValueLabel)

        latencySpinner.hidesWhenStopped = true
        let latencyValueStack = UIStackView(arrangedSubviews: [latencySpinner, latencyValueLabel])
        latencyValueStack.axis = .horizontal
        latencyValueStack.spacing = 6
        latencyValueStack.alignment = .center
        let latencyRow = Self.makeRow(label: "延迟", valueView: latencyValueStack)

        let infoStack = UIStackView(arrangedSubviews: [
            nameRow, Self.makeHairline(),
            addressRow, Self.makeHairline(),
            portRow, Self.makeHairline(),
            statusRow, Self.makeHairline(),
            latencyRow,
        ])
        infoStack.axis = .vertical
        infoStack.spacing = 0

        let switchButton = Self.makeSecondaryButton(title: "切换连接地址")
        switchButton.addTarget(self, action: #selector(switchTapped), for: .touchUpInside)
        let closeButton = Self.makePrimaryButton(title: "关闭")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        let buttonRow = UIStackView(arrangedSubviews: [switchButton, closeButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually

        let root = UIStackView(arrangedSubviews: [titleRow, infoStack, buttonRow])
        root.axis = .vertical
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(status: IMConnectionStatus, address: String, port: UInt16) {
        addressValueLabel.text = address
        portValueLabel.text = "\(port)"
        switch status {
        case .connected:
            statusValueLabel.text = "已连接"
            statusValueLabel.textColor = Theme.statusOnline
            statusDot.backgroundColor = Theme.statusOnline
        case .connecting:
            statusValueLabel.text = "正在连接…"
            statusValueLabel.textColor = Theme.statusConnecting
            statusDot.backgroundColor = Theme.statusConnecting
        case .disconnected:
            statusValueLabel.text = "未连接"
            statusValueLabel.textColor = Theme.statusOffline
            statusDot.backgroundColor = Theme.statusOffline
        }
    }

    /// `nil` 表示探测进行中（显示转圈）。
    func updateLatency(_ result: HostLatencyProbe.ProbeResult?) {
        guard let result else {
            latencyValueLabel.text = nil
            latencySpinner.startAnimating()
            return
        }
        latencySpinner.stopAnimating()
        latencyValueLabel.text = ServerLatencyFormatter.text(for: result)
    }

    /// 未连接 / 无可探测目标时的占位显示。与「探测中」「有结果」是三种
    /// 互斥状态，所以单独开一个入口，而不是往 `ProbeResult` 里塞哨兵值。
    func showLatencyPlaceholder() {
        latencySpinner.stopAnimating()
        latencyValueLabel.text = ServerLatencyFormatter.placeholder
    }

    // MARK: - 构件

    private static func makeValueLabel(text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        styleValueLabel(label)
        return label
    }

    private static func styleValueLabel(_ label: UILabel) {
        label.font = .systemFont(ofSize: 15)
        label.textColor = Theme.textPrimary
        label.textAlignment = .right
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
    }

    private static func makeRow(label: String, valueLabel: UILabel) -> UIView {
        makeRow(label: label, valueView: valueLabel)
    }

    private static func makeRow(label: String, valueView: UIView) -> UIView {
        let nameLabel = UILabel()
        nameLabel.text = label
        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.textColor = Theme.textSecondary
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [nameLabel, valueView])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.distribution = .equalSpacing
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        return row
    }

    private static func makeHairline() -> UIView {
        let line = UIView()
        line.backgroundColor = Theme.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return line
    }

    private static func makePrimaryButton(title: String) -> UIButton {
        let button = makeButtonShell(title: title)
        button.backgroundColor = Theme.accent
        button.setTitleColor(Theme.textOnAccent, for: .normal)
        return button
    }

    private static func makeSecondaryButton(title: String) -> UIButton {
        let button = makeButtonShell(title: title)
        button.backgroundColor = Theme.backgroundSecondary
        button.setTitleColor(Theme.textPrimary, for: .normal)
        return button
    }

    private static func makeButtonShell(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.layer.cornerRadius = Theme.cardCornerRadius
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    @objc private func switchTapped() { onSwitchTapped?() }
    @objc private func closeTapped() { onCloseTapped?() }
}

/// 探测结果 → 用户可读文案。状态 1 和状态 2 共用，保证两处口径一致。
enum ServerLatencyFormatter {
    static func text(for result: HostLatencyProbe.ProbeResult) -> String {
        switch result {
        case .latency(let milliseconds): return "\(milliseconds)ms"
        case .timedOut: return "超时"
        case .unresolved: return "无法解析"
        case .unreachable: return "不可达"
        }
    }

    /// 未连接 / 无值时的占位。
    static let placeholder = "——"
}
