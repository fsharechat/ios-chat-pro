// App/ServerNodePickerView.swift
import UIKit
import AppCore
import IMClient

/// 连接服务弹窗的状态 2：节点单选列表。纯展示 + 本地选中态，确认由
/// `onConfirm` 交回 `ServerInfoViewController`。
final class ServerNodePickerView: UIView {
    var onBackTapped: (() -> Void)?
    /// 传 nil 表示「自动（集群轮询）」。
    var onConfirm: ((String?) -> Void)?

    /// 当前选中的 host，nil = 自动。
    private var selectedHost: String?
    /// host → 该行的 view，供延迟结果回填。「自动」行不在其中。
    private var rowsByHost: [String: NodeRow] = [:]
    private let autoRow: NodeRow

    init(nodes: [AppConfig.ServerNode], selectedHost: String?) {
        self.selectedHost = selectedHost
        autoRow = NodeRow(title: "自动（集群轮询）", subtitle: "按集群顺序轮询", showsLatency: false)
        super.init(frame: .zero)

        let titleLabel = UILabel()
        titleLabel.text = "选择连接服务"
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary

        let metricHintLabel = UILabel()
        metricHintLabel.text = "建连耗时"
        metricHintLabel.font = .systemFont(ofSize: 12)
        metricHintLabel.textColor = Theme.textSecondary

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), metricHintLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8

        var rowViews: [UIView] = [autoRow]
        autoRow.onTapped = { [weak self] in self?.select(host: nil) }
        for node in nodes {
            let row = NodeRow(title: node.name, subtitle: node.host, showsLatency: true)
            row.onTapped = { [weak self] in self?.select(host: node.host) }
            rowsByHost[node.host] = row
            rowViews.append(row)
        }

        let listStack = UIStackView(arrangedSubviews: rowViews)
        listStack.axis = .vertical
        listStack.spacing = 0

        let backButton = Self.makeButton(title: "返回", primary: false)
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        let confirmButton = Self.makeButton(title: "确定", primary: true)
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        let buttonRow = UIStackView(arrangedSubviews: [backButton, confirmButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually

        let root = UIStackView(arrangedSubviews: [titleRow, listStack, buttonRow])
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

        applySelection()
        rowsByHost.values.forEach { $0.showLatencySpinner() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateLatency(_ result: HostLatencyProbe.ProbeResult, forHost host: String) {
        rowsByHost[host]?.showLatency(ServerLatencyFormatter.text(for: result))
    }

    /// 复用同一个 picker 再次进入状态 2 时调用：把选中态拉回真实的 pin，并把
    /// 所有节点行打回「探测中」。
    ///
    /// 两件事都是为了不让上一轮的残留误导用户——上次点「返回」而没「确定」的
    /// 临时选择不能留到下一次；上一轮的耗时数字是用户挑节点的依据，过期值比
    /// 转圈更坏。
    func resetForReuse(selectedHost: String?) {
        self.selectedHost = selectedHost
        applySelection()
        rowsByHost.values.forEach { $0.showLatencySpinner() }
    }

    private func select(host: String?) {
        selectedHost = host
        applySelection()
    }

    private func applySelection() {
        autoRow.isSelected = selectedHost == nil
        for (host, row) in rowsByHost {
            row.isSelected = host == selectedHost
        }
    }

    @objc private func backTapped() { onBackTapped?() }
    @objc private func confirmTapped() { onConfirm?(selectedHost) }

    private static func makeButton(title: String, primary: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = primary ? Theme.accent : Theme.backgroundSecondary
        button.setTitleColor(primary ? Theme.textOnAccent : Theme.textPrimary, for: .normal)
        button.layer.cornerRadius = Theme.cardCornerRadius
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }
}

/// 单选列表的一行：radio + 标题 + 灰色小字 + 行尾建连耗时（或转圈）。
private final class NodeRow: UIControl {
    var onTapped: (() -> Void)?

    override var isSelected: Bool {
        didSet { radioImageView.image = Self.radioImage(selected: isSelected) }
    }

    private let radioImageView = UIImageView()
    private let latencyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(title: String, subtitle: String, showsLatency: Bool) {
        super.init(frame: .zero)

        radioImageView.tintColor = Theme.accent
        radioImageView.contentMode = .scaleAspectFit
        radioImageView.translatesAutoresizingMaskIntoConstraints = false
        radioImageView.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15)
        titleLabel.textColor = Theme.textPrimary

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = Theme.textSecondary
        subtitleLabel.adjustsFontSizeToFitWidth = true
        subtitleLabel.minimumScaleFactor = 0.7

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        latencyLabel.font = .systemFont(ofSize: 14)
        latencyLabel.textColor = Theme.textSecondary
        latencyLabel.textAlignment = .right
        latencyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        spinner.hidesWhenStopped = true

        let trailingStack = UIStackView(arrangedSubviews: [spinner, latencyLabel])
        trailingStack.axis = .horizontal
        trailingStack.spacing = 4
        trailingStack.alignment = .center
        trailingStack.isHidden = !showsLatency

        let row = UIStackView(arrangedSubviews: [radioImageView, textStack, UIView(), trailingStack])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        isSelected = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showLatencySpinner() {
        latencyLabel.text = nil
        spinner.startAnimating()
    }

    func showLatency(_ text: String) {
        spinner.stopAnimating()
        latencyLabel.text = text
    }

    @objc private func handleTap() { onTapped?() }

    private static func radioImage(selected: Bool) -> UIImage? {
        UIImage(systemName: selected ? "largecircle.fill.circle" : "circle")
    }
}
