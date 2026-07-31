// App/ServerInfoViewController.swift
import UIKit
import AppCore
import IMClient

/// 点顶栏标题弹出的连接服务弹窗。居中卡片 + 半透明遮罩，两个状态在同一张
/// 卡片内切换、不销毁重建（对齐 android-chat-pro 的 `ServerInfoDialog`）。
///
/// 依赖全部走闭包注入，照 `SceneDelegate` 现有的 wire 惯例——不把
/// `AppEnvironment` 递进 view 层，也不引单例。
final class ServerInfoViewController: UIViewController {
    private let nodes: [AppConfig.ServerNode]
    private let port: UInt16
    private let pinnedHost: () -> String?
    private let connectedHost: () -> String?
    private let connectionStatus: () -> IMConnectionStatus
    private let onSwitch: (String?) -> Void

    private let cardView = UIView()
    private let infoCard = ServerInfoCardView()
    /// 当前在途的探测。切状态或弹窗消失时必须 cancel，否则回调会打到已
    /// 销毁的 view 上。
    private var probeHandle: HostLatencyProbe.Handle?
    /// 状态 2 的 view。首次进入状态 2 时创建，之后复用——弹窗要求两个状态
    /// 互切而不销毁重建。
    private var pickerView: ServerNodePickerView?

    init(
        nodes: [AppConfig.ServerNode],
        port: UInt16,
        pinnedHost: @escaping () -> String?,
        connectedHost: @escaping () -> String?,
        connectionStatus: @escaping () -> IMConnectionStatus,
        onSwitch: @escaping (String?) -> Void
    ) {
        self.nodes = nodes
        self.port = port
        self.pinnedHost = pinnedHost
        self.connectedHost = connectedHost
        self.connectionStatus = connectionStatus
        self.onSwitch = onSwitch
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        probeHandle?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        cardView.backgroundColor = Theme.popupCard
        cardView.layer.cornerRadius = 16
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            cardView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.86).withPriority(.defaultHigh),
        ])

        infoCard.onCloseTapped = { [weak self] in self?.dismiss(animated: true) }
        infoCard.onSwitchTapped = { [weak self] in self?.showPickerState() }

        showInfoState(animated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        probeHandle?.cancel()
        probeHandle = nil
    }

    /// 连接状态变化时由 `SceneDelegate` 转发进来，让状态 1 与顶栏标题同步。
    func refreshStatus(_ status: IMConnectionStatus) {
        guard infoCard.superview != nil else { return }
        infoCard.update(status: status, address: displayAddress(), port: port)
        // 弹窗开着时后台重连成功：状态行已变「已连接」，但延迟行还停在
        // 打开弹窗那一刻的占位 `——`，两行互相矛盾。这里补一次探测。
        //
        // `probeHandle == nil` 是「本轮还没探测过」的判据：只有
        // `startInfoProbe()` 走占位分支（未连接）时才会留下 nil，探测一旦
        // 发出 handle 就非 nil 并一直留到下次切状态。因此连上后只补探一次，
        // `.connecting` 反复抖动也不会造成探测风暴。
        if status == .connected, probeHandle == nil {
            startInfoProbe()
        }
    }

    // MARK: - 状态 1

    private func showInfoState(animated: Bool) {
        swapCardContent(to: infoCard, animated: animated)
        infoCard.update(status: connectionStatus(), address: displayAddress(), port: port)
        startInfoProbe()
    }

    /// 「连接地址」的取值：优先真实在连的 host；取不到时（未登录 / 尚未
    /// 发起连接）pin 了就显示 pin 的 host，没 pin 就显示「自动（集群轮询）」。
    private func displayAddress() -> String {
        if let host = connectedHost() { return host }
        return pinnedHost() ?? "自动（集群轮询）"
    }

    private func startInfoProbe() {
        probeHandle?.cancel()
        probeHandle = nil
        // 未连接时不探测：那一行本就该显示占位，跑一次注定失败的探测只是
        // 让用户多等 2 秒看到「超时」。
        guard connectionStatus() != .disconnected, let host = connectedHost() ?? pinnedHost() else {
            infoCard.showLatencyPlaceholder()
            return
        }
        infoCard.updateLatency(nil)
        probeHandle = HostLatencyProbe.probeAll(hosts: [host], port: port) { [weak self] _, result in
            self?.infoCard.updateLatency(result)
        }
    }

    // MARK: - 状态 2

    private func showPickerState() {
        let picker = pickerView ?? makePickerView()
        pickerView = picker
        // 复用的 picker 可能带着上一轮没确认的选中态和过期耗时，先归位。
        picker.resetForReuse(selectedHost: pinnedHost())
        swapCardContent(to: picker, animated: true)
        startPickerProbe(picker: picker)
    }

    private func makePickerView() -> ServerNodePickerView {
        let picker = ServerNodePickerView(nodes: nodes, selectedHost: pinnedHost())
        picker.onBackTapped = { [weak self] in self?.showInfoState(animated: true) }
        picker.onConfirm = { [weak self] host in
            guard let self else { return }
            // 选中项与当前项相同：直接回状态 1，不触发一次没必要的重连。
            if host != self.pinnedHost() {
                self.onSwitch(host)
            }
            self.showInfoState(animated: true)
        }
        return picker
    }

    private func startPickerProbe(picker: ServerNodePickerView) {
        // `probeHandle` 是单槽：状态 1 的单 host 探测可能还在飞，不先 cancel
        // 的话它的回调会打到已经切走的界面上。
        probeHandle?.cancel()
        probeHandle = HostLatencyProbe.probeAll(hosts: nodes.map(\.host), port: port) { [weak picker] host, result in
            picker?.updateLatency(result, forHost: host)
        }
    }

    // MARK: - 卡片内容切换

    private func swapCardContent(to content: UIView, animated: Bool) {
        let install = { [weak self] in
            guard let self else { return }
            self.cardView.subviews.forEach { $0.removeFromSuperview() }
            content.translatesAutoresizingMaskIntoConstraints = false
            self.cardView.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: self.cardView.topAnchor),
                content.leadingAnchor.constraint(equalTo: self.cardView.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: self.cardView.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: self.cardView.bottomAnchor),
            ])
        }
        guard animated else { return install() }
        UIView.transition(with: cardView, duration: 0.2, options: .transitionCrossDissolve) {
            install()
            self.cardView.layoutIfNeeded()
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
