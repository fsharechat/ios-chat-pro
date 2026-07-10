# 群聊 @ 提及增强 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 群聊点对方头像在输入框插入 @；`@` 触发的选人页改为拼音分组 + 头像 + 字母索引 + 「所有人」置顶；修复 `@@` 双 at bug。

**Architecture:** IMKit 层补数据（`StoredMessageRow.senderUid`、`MentionCandidate` 带头像、`PinyinIndexer.sections` 通用分组助手），App 层重写 `MentionPickerViewController`（复用联系人页 diffable + sectionIndex 模式）并给 6 个消息 cell 加头像点击回调。

**Tech Stack:** Swift / UIKit / Combine / GRDB（无 schema 改动）/ XCTest（SPM）。

**Spec:** `docs/superpowers/specs/2026-07-10-group-mention-design.md`

## Global Constraints

- 所有回复、注释风格遵循仓库现有中文惯例。
- 依赖方向严格单向：IMKit 不得 import UIKit；App 只通过 IMKit 拿数据。
- 线程模型无锁，全部主队列调用（现状保持）。
- `swift test` 主干存在固有失败基线（WebRTC macOS 切片等），只以 `--filter IMKitTests` 的结果为准，不得把既有失败误判为回归。
- **提交纪律（用户明确要求，覆盖本模板的每任务提交步骤）：全部任务完成、xcodebuild 通过、装机交用户手测通过后，才做一次性 commit。任务内的 "Commit" 步骤一律跳过，改为在最终任务统一提交。**

---

### Task 1: IMKit — `PinyinIndexer.sections` 通用分组助手 + `ContactListViewModel` 复用

**Files:**
- Modify: `Sources/IMKit/PinyinIndexer.swift`
- Modify: `Sources/IMKit/ContactListViewModel.swift:50-59`
- Test: `Tests/IMKitTests/PinyinIndexerTests.swift`

**Interfaces:**
- Produces: `PinyinIndexer.sections<T>(of items: [T], name: (T) -> String) -> [(letter: String, items: [T])]` — 按首字母 A–Z 分组、`#` 垫底、组内按 `sortKey` 排序。Task 4 的选人页与 `ContactListViewModel` 共用。

- [ ] **Step 1: 写失败测试**

在 `Tests/IMKitTests/PinyinIndexerTests.swift` 末尾（类内）追加：

```swift
    func test_sections_groupsSortsAndPutsHashLast() {
        let names = ["1", "云朵爸爸", "A玖先生", "飞享-官方测试2", "刘维涛", "ljlong2009"]

        let sections = PinyinIndexer.sections(of: names, name: { $0 })

        XCTAssertEqual(sections.map(\.letter), ["A", "F", "L", "Y", "#"])
        // L 组内按 sortKey 排序："刘维涛"→"liu wei tao" < "ljlong2009"（i < j），
        // 与 Android 端顺序一致
        XCTAssertEqual(sections.first(where: { $0.letter == "L" })?.items, ["刘维涛", "ljlong2009"])
        XCTAssertEqual(sections.last?.items, ["1"])
    }

    func test_sections_emptyInput_returnsEmpty() {
        XCTAssertTrue(PinyinIndexer.sections(of: [String](), name: { $0 }).isEmpty)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMKitTests/PinyinIndexerTests`
Expected: 编译失败 — `type 'PinyinIndexer' has no member 'sections'`

- [ ] **Step 3: 实现 `sections`**

在 `Sources/IMKit/PinyinIndexer.swift` 的 `enum PinyinIndexer` 内、`sortKey` 之后追加：

```swift
    /// 按 `sectionLetter` 分组并排序：字母组升序、"#" 垫底，组内按
    /// `sortKey` 升序。联系人列表与 @ 选人页共用。
    public static func sections<T>(of items: [T], name: (T) -> String) -> [(letter: String, items: [T])] {
        let grouped = Dictionary(grouping: items, by: { sectionLetter(for: name($0)) })
        let letters = grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        return letters.map { letter in
            (letter: letter, items: grouped[letter]!.sorted { sortKey(for: name($0)) < sortKey(for: name($1)) })
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMKitTests/PinyinIndexerTests`
Expected: PASS（含新增 2 个用例）

