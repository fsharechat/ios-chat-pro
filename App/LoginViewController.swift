// App/LoginViewController.swift
import UIKit
import Combine
import AppCore

final class LoginViewController: UIViewController {
    private let viewModel: LoginViewModel
    private var cancellables = Set<AnyCancellable>()

    private let logoImageView = UIImageView()
    private let titleLabel = UILabel()
    private let phoneField = UITextField()
    private let codeField = UITextField()
    private let requestCodeButton = UIButton(type: .system)
    private let loginButton = UIButton(type: .system)
    private let errorLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let formStack = UIStackView()
    private var formStackCenterYConstraint: NSLayoutConstraint!

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

        // cancelsTouchesInView = false so this doesn't swallow taps on
        // `loginButton`/`requestCodeButton` — it just resigns the keyboard
        // alongside whatever else the tap does.
        let dismissKeyboardTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissKeyboardTap.cancelsTouchesInView = false
        view.addGestureRecognizer(dismissKeyboardTap)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    private func layoutViews() {
        logoImageView.image = UIImage(named: "LoginLogo")
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.layer.cornerRadius = Theme.cardCornerRadius
        logoImageView.layer.masksToBounds = true
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logoImageView)

        titleLabel.text = "登录"
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.textAlignment = .center

        phoneField.placeholder = "手机号/邮箱"
        phoneField.keyboardType = .default
        phoneField.autocapitalizationType = .none
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

        formStack.addArrangedSubview(titleLabel)
        formStack.addArrangedSubview(phoneField)
        formStack.addArrangedSubview(codeRow)
        formStack.addArrangedSubview(loginButton)
        formStack.addArrangedSubview(activityIndicator)
        formStack.addArrangedSubview(errorLabel)
        formStack.axis = .vertical
        formStack.spacing = Theme.standardSpacing
        formStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(formStack)

        formStackCenterYConstraint = formStack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)

        NSLayoutConstraint.activate([
            // Anchored independently near the top (not part of `formStack`)
            // so it uses the blank space above the vertically-centered form
            // instead of sitting glued to the title — see login page review
            // 2026-07-14.
            logoImageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
            logoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 80),
            logoImageView.heightAnchor.constraint(equalToConstant: 80),

            formStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            formStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            formStackCenterYConstraint,
            loginButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    // Keeps the verification-code field and login button visible above the
    // keyboard: shifts `formStack` up by however much the keyboard would
    // otherwise cover it, rather than a fixed offset, so it adapts to
    // keyboard height/device size.
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
            let curveRaw = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }

        view.layoutIfNeeded()
        let keyboardFrameInView = view.convert(endFrame, from: nil)
        let overlap = formStack.frame.maxY - keyboardFrameInView.minY + 16
        guard overlap > 0 else { return }

        formStackCenterYConstraint.constant = -overlap
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curveRaw << 16)) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
            let curveRaw = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }

        formStackCenterYConstraint.constant = 0
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curveRaw << 16)) {
            self.view.layoutIfNeeded()
        }
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

    @objc private func dismissKeyboard() {
        view.endEditing(true)
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
