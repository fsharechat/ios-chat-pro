// App/LoginViewController.swift
import UIKit
import Combine
import AppCore

final class LoginViewController: UIViewController {
    private let viewModel: LoginViewModel
    private var cancellables = Set<AnyCancellable>()

    private let titleLabel = UILabel()
    private let phoneField = UITextField()
    private let codeField = UITextField()
    private let requestCodeButton = UIButton(type: .system)
    private let loginButton = UIButton(type: .system)
    private let errorLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    init(viewModel: LoginViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        bindViewModel()
    }

    private func layoutViews() {
        titleLabel.text = "登录"
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary

        phoneField.placeholder = "手机号"
        phoneField.keyboardType = .phonePad
        phoneField.borderStyle = .roundedRect
        phoneField.addTarget(self, action: #selector(phoneFieldChanged), for: .editingChanged)

        codeField.placeholder = "验证码"
        codeField.keyboardType = .numberPad
        codeField.borderStyle = .roundedRect
        codeField.addTarget(self, action: #selector(codeFieldChanged), for: .editingChanged)

        requestCodeButton.setTitle("获取验证码", for: .normal)
        requestCodeButton.addTarget(self, action: #selector(requestCodeTapped), for: .touchUpInside)

        let codeRow = UIStackView(arrangedSubviews: [codeField, requestCodeButton])
        codeRow.axis = .horizontal
        codeRow.spacing = Theme.standardSpacing

        loginButton.setTitle("登录", for: .normal)
        loginButton.setTitleColor(Theme.textOnAccent, for: .normal)
        loginButton.backgroundColor = Theme.accent
        loginButton.layer.cornerRadius = Theme.cardCornerRadius
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)

        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, phoneField, codeRow, loginButton, activityIndicator, errorLabel])
        stack.axis = .vertical
        stack.spacing = Theme.standardSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            loginButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func bindViewModel() {
        viewModel.$isRequestCodeEnabled
            .sink { [weak self] enabled in self?.requestCodeButton.isEnabled = enabled }
            .store(in: &cancellables)

        viewModel.$requestCodeCountdown
            .sink { [weak self] countdown in
                self?.requestCodeButton.setTitle(countdown > 0 ? "重新发送(\(countdown))" : "获取验证码", for: .normal)
            }
            .store(in: &cancellables)

        viewModel.$isLoginEnabled
            .combineLatest(viewModel.$isLoading)
            .sink { [weak self] loginEnabled, isLoading in self?.loginButton.isEnabled = loginEnabled && !isLoading }
            .store(in: &cancellables)

        viewModel.$isLoading
            .sink { [weak self] isLoading in
                isLoading ? self?.activityIndicator.startAnimating() : self?.activityIndicator.stopAnimating()
            }
            .store(in: &cancellables)

        viewModel.$errorMessage
            .sink { [weak self] message in
                self?.errorLabel.text = message
                self?.errorLabel.isHidden = (message == nil)
            }
            .store(in: &cancellables)
    }

    @objc private func phoneFieldChanged() {
        viewModel.phoneNumber = phoneField.text ?? ""
    }

    @objc private func codeFieldChanged() {
        viewModel.code = codeField.text ?? ""
    }

    // These unstructured `Task { ... }` calls are not cancelled if this view
    // controller is dismissed mid-request (no cancellation hookup in
    // `viewWillDisappear`/`deinit`) — harmless since `LoginViewModel` simply
    // outlives the dismissal briefly, but untracked. Accepted for Phase 1,
    // the same accepted gap documented in `AppEnvironment` and
    // `ReceiveMessageHandler`.
    @objc private func requestCodeTapped() {
        Task { await viewModel.requestCode() }
    }

    @objc private func loginTapped() {
        Task { await viewModel.login() }
    }
}