- [ ] **Step 5: `ContactListViewModel` 改用助手**

`Sources/IMKit/ContactListViewModel.swift` 中 `handleFriendsUpdate` 尾部的分组代码：

```swift
        let grouped = Dictionary(grouping: rows, by: { $0.sectionLetter })
        let sortedLetters = grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        sections = sortedLetters.map { letter in
            let sortedRows = grouped[letter]!.sorted { PinyinIndexer.sortKey(for: $0.displayName) < PinyinIndexer.sortKey(for: $1.displayName) }
            return (letter: letter, rows: sortedRows)
        }
```

替换为：

```swift
        sections = PinyinIndexer.sections(of: rows, name: \.displayName)
            .map { (letter: $0.letter, rows: $0.items) }
```

- [ ] **Step 6: 回归联系人 VM 测试**

Run: `swift test --filter IMKitTests/ContactListViewModelTests`
Expected: PASS（分组行为不变）

---

### Task 2: IMKit — `MentionCandidate`（带头像）替换元组返回值

**Files:**
- Modify: `Sources/IMKit/ConversationViewModel.swift:143-153`
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift:376-392`

**Interfaces:**
- Produces: `public struct MentionCandidate { let uid: String; let displayName: String; let avatarURL: String? }`；`ConversationViewModel.groupMemberCandidatesForMention() -> [MentionCandidate]`。Task 4 的选人页、Task 5 的头像点击昵称兜底都消费它。

- [ ] **Step 1: 改测试（新增头像断言）**

`Tests/IMKitTests/ConversationViewModelTests.swift` 中 `test_groupMemberCandidatesForMention_returnsActiveMembersWithDisplayNames` 改为：

```swift
    func test_groupMemberCandidatesForMention_returnsActiveMembersWithDisplayNames() throws {
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u2", memberType: .normal, updateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u3", memberType: .removed, updateDt: 0))
        try storage.users.upsertProfile(uid: "u2", name: nil, displayName: "Bob", portrait: "http://p/u2.png", mobile: nil, gender: 0, updateDt: 0)
        let viewModel = makeGroupViewModel(target: "g1")

        let candidates = viewModel.groupMemberCandidatesForMention()

        XCTAssertEqual(candidates.map(\.uid), ["u2"])
        XCTAssertEqual(candidates.map(\.displayName), ["Bob"])
        XCTAssertEqual(candidates.map(\.avatarURL), ["http://p/u2.png"])
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMKitTests/ConversationViewModelTests/test_groupMemberCandidatesForMention`
Expected: 编译失败 — 元组无 `avatarURL` 成员

- [ ] **Step 3: 实现 `MentionCandidate`**

`Sources/IMKit/ConversationViewModel.swift`：在 `groupMemberCandidatesForMention()` 方法上方（类外部、文件内合适位置，如文件顶部 import 之后）加：

```swift
/// 输入框 @ 选人页的候选成员。
public struct MentionCandidate: Equatable {
    public let uid: String
    public let displayName: String
    public let avatarURL: String?

