// App/UserInfoViewController.swift
import UIKit
import IMStorage

final class UserInfoViewController: UIViewController {

    var onSendMessage: (() -> Void)?
    var onVideoCall: (() -> Void)?

    private let userId: String
    private let storage: IMStorage

    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()
    private let mobileLabel = UILabel()
    private let sendMessageButton = UIButton(type: .system)
    private let videoCallButton = UIButton(type: .system)

    init(userId: String, storage: IMStorage) {
        self.userId = userId
        self.storage = storage
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
        populateUser()
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
        sendMessageButton.backgroundColor = Theme.tint
        sendMessageButton.layer.cornerRadius = 6
        sendMessageButton.titleLabel?.font = .systemFont(ofSize: 16)
        sendMessageButton.translatesAutoresizingMaskIntoConstraints = false
        sendMessageButton.addTarget(self, action: #selector(sendMessageTapped), for: .touchUpInside)

        videoCallButton.setTitle("视频聊天", for: .normal)
        videoCallButton.setTitleColor(Theme.tint, for: .normal)
        videoCallButton.layer.cornerRadius = 6
        videoCallButton.layer.borderWidth = 1
        videoCallButton.layer.borderColor = Theme.tint.cgColor
        videoCallButton.titleLabel?.font = .systemFont(ofSize: 16)
        videoCallButton.translatesAutoresizingMaskIntoConstraints = false
        videoCallButton.addTarget(self, action: #selector(videoCallTapped), for: .touchUpInside)

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

        view.addSubview(headerStack)
        view.addSubview(separator)
        view.addSubview(sendMessageButton)
        view.addSubview(videoCallButton)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 80),
            avatarImageView.heightAnchor.constraint(equalToConstant: 80),

            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
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
        ])
    }

    private func populateUser() {
        let user = try? storage.users.user(uid: userId)
        let displayName = user?.displayName ?? user?.name ?? userId
        let mobile = user?.mobile
        avatarImageView.setAvatar(urlString: user?.portrait, displayName: displayName)
        nameLabel.text = displayName
        mobileLabel.text = mobile.map { "电话/邮箱: \($0)" }
        mobileLabel.isHidden = mobile == nil
    }

    @objc private func sendMessageTapped() { onSendMessage?() }
    @objc private func videoCallTapped() { onVideoCall?() }
}
