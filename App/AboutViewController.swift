// App/AboutViewController.swift
import UIKit
import AppCore

final class AboutViewController: UIViewController {
    private let config: AppConfig
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    // 占位 URL,待替换为真实的功能介绍/用户协议/隐私政策页面地址 —— 同
    // `GroupInfoViewController.placeholderGroupAvatarURL` 一样用
    // example.com(RFC 2606 预留域名,不会真正解析)。
    private static let featureIntroURL = URL(string: "https://example.com/feature-intro")!
    private static let userAgreementURL = URL(string: "https://example.com/user-agreement")!
    private static let privacyPolicyURL = URL(string: "https://example.com/privacy-policy")!

    init(config: AppConfig) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
        title = "关于"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
    }

    private func layoutViews() {
        stack.axis = .vertical
        stack.spacing = Theme.standardSpacing
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "飞享"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"

        addLabel("\(appName) \(version) (\(build))", bold: true)
        addLabel("IM 服务器: \(config.imHosts):\(config.imPort)")
        for iceServer in config.iceServers {
            addLabel("ICE/STUN: \(iceServer.urlString)")
        }
        addLinkButton(title: "功能介绍", url: Self.featureIntroURL)
        addLinkButton(title: "用户协议", url: Self.userAgreementURL)
        addLinkButton(title: "隐私政策", url: Self.privacyPolicyURL)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -48),
        ])
    }

    private func addLabel(_ text: String, bold: Bool = false) {
        let label = UILabel()
        label.text = text
        label.font = bold ? .systemFont(ofSize: 18, weight: .semibold) : .systemFont(ofSize: 14)
        label.textColor = Theme.textPrimary
        label.numberOfLines = 0
        stack.addArrangedSubview(label)
    }

    private func addLinkButton(title: String, url: URL) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addAction(UIAction { [weak self] _ in self?.open(url) }, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }

    private func open(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