    public init(uid: String, displayName: String, avatarURL: String?) {
        self.uid = uid
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}
```

方法体改为：

```swift
    public func groupMemberCandidatesForMention() -> [MentionCandidate] {
        guard conversationType == .group else { return [] }
        let members = (try? storage.groups.members(groupId: target)) ?? []
        return members.map { member in
            let user = try? storage.users.user(uid: member.memberId)
            return MentionCandidate(
                uid: member.memberId,
                displayName: user?.displayName ?? user?.name ?? member.memberId,
                avatarURL: user?.portrait
            )
        }
    }
```

（方法的 doc 注释保留，`[(uid, displayName)]` 字样更新为 `MentionCandidate`。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMKitTests/ConversationViewModelTests`
Expected: PASS

---

### Task 3: IMKit — `StoredMessageRow.senderUid`

**Files:**
- Modify: `Sources/IMKit/ChatMessageRow.swift:57-117`
- Modify: `Sources/IMKit/ConversationViewModel.swift:479-497`（`buildStoredMessageRow`）
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift`

**Interfaces:**
- Produces: `StoredMessageRow.senderUid: String?` — 接收方向为 `message.from`，发送方向为 `nil`。Task 5 的头像点击消费它。

- [ ] **Step 1: 写失败测试**

`Tests/IMKitTests/ConversationViewModelTests.swift` 中 `test_groupMemberCandidatesForMention_onSingleChat_returnsEmpty` 之后追加：

```swift
    func test_incomingGroupMessage_rowCarriesSenderUid() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "u1",
            content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive
        ))
        let viewModel = makeGroupViewModel(target: "g1")

        guard case .message(let row) = try waitForFirstRow(viewModel) else { return XCTFail("expected .message") }
        XCTAssertEqual(row.senderUid, "u1")
    }

    func test_outgoingMessage_rowSenderUidIsNil() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "me",
            content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send
        ))
        let viewModel = makeGroupViewModel(target: "g1")

        guard case .message(let row) = try waitForFirstRow(viewModel) else { return XCTFail("expected .message") }
        XCTAssertNil(row.senderUid)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMKitTests/ConversationViewModelTests/test_incomingGroupMessage_rowCarriesSenderUid`
Expected: 编译失败 — `StoredMessageRow` 无 `senderUid`

- [ ] **Step 3: 加字段并填充**

`Sources/IMKit/ChatMessageRow.swift` 的 `StoredMessageRow`：

在 `public let senderAvatarURL: String?` 之后加：

```swift
    /// 发送者 uid，仅接收方向的消息非 nil — 群聊里点对方头像插入 @ 用；
    /// 自己发的消息为 nil，头像点击自然无动作。
    public let senderUid: String?
```

init 参数列表在 `senderAvatarURL: String? = nil,` 之后加 `senderUid: String? = nil,`，init 体内对应加 `self.senderUid = senderUid`。

`Sources/IMKit/ConversationViewModel.swift` 的 `buildStoredMessageRow` 返回处，在 `senderAvatarURL: senderAvatarURL,` 之后加：

```swift
            senderUid: message.direction == .receive ? message.from : nil,
```

同时更新 `StoredMessageRow` 的类型 doc 注释（第 53-56 行），补一句 senderUid 语义。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMKitTests/ConversationViewModelTests`
Expected: PASS

- [ ] **Step 5: IMKit 全量回归**

Run: `swift test --filter IMKitTests`
Expected: PASS（对照主干固有失败基线，无新增失败）

---

### Task 4: App — 重写 `MentionPickerViewController` + `presentMentionPicker` 适配 + `@@` 修复

**Files:**
- Rewrite: `App/MentionPickerViewController.swift`
- Modify: `App/ConversationViewController.swift:451-460`（`presentMentionPicker`）

**Interfaces:**
- Consumes: `MentionCandidate`（Task 2）、`PinyinIndexer.sections`（Task 1）、`ContactRow` / `ContactListCell` / `AvatarImageView`（既有）。
- Produces: `MentionPickerViewController(members: [MentionCandidate])`，回调签名不变：`onPicked: ((String?, String) -> Void)?`、`onCancelled: (() -> Void)?`。

- [ ] **Step 1: 重写选人页**

`App/MentionPickerViewController.swift` 整文件替换为：

