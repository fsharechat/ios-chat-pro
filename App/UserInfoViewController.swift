// App/UserInfoViewController.swift
import UIKit
import Combine
import IMStorage
import IMKit

/// Dual-state profile page, aligned with Android's `UserInfoActivity`:
/// friends get "发消息/视频聊天", strangers (e.g. reached via QR scan) get
/// "添加到通讯录" instead. State follows `StoredUser.isFriend` reactively,
/// so a remote `fetchUserInfo` refresh or an accepted friend request
/// re-renders the page in place.
final class UserInfoViewController: UIViewController {

    var onSendMessage: (() -> Void)?
    var onVideoCall: (() -> Void)?

    /// Set by `SceneDelegate` for stranger-reachable contexts — performs the
    /// actual friend-request send. The add button only shows when non-nil.
    var sendFriendRequest: ((_ reason: String, _ completion: @escaping (Result<Void, Error>) -> Void) -> Void)?

    /// Prefilled verification message ("我是 xxx"), aligned with Android.
    var friendRequestDefaultReason = ""

    private let userId: String
    private let storage: IMStorage
    private let isSelf: Bool
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()
    private let mobileLabel = UILabel()
    private let sendMessageButton = UIButton(type: .system)
    private let videoCallButton = UIButton(type: .system)
    private let addFriendButton = UIButton(type: .system)

    init(userId: String, storage: IMStorage, isSelf: Bool = false) {
        self.userId = userId
        self.storage = storage
        self.isSelf = isSelf
        super.init(nibName: nil, bundle: nil)
        title = "用户信息"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        observeUser()
    }

    private func layoutViews() {
        avatarImageView.layer.cornerRadius = 40
        avatarImageView.clipsToBounds = true
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        mobileLabel.font = .systemFont(ofSize: 14)
        mobileLabel.textColor = .secondaryLabel
        mobileLabel.translatesAutoresizingMaskIntoConstraints = false

        sendMessageButton.setTitle("发消息", for: .normal)
        sendMessageButton.setTitleColor(.white, for: .normal)
        sendMessageButton.backgroundColor = Theme.accent
        sendMessageButton.layer.cornerRadius = 6
        sendMessageButton.titleLabel?.font = .systemFont(ofSize: 16)
        sendMessageButton.translatesAutoresizingMaskIntoConstraints = false
        sendMessageButton.addTarget(self, action: #selector(sendMessageTapped), for: .touchUpInside)

        videoCallButton.setTitle("视频聊天", for: .normal)
        videoCallButton.setTitleColor(Theme.accent, for: .normal)
        videoCallButton.layer.cornerRadius = 6
        videoCallButton.layer.borderWidth = 1
        videoCallButton.layer.borderColor = Theme.accent.cgColor
        videoCallButton.titleLabel?.font = .systemFont(ofSize: 16)
        videoCallButton.translatesAutoresizingMaskIntoConstraints = false
        videoCallButton.addTarget(self, action: #selector(videoCallTapped), for: .touchUpInside)

        addFriendButton.setTitle("添加到通讯录", for: .normal)
        addFriendButton.setTitleColor(.white, for: .normal)
        addFriendButton.backgroundColor = Theme.accent
        addFriendButton.layer.cornerRadius = 6
        addFriendButton.titleLabel?.font = .systemFont(ofSize: 16)
        addFriendButton.translatesAutoresizingMaskIntoConstraints = false
        addFriendButton.addTarget(self, action: #selector(addFriendTapped), for: .touchUpInside)

        let infoStack = UIStackView(arrangedSubviews: [nameLabel, mobileLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 4
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = UIStackView(arrangedSubviews: [avatarImageView, infoStack])
        headerStack.axis = .horizontal
        headerStack.spacing = 16
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.addSubview(headerStack)
        scrollView.addSubview(separator)
        scrollView.addSubview(sendMessageButton)
        scrollView.addSubview(videoCallButton)
        scrollView.addSubview(addFriendButton)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            avatarImageView.widthAnchor.constraint(equalToConstant: 80),
            avatarImageView.heightAnchor.constraint(equalToConstant: 80),

            headerStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 24),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            sendMessageButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 24),
            sendMessageButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sendMessageButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            sendMessageButton.heightAnchor.constraint(equalToConstant: 48),

            videoCallButton.topAnchor.constraint(equalTo: sendMessageButton.bottomAnchor, constant: 12),
            videoCallButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            videoCallButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            videoCallButton.heightAnchor.constraint(equalToConstant: 48),

            addFriendButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 24),
            addFriendButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            addFriendButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            addFriendButton.heightAnchor.constraint(equalToConstant: 48),

            // videoCallButton 恒为最低元素（隐藏也参与布局），用它定出 contentSize 高度
            scrollView.bottomAnchor.constraint(equalTo: videoCallButton.bottomAnchor, constant: 24),
        ])
    }

    private func observeUser() {
        apply(user: try? storage.users.user(uid: userId))
        storage.users.usersPublisher()
            .replaceError(with: [])
            .sink { [weak self] users in
                guard let self else { return }
                self.apply(user: users.first { $0.uid == self.userId })
            }
            .store(in: &cancellables)
    }

    private func apply(user: StoredUser?) {
        let displayName = user?.displayName ?? user?.name ?? userId
        let mobile = user?.mobile
        avatarImageView.setAvatar(urlString: user?.portrait, displayName: displayName)
        nameLabel.text = displayName
        mobileLabel.text = mobile.map { "电话/邮箱: \($0)" }
        mobileLabel.isHidden = mobile == nil

        let isFriend = user?.isFriend ?? false
        sendMessageButton.isHidden = !(isFriend && !isSelf)
        videoCallButton.isHidden = !(isFriend && !isSelf)
        addFriendButton.isHidden = isSelf || isFriend || sendFriendRequest == nil
    }

    @objc private func sendMessageTapped() { onSendMessage?() }
    @objc private func videoCallTapped() { onVideoCall?() }

    @objc private func addFriendTapped() {
        let alert = UIAlertController(title: "添加朋友", message: "向 \(nameLabel.text ?? userId) 发送好友请求", preferredStyle: .alert)
        alert.addTextField { [weak self] textField in
            textField.placeholder = "验证消息（可选）"
            textField.text = self?.friendRequestDefaultReason
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "发送", style: .default) { [weak self, weak alert] _ in
            let reason = alert?.textFields?.first?.text ?? ""
            self?.performSendFriendRequest(reason: reason)
        })
        present(alert, animated: true)
    }

    private func performSendFriendRequest(reason: String) {
        addFriendButton.isEnabled = false
        sendFriendRequest?(reason) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.addFriendButton.isEnabled = true
                switch result {
                case .success:
                    self.presentResultAlert(title: "已发送", message: "好友请求已发送")
                case .failure:
                    self.presentResultAlert(title: "发送失败", message: "请稍后重试")
                }
            }
        }
    }

    private func presentResultAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
