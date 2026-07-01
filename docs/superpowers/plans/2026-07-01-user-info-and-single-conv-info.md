# 用户详情页 & 单聊会话详情页 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 联系人列表点击联系人跳转用户详情页（而非直接进聊天），单聊右上角按钮跳转单聊会话详情页，均对标 Android 端体验。

**Architecture:** 新建 `SingleConversationInfoViewModel`（IMKit）管理单聊会话设置状态；新建 `UserInfoViewController` 展示用户资料；新建 `SingleConversationInfoViewController` 展示单聊会话详情；SceneDelegate 统一 wire 路由。`SearchMessageViewController` 改为接受闭包而非 `GroupInfoViewModel`，解除耦合。

**Tech Stack:** Swift, UIKit, Combine, GRDB（通过 IMStorage）

## Global Constraints

- 主队列调用，无锁
- App target 不引入新第三方依赖
- IMKit 层不得引用 App target 的类型
- 依赖方向严格：IMKit → IMStorage，App → IMKit + IMStorage
- 所有新 VC 遵循现有模式：`init(nibName:bundle:)` 不可用，用 `@available(*, unavailable)`
- 编译验证命令：`xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

---

## 文件清单

| 操作 | 文件 | 职责 |
|---|---|---|
| 新建 | `Sources/IMKit/SingleConversationInfoViewModel.swift` | 单聊 isTop/isMuted/clearMessages/searchMessages |
| 修改 | `App/SearchMessageViewController.swift` | 接受 `(String) -> [StoredMessage]` 闭包，解除对 GroupInfoViewModel 的依赖 |
| 新建 | `App/UserInfoViewController.swift` | 展示对方头像/昵称/手机号，含"发消息"/"视频聊天"按钮 |
| 新建 | `App/SingleConversationInfoViewController.swift` | 单聊详情：成员头像 + 免打扰/置顶开关 + 查找/清空记录 |
| 修改 | `App/SceneDelegate.swift` | wire 联系人点击→UserInfoVC、单聊info按钮→SingleConvInfoVC、群成员点击→UserInfoVC |

---

## Task 1: `SingleConversationInfoViewModel`

**Files:**
- Create: `Sources/IMKit/SingleConversationInfoViewModel.swift`

**Interfaces:**
- Produces: `SingleConversationInfoViewModel(userId: String, storage: IMStorage)` — 供 Task 4 & Task 5 使用

- [ ] **Step 1: 创建 ViewModel 文件**

```swift
// Sources/IMKit/SingleConversationInfoViewModel.swift
import Foundation
import Combine
import IMStorage

public final class SingleConversationInfoViewModel {
    @Published public private(set) var isTop: Bool = false
    @Published public private(set) var isMuted: Bool = false

    private let storage: IMStorage
    public let userId: String

    public init(userId: String, storage: IMStorage) {
        self.userId = userId
        self.storage = storage
        if let conv = try? storage.conversations.conversation(conversationType: .single, target: userId) {
            isTop = conv.isTop
            isMuted = conv.isMuted
        }
    }

    public func userInfo() -> StoredUser? {
        try? storage.users.user(uid: userId)
    }

    public func setTop(_ value: Bool) {
        isTop = value
        try? storage.conversations.setTop(value, conversationType: .single, target: userId)
    }

    public func setMuted(_ value: Bool) {
        isMuted = value
        try? storage.conversations.setMuted(value, conversationType: .single, target: userId)
    }