```swift
import UIKit
import IMKit

/// 输入框敲 "@" 后弹出的选人页，Android 样式：「所有人」置顶（空
/// section、不显示 header、不进右侧索引），成员按拼音首字母分组 +
/// 头像 + 右侧字母索引。回调里 `uid == nil` 表示选了「所有人」。
final class MentionPickerViewController: UIViewController {

    /// diffable 快照的行类型：置顶「所有人」或普通成员行。
    fileprivate enum Item: Hashable {
        case all
        case member(ContactRow)
    }

    /// 空字符串 section 承载「所有人」；header 与索引条都要跳过它，
    /// 这是不能用 `ContactListDataSource` 直接复用的原因。
    private final class DataSource: UITableViewDiffableDataSource<String, Item> {
        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            let id = snapshot().sectionIdentifiers[section]
            return id.isEmpty ? nil : id
        }

        override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
            let titles = snapshot().sectionIdentifiers.filter { !$0.isEmpty }
            return titles.isEmpty ? nil : titles
        }

        override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
            snapshot().sectionIdentifiers.firstIndex(of: title) ?? 0
        }
    }

    private let sections: [(letter: String, rows: [ContactRow])]
    private let tableView = UITableView()
    private var dataSource: DataSource!

    var onPicked: ((_ uid: String?, _ displayName: String) -> Void)?
    /// 通过取消按钮关闭（而非选中某行）时回调 — 让调用方清掉输入框里
    /// 悬空的触发 "@"。
    var onCancelled: (() -> Void)?

    init(members: [MentionCandidate]) {
        let rows = members.map { candidate in
            ContactRow(
                uid: candidate.uid,
                displayName: candidate.displayName,
                avatarURL: candidate.avatarURL,
                sectionLetter: PinyinIndexer.sectionLetter(for: candidate.displayName)
            )
        }
        sections = PinyinIndexer.sections(of: rows, name: \.displayName)
            .map { (letter: $0.letter, rows: $0.items) }
        super.init(nibName: nil, bundle: nil)
        title = "选择群成员"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.register(MentionAllCell.self, forCellReuseIdentifier: MentionAllCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.sectionIndexColor = Theme.accent
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        dataSource = DataSource(tableView: tableView) { tableView, indexPath, item in
            switch item {
            case .all:
                return tableView.dequeueReusableCell(withIdentifier: MentionAllCell.reuseIdentifier, for: indexPath)
            case .member(let row):
                let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
                cell.configure(with: row)
                return cell
            }
        }
        applySnapshot()
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
        snapshot.appendSections([""])
        snapshot.appendItems([.all], toSection: "")
        snapshot.appendSections(sections.map { $0.letter })
        for section in sections {
            snapshot.appendItems(section.rows.map { .member($0) }, toSection: section.letter)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func cancelTapped() {
        onCancelled?()
        dismiss(animated: true)
    }
}

extension MentionPickerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .all:
            onPicked?(nil, "所有人")
        case .member(let row):
            onPicked?(row.uid, row.displayName)
        }
    }
}

/// 置顶的「所有人」行：蓝底群像图标 + 文字，布局尺寸对齐 `ContactListCell`。
private final class MentionAllCell: UITableViewCell {
    static let reuseIdentifier = "MentionAllCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.backgroundSecondary

        let iconContainer = UIView()
        iconContainer.backgroundColor = Theme.accent
        iconContainer.layer.cornerRadius = 20
        iconContainer.clipsToBounds = true
        iconContainer.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(systemName: "person.3.fill"))
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        let nameLabel = UILabel()
        nameLabel.text = "所有人"
        nameLabel.font = .systemFont(ofSize: 16, weight: .regular)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconContainer)
        contentView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),
            iconContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            iconContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            nameLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
```

- [ ] **Step 2: `presentMentionPicker` 修 `@@`**

`App/ConversationViewController.swift` 的 `presentMentionPicker()` 中 `onPicked` 闭包改为（先删触发 `@` 再插入）：

```swift
        picker.onPicked = { [weak self] uid, displayName in
            // 用户敲的触发 "@" 还留在输入框里，先删掉再插入完整的
            // "@昵称 "，否则会出现 "@@昵称"。
            self?.inputBar.removeTrailingMentionTrigger()
            self?.inputBar.insertMention(uid: uid, displayName: displayName)
            self?.dismiss(animated: true)
        }
```

其余行不动（`MentionPickerViewController(members:)` 的实参 `viewModel.groupMemberCandidatesForMention()` 类型已随 Task 2 变为 `[MentionCandidate]`，无需改）。

- [ ] **Step 3: 编译 App**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

---

### Task 5: App — 六个消息 cell 头像点击回调 + 会话页绑定

**Files:**
- Modify: `App/TextMessageCell.swift`（头像属性名 `senderAvatarImageView`）
- Modify: `App/ImageMessageCell.swift`（`senderAvatarImageView`）
- Modify: `App/VideoMessageCell.swift`（`senderAvatarImageView`）
- Modify: `App/LocationMessageCell.swift`（`senderAvatarImageView`）
- Modify: `App/VoiceMessageCell.swift`（头像属性名 `avatarView`）
- Modify: `App/FileMessageCell.swift`（`avatarView`）
- Modify: `App/ConversationViewController.swift:175-243`（dataSource cellProvider）

**Interfaces:**
- Consumes: `StoredMessageRow.senderUid`（Task 3）、`MentionCandidate`（Task 2）、`MessageInputBar.insertMention(uid:displayName:)`（既有）。
- Produces: 每个 cell 新增 `var onAvatarTapped: (() -> Void)?`。

- [ ] **Step 1: 六个 cell 加回调与手势**

对每个 cell 做同样三处改动（以 `TextMessageCell` 为例，其余 5 个把 `senderAvatarImageView` 换成各自的头像属性名）：

1. 回调声明，放在既有回调（如 `onRetryTapped`）旁边：

```swift
    /// 群聊里点对方头像 → 会话页在输入框插入 @；自己发的消息不绑定。
    var onAvatarTapped: (() -> Void)?
```

2. 布局方法（`layoutViews()` / `setupViews()` 等 init 调用的那个）内加手势（`AvatarImageView` 是 `UIImageView` 子类，默认关交互，必须显式打开）：

```swift
        senderAvatarImageView.isUserInteractionEnabled = true
        senderAvatarImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))
```

3. 类内加 action，并在 `prepareForReuse()` 里补 `onAvatarTapped = nil`（`VoiceMessageCell`、`FileMessageCell` 目前没有 `prepareForReuse`，新增 override，记得 `super.prepareForReuse()`）：

```swift
    @objc private func avatarTapped() { onAvatarTapped?() }
```

- [ ] **Step 2: 会话页绑定**

`App/ConversationViewController.swift`：在 `presentMentionPicker()` 旁边加辅助方法：

```swift
    /// 点对方头像插入 @（对齐 Android）：仅群聊、仅接收方向生效 ——
    /// 自己发的消息 senderUid 为 nil，点了没有任何动作。
    private func insertMentionFromAvatar(_ message: StoredMessageRow) {
        guard row.conversationType == .group, let uid = message.senderUid else { return }
        // 行内昵称可能因「显示群成员昵称」开关关闭而为 nil，从 mention
        // 候选里兜底解析，再不行退回 uid。
        let displayName = message.senderDisplayName
            ?? viewModel.groupMemberCandidatesForMention().first(where: { $0.uid == uid })?.displayName
            ?? uid
        inputBar.insertMention(uid: uid, displayName: displayName)
    }
```

dataSource cellProvider 的 6 个消息 case（`VoiceMessageCell`、`FileMessageCell`、`LocationMessageCell`、`TextMessageCell`、`VideoMessageCell`、`ImageMessageCell` —— 只限 `.message(let message)` 的 case，`pendingImage`/`pendingVideo` 是自己发的，不加）各加一行：

```swift
                cell.onAvatarTapped = { [weak self] in self?.insertMentionFromAvatar(message) }
```

- [ ] **Step 3: 编译 App**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

---

### Task 6: 全量验证 + 装机交付 +（用户验证通过后）提交

**Files:** 无新改动；验证与交付。

- [ ] **Step 1: SPM 回归**

Run: `swift test --filter IMKitTests`
Expected: PASS，无新增失败（对照主干固有失败基线）

- [ ] **Step 2: App 编译**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: 装机给用户手测**

按既有真机流程构建安装（Xcode 直装；失败时按记忆走 `devicectl` 兜底）。等待用户按 spec 验证清单手测：

1. 群聊点对方头像 → 输入框出现 `@昵称 `，发出后 Android 端收到提醒；
2. 点自己消息头像 → 无反应；
3. 输入 `@` → 选人页：字母分组、头像、右侧索引、「所有人」置顶；
4. 选人后输入框只有一个 `@`；
5. 单聊点头像 → 无反应。

- [ ] **Step 4: 用户确认通过后一次性提交**

```bash
git add Sources/IMKit App docs/superpowers
git commit -m "feat(App): 群聊点头像插入@，@选人页对齐 Android（拼音分组/头像/字母索引/所有人置顶）

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