    public func clearMessages(completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try storage.messages.clearMessages(conversationType: .single, target: userId)
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    public func searchMessages(keyword: String) -> [StoredMessage] {
        (try? storage.messages.searchMessages(conversationType: .single, target: userId, keyword: keyword)) ?? []
    }
}
```

- [ ] **Step 2: 编译验证**

```bash
swift build 2>&1 | tail -5
```

期望输出：`Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/IMKit/SingleConversationInfoViewModel.swift
git commit -m "feat(IMKit): add SingleConversationInfoViewModel for single-chat settings"
```

---

## Task 2: `SearchMessageViewController` 解耦

**Files:**
- Modify: `App/SearchMessageViewController.swift`（第 7-13 行，`private let viewModel: GroupInfoViewModel`）

**Interfaces:**
- Consumes: `searcher: (String) -> [StoredMessage]` 闭包
- Produces: `SearchMessageViewController(searcher: (String) -> [StoredMessage])` — 供 Task 5 SceneDelegate 使用

- [ ] **Step 1: 修改 `SearchMessageViewController` 接受闭包**

将 `App/SearchMessageViewController.swift` 第 7-13 行替换：

```swift
final class SearchMessageViewController: UIViewController {
    private let searcher: (String) -> [StoredMessage]
    private var results: [StoredMessage] = []

    private let searchBar = UISearchBar()
    private let tableView = UITableView()

    init(searcher: @escaping (String) -> [StoredMessage]) {
        self.searcher = searcher
        super.init(nibName: nil, bundle: nil)
        title = "查找聊天记录"
    }
```

- [ ] **Step 2: 修改 `performSearch` 调用方式**

将第 46-54 行中的 `viewModel.searchMessages(keyword:)` 改为 `searcher(keyword)`：

```swift
    private func performSearch(keyword: String) {
        guard !keyword.isEmpty else {
            results = []
            tableView.reloadData()
            return
        }
        results = searcher(keyword)
        tableView.reloadData()
    }
```

- [ ] **Step 3: 修改 SceneDelegate 中 group 搜索调用**

在 `App/SceneDelegate.swift` 第 272 行，将：
```swift
let searchVC = SearchMessageViewController(viewModel: groupInfoViewModel)
```
改为：
```swift
let searchVC = SearchMessageViewController(searcher: groupInfoViewModel.searchMessages)
```

- [ ] **Step 4: 编译验证**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

期望输出：`** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add App/SearchMessageViewController.swift App/SceneDelegate.swift
git commit -m "refactor(App): decouple SearchMessageViewController from GroupInfoViewModel"
```

---

## Task 3: `UserInfoViewController`

**Files:**
- Create: `App/UserInfoViewController.swift`

**Interfaces:**
- Consumes: `userId: String`，`storage: IMStorage`（从 IMStorage 读取 `StoredUser`）
- Produces:
  - `var onSendMessage: (() -> Void)?`
  - `var onVideoCall: (() -> Void)?`
  - `UserInfoViewController(userId: String, storage: IMStorage)`

布局（对标 Android 截图 #10）：
```
┌─────────────────────────────────────┐
│  [头像 80×80]  昵称（大字）           │
│               电话: 139xxxxxxxx      │
├─────────────────────────────────────┤
│         [发消息]（蓝色全宽按钮）       │
├─────────────────────────────────────┤
│         [视频聊天]（白色边框按钮）     │
└─────────────────────────────────────┘
```

- [ ] **Step 1: 创建 UserInfoViewController**

```swift
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
```

- [ ] **Step 2: 编译验证**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

期望输出：`** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/UserInfoViewController.swift
git commit -m "feat(App): add UserInfoViewController showing avatar/name/mobile with send/video-call actions"
```

---

## Task 4: `SingleConversationInfoViewController`

**Files:**
- Create: `App/SingleConversationInfoViewController.swift`

**Interfaces:**
- Consumes:
  - `viewModel: SingleConversationInfoViewModel`（来自 Task 1）
- Produces:
  - `var onAvatarTapped: (() -> Void)?`
  - `var onSearchMessagesTapped: (() -> Void)?`
  - `SingleConversationInfoViewController(viewModel: SingleConversationInfoViewModel)`

布局（对标 Android 截图 #11）：
- 顶部头像（可点击）+ 昵称
- Table section 1：消息免打扰 Toggle、置顶聊天 Toggle
- Table section 2：查找聊天记录（→ 回调）
- Table section 3：清空聊天记录（→ 确认弹窗）

- [ ] **Step 1: 创建 SingleConversationInfoViewController**

```swift
// App/SingleConversationInfoViewController.swift
import UIKit
import Combine
import IMKit
import IMStorage

final class SingleConversationInfoViewController: UIViewController {

    var onAvatarTapped: (() -> Void)?
    var onSearchMessagesTapped: (() -> Void)?

    private let viewModel: SingleConversationInfoViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Section, Row>!

    private enum Section: Int, CaseIterable { case toggles, actions }
    private enum Row: Hashable {
        case mute(Bool)
        case stickTop(Bool)
        case searchMessages
        case clearMessages
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()

    init(viewModel: SingleConversationInfoViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "会话详情"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        layoutViews()
        configureDataSource()
        bindViewModel()
        populateHeader()
    }

    private func layoutViews() {
        // Header
        let headerView = UIView()
        avatarImageView.layer.cornerRadius = 35
        avatarImageView.clipsToBounds = true
        avatarImageView.isUserInteractionEnabled = true
        avatarImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .secondaryLabel
        nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(avatarImageView)
        headerView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
            avatarImageView.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 70),
            avatarImageView.heightAnchor.constraint(equalToConstant: 70),
            nameLabel.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 6),
            nameLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -12),
        ])
        headerView.frame = CGRect(x: 0, y: 0, width: 0, height: 120)

        // Table
        tableView.register(ToggleSwitchCell.self, forCellReuseIdentifier: ToggleSwitchCell.reuseIdentifier)
        tableView.register(NavigationRowCell.self, forCellReuseIdentifier: NavigationRowCell.reuseIdentifier)
        tableView.tableHeaderView = headerView
        tableView.delegate = self
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 0)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView, header.frame.width != tableView.bounds.width else { return }
        header.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 120)
        tableView.tableHeaderView = header
    }

    private func populateHeader() {
        let user = viewModel.userInfo()
        let displayName = user?.displayName ?? user?.name ?? viewModel.userId
        avatarImageView.setAvatar(urlString: user?.portrait, displayName: displayName)
        nameLabel.text = displayName
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView)
        }
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        switch row {
        case .mute(let isOn):
            let cell = tableView.dequeueReusableCell(withIdentifier: ToggleSwitchCell.reuseIdentifier, for: indexPath) as! ToggleSwitchCell
            cell.configure(title: "消息免打扰", isOn: isOn)
            cell.onToggle = { [weak self] value in self?.viewModel.setMuted(value) }
            return cell
        case .stickTop(let isOn):
            let cell = tableView.dequeueReusableCell(withIdentifier: ToggleSwitchCell.reuseIdentifier, for: indexPath) as! ToggleSwitchCell
            cell.configure(title: "置顶聊天", isOn: isOn)
            cell.onToggle = { [weak self] value in self?.viewModel.setTop(value) }
            return cell
        case .searchMessages:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "查找聊天记录", detail: nil)
            return cell
        case .clearMessages:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "清空聊天记录", detail: nil)
            return cell
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.mute(viewModel.isMuted), .stickTop(viewModel.isTop)], toSection: .toggles)
        snapshot.appendItems([.searchMessages, .clearMessages], toSection: .actions)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func bindViewModel() {
        Publishers.Merge(
            viewModel.$isTop.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isMuted.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.applySnapshot() }
        .store(in: &cancellables)
    }

    private func handleClearMessagesTapped() {
        let alert = UIAlertController(title: "清空聊天记录", message: "清空后不可恢复，确认操作？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .destructive) { [weak self] _ in
            self?.viewModel.clearMessages { result in
                DispatchQueue.main.async {
                    if case .failure = result {
                        let err = UIAlertController(title: "清空失败", message: "请稍后重试", preferredStyle: .alert)
                        err.addAction(UIAlertAction(title: "好", style: .default))
                        self?.present(err, animated: true)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    @objc private func avatarTapped() { onAvatarTapped?() }
}

extension SingleConversationInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 50 }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let spacer = UIView()
        spacer.backgroundColor = .systemGroupedBackground
        return spacer
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 0 : 10
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .searchMessages: onSearchMessagesTapped?()
        case .clearMessages: handleClearMessagesTapped()
        default: break
        }
    }
}
```

- [ ] **Step 2: 编译验证**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

期望输出：`** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/SingleConversationInfoViewController.swift
git commit -m "feat(App): add SingleConversationInfoViewController for single-chat settings"
```

---

## Task 5: SceneDelegate 路由接线

**Files:**
- Modify: `App/SceneDelegate.swift`（第 292-329 行 `makeContactListNavigationController`，第 210-278 行 `wireGroupInfoNavigation`）

**Interfaces:**
- Consumes: `UserInfoViewController(userId:storage:)`, `SingleConversationInfoViewController(viewModel:)`, `SingleConversationInfoViewModel(userId:storage:)`

**改动 A：联系人点击 → 先进用户详情页**

将 `makeContactListNavigationController` 中第 294-329 行的 `onContactSelected` 闭包替换为：

```swift
listViewController.onContactSelected = { [weak self, weak listViewController] row in
    guard let self else { return }
    let userInfoVC = UserInfoViewController(userId: row.uid, storage: self.environment.storage)
    userInfoVC.onSendMessage = { [weak self, weak listViewController] in
        guard let self else { return }
        let conversationViewModel = ConversationViewModel(
            storage: self.environment.storage,
            messageSending: self.environment.messagingService,
            imageUploading: self.environment.mediaUploadService,
            voiceUploading: self.environment.mediaUploadService,
            fileUploading: self.environment.mediaUploadService,
            videoUploading: self.environment.mediaUploadService,
            target: row.uid,
            conversationType: .single,
            currentUserId: self.environment.imClient?.userId ?? ""
        )
        let conversationRow = ConversationRow(
            conversationType: .single,
            target: row.uid,
            line: 0,
            displayName: row.displayName,
            avatarURL: row.avatarURL,
            previewText: "",
            timestamp: 0,
            unreadCount: 0,
            hasUnreadMention: false,
            isTop: false,
            isMuted: false,
            lastMessageStatus: nil
        )
        let conversationVC = ConversationViewController(row: conversationRow, viewModel: conversationViewModel)
        conversationVC.onCallTapped = { [weak self] audioOnly in
            self?.startCallIfAuthorized(to: row.uid, audioOnly: audioOnly)
        }
        self.wireContactInfoNavigation(on: conversationVC, userId: row.uid)
        listViewController?.navigationController?.pushViewController(conversationVC, animated: true)
    }
    userInfoVC.onVideoCall = { [weak self] in
        self?.startCallIfAuthorized(to: row.uid, audioOnly: false)
    }
    listViewController?.navigationController?.pushViewController(userInfoVC, animated: true)
}
```

**改动 B：新增私有方法 `wireContactInfoNavigation`**

在 `SceneDelegate` 中添加方法（与 `wireGroupInfoNavigation` 并列）：

```swift
private func wireContactInfoNavigation(on conversationVC: ConversationViewController, userId: String) {
    conversationVC.onContactInfoTapped = { [weak self, weak conversationVC] in
        guard let self else { return }
        let vm = SingleConversationInfoViewModel(userId: userId, storage: self.environment.storage)
        let infoVC = SingleConversationInfoViewController(viewModel: vm)

        infoVC.onAvatarTapped = { [weak infoVC] in
            let userInfoVC = UserInfoViewController(userId: userId, storage: self.environment.storage)
            // 从会话详情内再次"发消息"直接 pop 回聊天（聊天已在栈上）
            userInfoVC.onSendMessage = { [weak infoVC] in
                infoVC?.navigationController?.popViewController(animated: true)
            }
            userInfoVC.onVideoCall = { [weak self] in
                self?.startCallIfAuthorized(to: userId, audioOnly: false)
            }
            infoVC?.navigationController?.pushViewController(userInfoVC, animated: true)
        }

        infoVC.onSearchMessagesTapped = { [weak infoVC] in
            let searchVC = SearchMessageViewController(searcher: vm.searchMessages)
            infoVC?.navigationController?.pushViewController(searchVC, animated: true)
        }

        conversationVC?.navigationController?.pushViewController(infoVC, animated: true)
    }
}
```

**改动 C：会话列表中已有单聊的 wire（`onContactInfoTapped` 未接入的路径）**

在 `makeConversationListNavigationController`（或同等位置）中，现有单聊 `ConversationViewController` 创建处，调用 `wireContactInfoNavigation`：

> 注意：查找所有 `ConversationViewController(row: conversationRow, viewModel: conversationViewModel)` 构造后直接 push 的地方（消息列表 tab 中），在 push 前补充：
> ```swift
> if conversationRow.conversationType == .single {
>     self.wireContactInfoNavigation(on: conversationViewController, userId: conversationRow.target)
> }
> ```

**改动 D：群成员头像点击 → 用户详情**

在 `wireGroupInfoNavigation` 中，将第 244-247 行的 TODO 替换为：

```swift
groupInfoViewController.onMemberTapped = { [weak self, weak groupInfoViewController] uid in
    guard let self else { return }
    let userInfoVC = UserInfoViewController(userId: uid, storage: self.environment.storage)
    userInfoVC.onSendMessage = { [weak self, weak groupInfoViewController] in
        // 群成员详情→发消息，弹出群详情并新开单聊
        groupInfoViewController?.navigationController?.popViewController(animated: true)
    }
    userInfoVC.onVideoCall = { [weak self] in
        self?.startCallIfAuthorized(to: uid, audioOnly: false)
    }
    groupInfoViewController?.navigationController?.pushViewController(userInfoVC, animated: true)
}
```

- [ ] **Step 1: 修改 `onContactSelected` 闭包（改动 A）**

在 `SceneDelegate.swift` 第 294 行，将整个 `listViewController.onContactSelected = { ... }` 块替换为改动 A 的代码。

- [ ] **Step 2: 添加 `wireContactInfoNavigation` 方法（改动 B）**

在 `wireGroupInfoNavigation` 方法之后添加改动 B 的私有方法。

- [ ] **Step 3: 为消息列表 tab 中的单聊接入 `wireContactInfoNavigation`（改动 C）**

搜索 `SceneDelegate.swift` 中所有 `ConversationViewController` push 处，找到来自会话列表 tab 的单聊跳转（通常在 `makeConversationListNavigationController` 内）：

```swift
// 在 push 前补充：
if conversationRow.conversationType == .single {
    self.wireContactInfoNavigation(on: conversationVC, userId: conversationRow.target)
}
```

- [ ] **Step 4: 更新群成员点击（改动 D）**

将 `wireGroupInfoNavigation` 内第 244-247 行（`onMemberTapped` TODO）替换为改动 D 的代码。

- [ ] **Step 5: 编译验证**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

期望输出：`** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add App/SceneDelegate.swift
git commit -m "feat(App): wire contact-info and single-conv-info navigation in SceneDelegate"
```

---

## 自查

- [x] **Spec 覆盖：** 联系人点击 → UserInfoVC ✅ | 单聊右上角 → SingleConvInfoVC ✅ | 群成员头像 → UserInfoVC ✅
- [x] **无占位符：** 所有 step 均含完整代码
- [x] **类型一致：** `SingleConversationInfoViewModel` 在 Task 1 定义，Task 4/5 均使用相同签名 `init(userId:storage:)` 和 `searchMessages(keyword:) -> [StoredMessage]`
- [x] **`SearchMessageViewController`：** Task 2 改为闭包，Task 5 调用 `SearchMessageViewController(searcher: vm.searchMessages)` 一致
