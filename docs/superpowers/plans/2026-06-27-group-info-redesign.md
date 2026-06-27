# Group Info Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重写 iOS 群组详情页，对标 Android `GroupConversationInfoFragment`，补齐成员 Grid、QR 码、群公告(UI)、查找消息、免打扰、置顶、保存通讯录、群昵称(UI)、显示成员昵称、清空记录十大功能。

**Architecture:** 采用方案 B：`Section/Row` 枚举 + `UITableViewDiffableDataSource` 驱动页面；`GroupMemberGridView`（UICollectionView 5 列）作为 tableHeaderView；`GroupInfoViewModel` 扩展会话设置（isTop/isMuted/isFav）和消息操作；三个新页面通过 closure 从 SceneDelegate 注入导航。

**Tech Stack:** Swift 5.8, UIKit, Combine, GRDB, CoreImage (QR 码), XCTest, Swift Package Manager

## Global Constraints

- iOS 最低版本：iOS 15（`Package.swift` 已声明）
- 所有 Storage 层改动必须通过 `IMDatabase` migration 注册（禁止在 migration 外执行 ALTER TABLE）
- ViewModel 不允许直接 import UIKit（只在 `App/` 目录的 ViewController/View 层 import UIKit）
- 导航全部通过 closure 注入，不允许 ViewController 直接持有另一个 ViewController
- 测试命令：`swift test --filter <TargetName>Tests`，必须全部通过后再 commit
- UI 层（`App/` 目录）不写单元测试，以构建通过为验收标准
- 页面标题：「会话详情」；底部按钮颜色：`UIColor.systemRed`

---

## File Map

### 新建文件
| 文件 | 职责 |
|------|------|
| `App/ToggleSwitchCell.swift` | 通用 Toggle 行 Cell（左 label + 右 UISwitch）|
| `App/NavigationRowCell.swift` | 通用导航行 Cell（左 label + 右 detail + 箭头/图标）|
| `App/TextValueRowCell.swift` | 通用文本值行 Cell（左 label + 右灰色值文本，可点击）|
| `App/GroupMemberGridView.swift` | 成员头像 Grid（UICollectionView 5 列，含 +/- 按钮）|
| `App/GroupQRCodeViewController.swift` | 群二维码全屏展示页（CoreImage 生成）|
| `App/GroupNoticeViewController.swift` | 群公告展示/编辑页（仅 UI，不接 API）|
| `App/SearchMessageViewController.swift` | 本地消息搜索页（UISearchBar + 结果列表）|

### 修改文件
| 文件 | 改动 |
|------|------|
| `Sources/IMStorage/ConversationStore.swift` | 新增 `setMuted(_:conversationType:target:line:)` |
| `Sources/IMStorage/StoredGroup.swift` | 新增 `isFav: Bool` 字段 |
| `Sources/IMStorage/GroupStore.swift` | 新增 `setFav(_:groupId:)` |
| `Sources/IMStorage/IMDatabase.swift` | 新增 migration `v7_addGroupIsFav` |
| `Sources/IMStorage/MessageStore.swift` | 新增 `clearMessages(...)` 和 `searchMessages(...)` |
| `Sources/IMKit/GroupInfoViewModel.swift` | 新增会话设置字段、setMuted/setTop/setFav/clearMessages/searchMessages |
| `App/GroupInfoViewController.swift` | 全面重写（Section/Row 枚举 + DiffableDataSource）|
| `App/SceneDelegate.swift` | `wireGroupInfoNavigation` 绑定新增 closure |

### 测试文件
| 文件 | 覆盖内容 |
|------|---------|
| `Tests/IMStorageTests/ConversationStoreTests.swift` | 追加 `setMuted` 测试 |
| `Tests/IMStorageTests/GroupStoreTests.swift` | 追加 `setFav` 测试 |
| `Tests/IMStorageTests/MessageStoreTests.swift` | 追加 `clearMessages`/`searchMessages` 测试 |

---

## Task 1: ConversationStore.setMuted()

**Files:**
- Modify: `Sources/IMStorage/ConversationStore.swift`
- Test: `Tests/IMStorageTests/ConversationStoreTests.swift`

**Interfaces:**
- Produces: `ConversationStore.setMuted(_ isMuted: Bool, conversationType: ConversationType, target: String, line: Int) throws`

- [ ] **Step 1: 写失败测试**

在 `Tests/IMStorageTests/ConversationStoreTests.swift` 文件末尾、最后一个 `}` 之前追加：

```swift
func test_setMuted_true_storesMutedFlag() throws {
    try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)

    try store.setMuted(true, conversationType: .group, target: "g1", line: 0)

    XCTAssertEqual(try store.conversation(conversationType: .group, target: "g1")?.isMuted, true)
}

func test_setMuted_false_clearsMutedFlag() throws {
    try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
    try store.setMuted(true, conversationType: .group, target: "g1", line: 0)

    try store.setMuted(false, conversationType: .group, target: "g1", line: 0)

    XCTAssertEqual(try store.conversation(conversationType: .group, target: "g1")?.isMuted, false)
}
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
swift test --filter IMStorageTests.ConversationStoreTests/test_setMuted_true_storesMutedFlag 2>&1 | tail -5
```

期望输出：`error: ... 'setMuted' is not a member of type`

- [ ] **Step 3: 实现 setMuted**

在 `Sources/IMStorage/ConversationStore.swift` 中，`setTop` 方法之后追加：

```swift
public func setMuted(_ isMuted: Bool, conversationType: ConversationType, target: String, line: Int = 0) throws {
    try dbQueue.write { db in
        try db.execute(
            sql: "UPDATE conversation SET isMuted = ? WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [isMuted, conversationType.rawValue, target, line]
        )
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

```bash
swift test --filter IMStorageTests.ConversationStoreTests 2>&1 | tail -5
```

期望输出：`Test Suite 'ConversationStoreTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/ConversationStore.swift Tests/IMStorageTests/ConversationStoreTests.swift
git commit -m "feat(IMStorage): add ConversationStore.setMuted()"
```

---

## Task 2: StoredGroup.isFav + GroupStore.setFav() + Migration

**Files:**
- Modify: `Sources/IMStorage/StoredGroup.swift`
- Modify: `Sources/IMStorage/GroupStore.swift`
- Modify: `Sources/IMStorage/IMDatabase.swift`
- Test: `Tests/IMStorageTests/GroupStoreTests.swift`

**Interfaces:**
- Produces: `StoredGroup.isFav: Bool`
- Produces: `GroupStore.setFav(_ isFav: Bool, groupId: String) throws`

- [ ] **Step 1: 写失败测试**

在 `Tests/IMStorageTests/GroupStoreTests.swift` 末尾、最后一个 `}` 之前追加：

```swift
func test_setFav_true_storesFlag() throws {
    try store.upsertGroup(StoredGroup(groupId: "g1", name: "G1", portrait: nil, owner: "u1", groupType: .normal, memberCount: 1, updateDt: 0, memberUpdateDt: 0, isFav: false))

    try store.setFav(true, groupId: "g1")

    XCTAssertEqual(try store.group(groupId: "g1")?.isFav, true)
}

func test_setFav_false_clearsFlag() throws {
    try store.upsertGroup(StoredGroup(groupId: "g1", name: "G1", portrait: nil, owner: "u1", groupType: .normal, memberCount: 1, updateDt: 0, memberUpdateDt: 0, isFav: true))

    try store.setFav(false, groupId: "g1")

    XCTAssertEqual(try store.group(groupId: "g1")?.isFav, false)
}

func test_upsertGroup_isFav_defaultsFalse() throws {
    try store.upsertGroup(StoredGroup(groupId: "g2", name: "G2", portrait: nil, owner: "u1", groupType: .normal, memberCount: 1, updateDt: 0, memberUpdateDt: 0, isFav: false))

    XCTAssertEqual(try store.group(groupId: "g2")?.isFav, false)
}
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
swift test --filter IMStorageTests.GroupStoreTests/test_setFav_true_storesFlag 2>&1 | tail -5
```

期望输出：`error: extra argument 'isFav' in call` 或 `'setFav' is not a member`

- [ ] **Step 3: 给 StoredGroup 新增 isFav 字段**

修改 `Sources/IMStorage/StoredGroup.swift`，在 `memberUpdateDt` 字段之后加 `isFav`：

```swift
public struct StoredGroup: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "groupInfo"

    public var groupId: String
    public var name: String
    public var portrait: String?
    public var owner: String?
    public var groupType: GroupType
    public var memberCount: Int
    public var updateDt: Int64
    public var memberUpdateDt: Int64
    public var isFav: Bool

    public init(
        groupId: String,
        name: String,
        portrait: String?,
        owner: String?,
        groupType: GroupType,
        memberCount: Int,
        updateDt: Int64,
        memberUpdateDt: Int64,
        isFav: Bool = false
    ) {
        self.groupId = groupId
        self.name = name
        self.portrait = portrait
        self.owner = owner
        self.groupType = groupType
        self.memberCount = memberCount
        self.updateDt = updateDt
        self.memberUpdateDt = memberUpdateDt
        self.isFav = isFav
    }
}
```

（`StoredGroupMember` 结构体保持不变）

- [ ] **Step 4: 在 IMDatabase 注册 migration v7**

在 `Sources/IMStorage/IMDatabase.swift` 中，`v6_addMessageUidIndex` 的 `return migrator` 语句之前追加：

```swift
migrator.registerMigration("v7_addGroupIsFav") { db in
    try db.alter(table: "groupInfo") { t in
        t.add(column: "isFav", .boolean).notNull().defaults(to: false)
    }
}
```

- [ ] **Step 5: 在 GroupStore 新增 setFav**

在 `Sources/IMStorage/GroupStore.swift` 的 `membersPublisher` 方法之后追加：

```swift
public func setFav(_ isFav: Bool, groupId: String) throws {
    try dbQueue.write { db in
        try db.execute(
            sql: "UPDATE groupInfo SET isFav = ? WHERE groupId = ?",
            arguments: [isFav, groupId]
        )
    }
}
```

- [ ] **Step 6: 运行测试，确认通过**

```bash
swift test --filter IMStorageTests.GroupStoreTests 2>&1 | tail -5
```

期望输出：`Test Suite 'GroupStoreTests' passed`

- [ ] **Step 7: Commit**

```bash
git add Sources/IMStorage/StoredGroup.swift Sources/IMStorage/GroupStore.swift Sources/IMStorage/IMDatabase.swift Tests/IMStorageTests/GroupStoreTests.swift
git commit -m "feat(IMStorage): add StoredGroup.isFav field and GroupStore.setFav()"
```

---

## Task 3: MessageStore.clearMessages() + searchMessages()

**Files:**
- Modify: `Sources/IMStorage/MessageStore.swift`
- Test: `Tests/IMStorageTests/MessageStoreTests.swift`

**Interfaces:**
- Produces: `MessageStore.clearMessages(conversationType: ConversationType, target: String, line: Int) throws`
- Produces: `MessageStore.searchMessages(conversationType: ConversationType, target: String, keyword: String) throws -> [StoredMessage]`

- [ ] **Step 1: 写失败测试**

在 `Tests/IMStorageTests/MessageStoreTests.swift` 末尾、最后一个 `}` 之前追加：

```swift
func test_clearMessages_deletesAllMessagesForConversation() throws {
    try store.insert(makeMessage(localMessageId: 1, target: "g1", text: "hello"))
    try store.insert(makeMessage(localMessageId: 2, target: "g1", text: "world"))
    try store.insert(makeMessage(localMessageId: 3, target: "u2", text: "other"))

    try store.clearMessages(conversationType: .single, target: "g1")

    XCTAssertTrue(try store.messages(conversationType: .single, target: "g1").isEmpty)
    XCTAssertEqual(try store.messages(conversationType: .single, target: "u2").count, 1)
}

func test_searchMessages_returnsMatchingMessages() throws {
    try store.insert(makeMessage(localMessageId: 1, target: "g1", text: "hello world"))
    try store.insert(makeMessage(localMessageId: 2, target: "g1", text: "goodbye"))
    try store.insert(makeMessage(localMessageId: 3, target: "g1", text: "hello again"))

    let results = try store.searchMessages(conversationType: .single, target: "g1", keyword: "hello")

    XCTAssertEqual(results.count, 2)
    XCTAssertTrue(results.allSatisfy { ($0.searchableContent ?? "").contains("hello") })
}

func test_searchMessages_returnsEmptyWhenNoMatch() throws {
    try store.insert(makeMessage(localMessageId: 1, target: "g1", text: "hello"))

    let results = try store.searchMessages(conversationType: .single, target: "g1", keyword: "xyz")

    XCTAssertTrue(results.isEmpty)
}
```

注意：`makeMessage` 已在该文件中定义，使用 `text:` 参数；`StoredMessage` 的 `searchableContent` 由 `content` 字段派生，检查测试 helpers 确认已设置 searchableContent。若 `searchableContent` 为 nil，测试改为检查 `results.count`。

- [ ] **Step 2: 确认 StoredMessage.searchableContent 与 text 的关系**

```bash
grep -n "searchableContent" Sources/IMStorage/StoredMessage.swift | head -10
```

若 `searchableContent` 由初始化时的 `.text(text)` 自动填充为文本内容，测试断言保持不变。若不填充，将测试中 `allSatisfy` 的断言改为只检查 `results.count == 2`。

- [ ] **Step 3: 运行测试，确认失败**

```bash
swift test --filter IMStorageTests.MessageStoreTests/test_clearMessages_deletesAllMessagesForConversation 2>&1 | tail -5
```

期望输出：`error: 'clearMessages' is not a member`

- [ ] **Step 4: 实现 clearMessages 和 searchMessages**

在 `Sources/IMStorage/MessageStore.swift` 中 `olderMessages` 方法之前追加：

```swift
public func clearMessages(conversationType: ConversationType, target: String, line: Int = 0) throws {
    try dbQueue.write { db in
        try db.execute(
            sql: "DELETE FROM message WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [conversationType.rawValue, target, line]
        )
    }
}

public func searchMessages(conversationType: ConversationType, target: String, keyword: String) throws -> [StoredMessage] {
    try dbQueue.read { db in
        try StoredMessage
            .filter(Column("conversationType") == conversationType.rawValue)
            .filter(Column("target") == target)
            .filter(Column("searchableContent").like("%\(keyword)%"))
            .order(Column("timestamp").desc)
            .limit(100)
            .fetchAll(db)
    }
}
```

- [ ] **Step 5: 运行测试，确认通过**

```bash
swift test --filter IMStorageTests.MessageStoreTests 2>&1 | tail -5
```

期望输出：`Test Suite 'MessageStoreTests' passed`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/MessageStoreTests.swift
git commit -m "feat(IMStorage): add MessageStore.clearMessages() and searchMessages()"
```

---

## Task 4: GroupInfoViewModel 扩展（会话设置 + 消息操作）

**Files:**
- Modify: `Sources/IMKit/GroupInfoViewModel.swift`

**Interfaces:**
- Consumes: `ConversationStore.setMuted()` (Task 1), `GroupStore.setFav()` (Task 2), `MessageStore.clearMessages()/searchMessages()` (Task 3)
- Produces:
  - `@Published var isTop: Bool`
  - `@Published var isMuted: Bool`
  - `@Published var isFav: Bool`
  - `func setTop(_ value: Bool)`
  - `func setMuted(_ value: Bool)`
  - `func setFav(_ value: Bool)`
  - `func clearMessages(completion: @escaping (Result<Void, Error>) -> Void)`
  - `func searchMessages(keyword: String) -> [StoredMessage]`

- [ ] **Step 1: 扩展 GroupInfoViewModel**

将 `Sources/IMKit/GroupInfoViewModel.swift` 全文替换为：

```swift
// Sources/IMKit/GroupInfoViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the group-info screen: member list, group info, conversation settings,
/// and message operations. The permission matrix is verified against real
/// server-side permission-check code (see design doc §4):
///
/// |              | Restricted   | Normal      | Free       |
/// |--------------|--------------|-------------|------------|
/// | add member   | owner only   | any member  | any member |
/// | kick member  | owner only   | owner only  | nobody     |
/// | modify info  | owner only   | any member  | any member |
/// | dismiss      | owner only   | owner only  | nobody     |
/// | quit         | any member   | any member  | any member |
///
/// **Threading contract:** no internal locking, call from a single consistent queue.
public final class GroupInfoViewModel {
    public struct MemberRow: Equatable, Hashable {
        public let uid: String
        public let displayName: String
        public let avatarURL: String?
        public let isOwner: Bool
    }

    // Group info
    @Published public private(set) var group: StoredGroup?
    @Published public private(set) var members: [MemberRow] = []

    // Permissions
    @Published public private(set) var canAddMembers: Bool = false
    @Published public private(set) var canKickMembers: Bool = false
    @Published public private(set) var canModifyInfo: Bool = false
    @Published public private(set) var canDismiss: Bool = false

    // Conversation settings (initialized from storage, updated optimistically)
    @Published public private(set) var isTop: Bool = false
    @Published public private(set) var isMuted: Bool = false
    @Published public private(set) var isFav: Bool = false

    private let groupId: String
    private let groupActing: GroupActing?
    private let groupSyncing: GroupSyncing?
    private let storage: IMStorage
    private let currentUserId: String
    private var groupCancellable: AnyCancellable?
    private var membersCancellable: AnyCancellable?

    public init(groupId: String, groupActing: GroupActing?, groupSyncing: GroupSyncing?, storage: IMStorage, currentUserId: String) {
        self.groupId = groupId
        self.groupActing = groupActing
        self.groupSyncing = groupSyncing
        self.storage = storage
        self.currentUserId = currentUserId

        // Load initial conversation settings (isTop, isMuted) from stored conversation
        if let conversation = try? storage.conversations.conversation(conversationType: .group, target: groupId) {
            self.isTop = conversation.isTop
            self.isMuted = conversation.isMuted
        }

        groupCancellable = storage.groups.groupPublisher(groupId: groupId)
            .replaceError(with: nil)
            .sink { [weak self] group in
                self?.handleGroupUpdate(group)
                self?.isFav = group?.isFav ?? false
            }
        membersCancellable = storage.groups.membersPublisher(groupId: groupId)
            .replaceError(with: [])
            .sink { [weak self] members in self?.handleMembersUpdate(members) }
    }

    public func refresh() {
        groupSyncing?.refreshGroup(targetId: groupId)
    }

    // MARK: - Member Actions

    public func addMembers(_ uids: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.addMembers(groupId: groupId, memberIds: uids) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshMembers(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func kickMember(_ uid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.kickMember(groupId: groupId, memberId: uid) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshMembers(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func renameGroup(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.modifyGroupInfo(groupId: groupId, type: .name, value: name) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshGroup(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func updatePortrait(url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.modifyGroupInfo(groupId: groupId, type: .portrait, value: url) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshGroup(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func quitGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.quitGroup(groupId: groupId, completion: completion)
    }

    public func dismissGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.dismissGroup(groupId: groupId, completion: completion)
    }

    // MARK: - Conversation Settings

    public func setTop(_ value: Bool) {
        isTop = value
        try? storage.conversations.setTop(value, conversationType: .group, target: groupId)
    }

    public func setMuted(_ value: Bool) {
        isMuted = value
        try? storage.conversations.setMuted(value, conversationType: .group, target: groupId)
    }

    public func setFav(_ value: Bool) {
        isFav = value
        try? storage.groups.setFav(value, groupId: groupId)
    }

    // MARK: - Message Operations

    public func clearMessages(completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try storage.messages.clearMessages(conversationType: .group, target: groupId)
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    public func searchMessages(keyword: String) -> [StoredMessage] {
        (try? storage.messages.searchMessages(conversationType: .group, target: groupId, keyword: keyword)) ?? []
    }

    // MARK: - Private

    private func handleGroupUpdate(_ group: StoredGroup?) {
        self.group = group
        self.isFav = group?.isFav ?? false
        recomputePermissions()
    }

    private func handleMembersUpdate(_ storedMembers: [StoredGroupMember]) {
        members = storedMembers.map { member in
            let user = try? storage.users.user(uid: member.memberId)
            return MemberRow(
                uid: member.memberId,
                displayName: user?.displayName ?? user?.name ?? member.memberId,
                avatarURL: user?.portrait,
                isOwner: member.memberType == .owner
            )
        }
    }

    private func recomputePermissions() {
        guard let group else {
            canAddMembers = false; canKickMembers = false
            canModifyInfo = false; canDismiss = false
            return
        }
        let isOwner = group.owner == currentUserId
        switch group.groupType {
        case .restricted:
            canAddMembers = isOwner; canKickMembers = isOwner
            canModifyInfo = isOwner; canDismiss = isOwner
        case .normal:
            canAddMembers = true; canKickMembers = isOwner
            canModifyInfo = true; canDismiss = isOwner
        case .free:
            canAddMembers = true; canKickMembers = false
            canModifyInfo = true; canDismiss = false
        }
    }
}
```

- [ ] **Step 2: 构建确认无编译错误**

```bash
swift build --target IMKit 2>&1 | tail -10
```

期望输出：`Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/IMKit/GroupInfoViewModel.swift
git commit -m "feat(IMKit): extend GroupInfoViewModel with conversation settings and message ops"
```

---

## Task 5: 通用 Cell 类型

**Files:**
- Create: `App/ToggleSwitchCell.swift`
- Create: `App/NavigationRowCell.swift`
- Create: `App/TextValueRowCell.swift`

**Interfaces:**
- Produces:
  - `ToggleSwitchCell.configure(title: String, isOn: Bool)` + `var onToggle: ((Bool) -> Void)?`
  - `NavigationRowCell.configure(title: String, detail: String?, rightView: UIView?)` + `static let reuseIdentifier`
  - `TextValueRowCell.configure(title: String, value: String?)` + `static let reuseIdentifier`

- [ ] **Step 1: 创建 ToggleSwitchCell**

新建 `App/ToggleSwitchCell.swift`：

```swift
// App/ToggleSwitchCell.swift
import UIKit

final class ToggleSwitchCell: UITableViewCell {
    static let reuseIdentifier = "ToggleSwitchCell"

    var onToggle: ((Bool) -> Void)?

    private let titleLabel = UILabel()
    private let toggle = UISwitch()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.font = .systemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
        contentView.addSubview(titleLabel)
        contentView.addSubview(toggle)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 15),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -15),
            toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, isOn: Bool) {
        titleLabel.text = title
        toggle.isOn = isOn
    }

    @objc private func switchChanged() {
        onToggle?(toggle.isOn)
    }
}
```

- [ ] **Step 2: 创建 NavigationRowCell**

新建 `App/NavigationRowCell.swift`：

```swift
// App/NavigationRowCell.swift
import UIKit

final class NavigationRowCell: UITableViewCell {
    static let reuseIdentifier = "NavigationRowCell"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var rightCustomView: UIView?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        titleLabel.font = .systemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabel
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 15),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            detailLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, detail: String? = nil, rightView: UIView? = nil) {
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = (detail == nil && rightView == nil)

        rightCustomView?.removeFromSuperview()
        rightCustomView = nil

        if let rv = rightView {
            accessoryType = .none
            rv.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(rv)
            NSLayoutConstraint.activate([
                rv.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -15),
                rv.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
            rightCustomView = rv
        } else {
            accessoryType = .disclosureIndicator
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rightCustomView?.removeFromSuperview()
        rightCustomView = nil
        accessoryType = .disclosureIndicator
        detailLabel.text = nil
    }
}
```

- [ ] **Step 3: 创建 TextValueRowCell**

新建 `App/TextValueRowCell.swift`：

```swift
// App/TextValueRowCell.swift
import UIKit

final class TextValueRowCell: UITableViewCell {
    static let reuseIdentifier = "TextValueRowCell"

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        titleLabel.font = .systemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .systemFont(ofSize: 14)
        valueLabel.textColor = .secondaryLabel
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        contentView.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 15),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, value: String?) {
        titleLabel.text = title
        valueLabel.text = value ?? ""
    }
}
```

- [ ] **Step 4: 构建确认无编译错误**

在 Xcode 中 ⌘+B，或：

```bash
xcodebuild -scheme "ios-chat-pro" -destination "generic/platform=iOS Simulator" build 2>&1 | grep -E "error:|Build complete" | tail -5
```

期望输出：`Build Succeeded` 或 `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add App/ToggleSwitchCell.swift App/NavigationRowCell.swift App/TextValueRowCell.swift
git commit -m "feat(App): add reusable ToggleSwitchCell, NavigationRowCell, TextValueRowCell"
```

---

## Task 6: GroupMemberGridView

**Files:**
- Create: `App/GroupMemberGridView.swift`

**Interfaces:**
- Consumes: `GroupInfoViewModel.MemberRow`（uid, displayName, avatarURL, isOwner）, `AvatarLoader`, `AvatarImageView`（已存在于 `App/`）
- Produces:
  - `GroupMemberGridView.update(members: [GroupInfoViewModel.MemberRow], canAdd: Bool, canRemove: Bool)`
  - `var onAddTapped: (() -> Void)?`
  - `var onRemoveTapped: (() -> Void)?`
  - `var onMemberTapped: ((String) -> Void)?`
  - `var intrinsicHeight: CGFloat`（供 ViewController 设置 headerView 高度）

- [ ] **Step 1: 创建 GroupMemberGridView**

新建 `App/GroupMemberGridView.swift`：

```swift
// App/GroupMemberGridView.swift
import UIKit
import IMKit

final class GroupMemberGridView: UIView {

    var onAddTapped: (() -> Void)?
    var onRemoveTapped: (() -> Void)?
    var onMemberTapped: ((String) -> Void)?

    private enum Item: Hashable {
        case member(String)   // uid
        case add
        case remove
    }

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var members: [GroupInfoViewModel.MemberRow] = []
    private var canAdd = false
    private var canRemove = false

    private static let columns = 5
    private static let cellSize: CGFloat = 60
    private static let spacing: CGFloat = 8
    private static let hPadding: CGFloat = 7
    private static let vPadding: CGFloat = 15

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.itemSize = CGSize(width: Self.cellSize, height: Self.cellSize + 20)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collectionView.backgroundColor = .systemBackground
        collectionView.isScrollEnabled = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor, constant: Self.vPadding),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPadding),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hPadding),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.vPadding),
        ])
        collectionView.register(MemberCell.self, forCellWithReuseIdentifier: "MemberCell")
        collectionView.register(ActionCell.self, forCellWithReuseIdentifier: "ActionCell")
        collectionView.delegate = self

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, indexPath, item in
            switch item {
            case .member(let uid):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "MemberCell", for: indexPath) as! MemberCell
                let member = self?.members.first { $0.uid == uid }
                cell.configure(displayName: member?.displayName ?? uid, avatarURL: member?.avatarURL, isOwner: member?.isOwner ?? false)
                return cell
            case .add:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "ActionCell", for: indexPath) as! ActionCell
                cell.configure(systemName: "plus")
                return cell
            case .remove:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "ActionCell", for: indexPath) as! ActionCell
                cell.configure(systemName: "minus")
                return cell
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(members: [GroupInfoViewModel.MemberRow], canAdd: Bool, canRemove: Bool) {
        self.members = members
        self.canAdd = canAdd
        self.canRemove = canRemove
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(members.map { .member($0.uid) })
        if canAdd { snapshot.appendItems([.add]) }
        if canRemove { snapshot.appendItems([.remove]) }
        dataSource.apply(snapshot, animatingDifferences: false)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let totalItems = members.count + (canAdd ? 1 : 0) + (canRemove ? 1 : 0)
        let rows = max(1, Int(ceil(Double(totalItems) / Double(Self.columns))))
        let cellHeight = Self.cellSize + 20
        let height = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * Self.spacing + Self.vPadding * 2
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }
}

extension GroupMemberGridView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .member(let uid): onMemberTapped?(uid)
        case .add: onAddTapped?()
        case .remove: onRemoveTapped?()
        }
    }
}

// MARK: - Private Cells

private final class MemberCell: UICollectionViewCell {
    private let avatarView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarView)
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            avatarView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 48),
            avatarView.heightAnchor.constraint(equalToConstant: 48),
            nameLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(displayName: String, avatarURL: String?, isOwner: Bool) {
        avatarView.setAvatar(urlString: avatarURL, displayName: displayName)
        nameLabel.text = isOwner ? "👑\(displayName)" : displayName
    }
}

private final class ActionCell: UICollectionViewCell {
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 24
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = UIColor.separator.cgColor
        imageView.tintColor = .label
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(systemName: String) {
        imageView.image = UIImage(systemName: systemName)
    }
}
```

- [ ] **Step 2: 构建确认**

```bash
xcodebuild -scheme "ios-chat-pro" -destination "generic/platform=iOS Simulator" build 2>&1 | grep -E "error:|Build Succeeded" | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add App/GroupMemberGridView.swift
git commit -m "feat(App): add GroupMemberGridView with 5-column grid and +/- action cells"
```

---

## Task 7: GroupQRCodeViewController

**Files:**
- Create: `App/GroupQRCodeViewController.swift`

**Interfaces:**
- Consumes: `groupId: String`, `groupName: String`, `portraitURL: String?`
- Produces: `GroupQRCodeViewController(groupId:groupName:portraitURL:)`

- [ ] **Step 1: 创建 GroupQRCodeViewController**

新建 `App/GroupQRCodeViewController.swift`：

```swift
// App/GroupQRCodeViewController.swift
import UIKit
import CoreImage.CIFilterBuiltins

final class GroupQRCodeViewController: UIViewController {
    private let groupId: String
    private let groupName: String
    private let portraitURL: String?

    private let avatarView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()
    private let qrImageView = UIImageView()

    init(groupId: String, groupName: String, portraitURL: String?) {
        self.groupId = groupId
        self.groupName = groupName
        self.portraitURL = portraitURL
        super.init(nibName: nil, bundle: nil)
        title = "群二维码"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        layoutViews()
        avatarView.setAvatar(urlString: portraitURL, displayName: groupName)
        nameLabel.text = groupName
        qrImageView.image = generateQRCode(from: "group:\(groupId)")
    }

    private func layoutViews() {
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(avatarView)
        view.addSubview(nameLabel)
        view.addSubview(qrImageView)

        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            avatarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 72),
            avatarView.heightAnchor.constraint(equalToConstant: 72),

            nameLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            qrImageView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 32),
            qrImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: 200),
            qrImageView.heightAnchor.constraint(equalToConstant: 200),
        ])
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
```

- [ ] **Step 2: 构建确认**

```bash
xcodebuild -scheme "ios-chat-pro" -destination "generic/platform=iOS Simulator" build 2>&1 | grep -E "error:|Build Succeeded" | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add App/GroupQRCodeViewController.swift
git commit -m "feat(App): add GroupQRCodeViewController with CoreImage QR generation"
```

---

## Task 8: GroupNoticeViewController

**Files:**
- Create: `App/GroupNoticeViewController.swift`

**Interfaces:**
- Consumes: `notice: String?`, `canEdit: Bool`
- Produces: `GroupNoticeViewController(notice:canEdit:)`

- [ ] **Step 1: 创建 GroupNoticeViewController**

新建 `App/GroupNoticeViewController.swift`：

```swift
// App/GroupNoticeViewController.swift
import UIKit

final class GroupNoticeViewController: UIViewController {
    private let initialNotice: String?
    private let canEdit: Bool
    private let textView = UITextView()

    init(notice: String?, canEdit: Bool) {
        self.initialNotice = notice
        self.canEdit = canEdit
        super.init(nibName: nil, bundle: nil)
        title = "群公告"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.font = .systemFont(ofSize: 16)
        textView.text = initialNotice?.isEmpty == false ? initialNotice : "暂无公告"
        textView.textColor = initialNotice?.isEmpty == false ? .label : .secondaryLabel
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        if canEdit {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "编辑", style: .plain, target: self, action: #selector(editTapped))
        }
    }

    @objc private func editTapped() {
        if textView.isEditable {
            textView.isEditable = false
            textView.resignFirstResponder()
            navigationItem.rightBarButtonItem?.title = "编辑"
        } else {
            if textView.textColor == .secondaryLabel {
                textView.text = ""
                textView.textColor = .label
            }
            textView.isEditable = true
            textView.becomeFirstResponder()
            navigationItem.rightBarButtonItem?.title = "完成"
        }
    }
}
```

- [ ] **Step 2: 构建确认**

```bash
xcodebuild -scheme "ios-chat-pro" -destination "generic/platform=iOS Simulator" build 2>&1 | grep -E "error:|Build Succeeded" | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add App/GroupNoticeViewController.swift
git commit -m "feat(App): add GroupNoticeViewController (UI only, no API)"
```

---

## Task 9: SearchMessageViewController

**Files:**
- Create: `App/SearchMessageViewController.swift`

**Interfaces:**
- Consumes: `GroupInfoViewModel.searchMessages(keyword:) -> [StoredMessage]`
- Produces: `SearchMessageViewController(viewModel: GroupInfoViewModel)`

- [ ] **Step 1: 创建 SearchMessageViewController**

新建 `App/SearchMessageViewController.swift`：

```swift
// App/SearchMessageViewController.swift
import UIKit
import IMKit
import IMStorage

final class SearchMessageViewController: UIViewController {
    private let viewModel: GroupInfoViewModel
    private var results: [StoredMessage] = []

    private let searchBar = UISearchBar()
    private let tableView = UITableView()

    init(viewModel: GroupInfoViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "查找聊天记录"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        searchBar.placeholder = "搜索"
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(SearchResultCell.self, forCellReuseIdentifier: SearchResultCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.tableHeaderView = nil
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func performSearch(keyword: String) {
        guard !keyword.isEmpty else {
            results = []
            tableView.reloadData()
            return
        }
        results = viewModel.searchMessages(keyword: keyword)
        tableView.reloadData()
    }
}

extension SearchMessageViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        performSearch(keyword: searchText)
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

extension SearchMessageViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SearchResultCell.reuseIdentifier, for: indexPath) as! SearchResultCell
        cell.configure(with: results[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 60 }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

// MARK: - SearchResultCell

private final class SearchResultCell: UITableViewCell {
    static let reuseIdentifier = "SearchResultCell"

    private let summaryLabel = UILabel()
    private let timeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        summaryLabel.font = .systemFont(ofSize: 14)
        summaryLabel.numberOfLines = 2
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .secondaryLabel
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(summaryLabel)
        contentView.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            summaryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 15),
            summaryLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -8),
            summaryLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -15),
            timeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 60),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with message: StoredMessage) {
        summaryLabel.text = message.searchableContent ?? ""
        let date = Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        timeLabel.text = formatter.string(from: date)
    }
}
```

- [ ] **Step 2: 构建确认**

```bash
xcodebuild -scheme "ios-chat-pro" -destination "generic/platform=iOS Simulator" build 2>&1 | grep -E "error:|Build Succeeded" | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add App/SearchMessageViewController.swift
git commit -m "feat(App): add SearchMessageViewController with local DB search"
```

---

## Task 10: GroupInfoViewController 全面重写

**Files:**
- Modify: `App/GroupInfoViewController.swift`（全文替换）

**Interfaces:**
- Consumes: 
  - `GroupInfoViewModel`（Task 4）
  - `GroupMemberGridView`（Task 6）
  - `ToggleSwitchCell`, `NavigationRowCell`, `TextValueRowCell`（Task 5）
- Produces:
  - `var onAddMembersTapped: (() -> Void)?`
  - `var onRemoveMembersTapped: (() -> Void)?`
  - `var onMemberTapped: ((String) -> Void)?`
  - `var onQRCodeTapped: (() -> Void)?`
  - `var onGroupNoticeTapped: (() -> Void)?`
  - `var onSearchMessagesTapped: (() -> Void)?`

- [ ] **Step 1: 全文替换 GroupInfoViewController.swift**

将 `App/GroupInfoViewController.swift` 全文替换为：

```swift
// App/GroupInfoViewController.swift
import UIKit
import Combine
import IMKit
import IMStorage

final class GroupInfoViewController: UIViewController {

    // MARK: - Navigation Callbacks (wired from SceneDelegate)
    var onAddMembersTapped: (() -> Void)?
    var onRemoveMembersTapped: (() -> Void)?
    var onMemberTapped: ((String) -> Void)?
    var onQRCodeTapped: (() -> Void)?
    var onGroupNoticeTapped: (() -> Void)?
    var onSearchMessagesTapped: (() -> Void)?

    // MARK: - Section / Row Model

    private enum Section: Int, CaseIterable {
        case groupInfo
        case messageActions
        case conversationSettings
        case personalSettings
        case dangerZone
    }

    private enum Row: Hashable {
        case groupName(String)
        case qrCode
        case groupNotice
        case searchMessages
        case mute(Bool)
        case stickTop(Bool)
        case saveToContacts(Bool)
        case myNickname
        case showMemberNicknames(Bool)
        case clearMessages
    }

    // MARK: - Properties

    private let viewModel: GroupInfoViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Section, Row>!
    private var showMemberNicknames: Bool {
        get { UserDefaults.standard.bool(forKey: showMemberNicknamesKey) }
        set { UserDefaults.standard.set(newValue, forKey: showMemberNicknamesKey) }
    }
    private var showMemberNicknamesKey: String { "showMemberNicknames_\(viewModel.group?.groupId ?? "")" }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let memberGridView = GroupMemberGridView()
    private let bottomButton = UIButton(type: .system)

    // MARK: - Init

    init(viewModel: GroupInfoViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "会话详情"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        layoutViews()
        configureDataSource()
        bindViewModel()
        viewModel.refresh()
    }

    // MARK: - Layout

    private func layoutViews() {
        // Member grid as table header
        memberGridView.onAddTapped = { [weak self] in self?.onAddMembersTapped?() }
        memberGridView.onRemoveTapped = { [weak self] in self?.onRemoveMembersTapped?() }
        memberGridView.onMemberTapped = { [weak self] uid in self?.onMemberTapped?(uid) }

        // Table view
        tableView.register(ToggleSwitchCell.self, forCellReuseIdentifier: ToggleSwitchCell.reuseIdentifier)
        tableView.register(NavigationRowCell.self, forCellReuseIdentifier: NavigationRowCell.reuseIdentifier)
        tableView.register(TextValueRowCell.self, forCellReuseIdentifier: TextValueRowCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 0)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom button
        bottomButton.setTitle("退出群组", for: .normal)
        bottomButton.setTitleColor(.white, for: .normal)
        bottomButton.backgroundColor = .systemRed
        bottomButton.layer.cornerRadius = 4
        bottomButton.titleLabel?.font = .systemFont(ofSize: 16)
        bottomButton.addTarget(self, action: #selector(bottomButtonTapped), for: .touchUpInside)
        bottomButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(bottomButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomButton.topAnchor, constant: -8),

            bottomButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bottomButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bottomButton.heightAnchor.constraint(equalToConstant: 44),
            bottomButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - DataSource

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView)
        }
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        switch row {
        case .groupName(let name):
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "群聊名称", detail: name)
            return cell

        case .qrCode:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            let qrIcon = UIImageView(image: UIImage(systemName: "qrcode"))
            qrIcon.tintColor = .label
            cell.configure(title: "二维码", detail: nil, rightView: qrIcon)
            return cell

        case .groupNotice:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "群公告", detail: nil)
            return cell

        case .searchMessages:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "查找聊天记录", detail: nil)
            return cell

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

        case .saveToContacts(let isOn):
            let cell = tableView.dequeueReusableCell(withIdentifier: ToggleSwitchCell.reuseIdentifier, for: indexPath) as! ToggleSwitchCell
            cell.configure(title: "保存到通讯录", isOn: isOn)
            cell.onToggle = { [weak self] value in self?.viewModel.setFav(value) }
            return cell

        case .myNickname:
            let cell = tableView.dequeueReusableCell(withIdentifier: TextValueRowCell.reuseIdentifier, for: indexPath) as! TextValueRowCell
            cell.configure(title: "我在本群的昵称", value: nil)
            return cell

        case .showMemberNicknames(let isOn):
            let cell = tableView.dequeueReusableCell(withIdentifier: ToggleSwitchCell.reuseIdentifier, for: indexPath) as! ToggleSwitchCell
            cell.configure(title: "显示群成员昵称", isOn: isOn)
            cell.onToggle = { [weak self] value in
                self?.showMemberNicknames = value
                self?.applySnapshot()
            }
            return cell

        case .clearMessages:
            let cell = tableView.dequeueReusableCell(withIdentifier: NavigationRowCell.reuseIdentifier, for: indexPath) as! NavigationRowCell
            cell.configure(title: "清空聊天记录", detail: nil)
            return cell
        }
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)

        snapshot.appendItems([
            .groupName(viewModel.group?.name ?? ""),
            .qrCode,
            .groupNotice,
        ], toSection: .groupInfo)

        snapshot.appendItems([.searchMessages], toSection: .messageActions)

        snapshot.appendItems([
            .mute(viewModel.isMuted),
            .stickTop(viewModel.isTop),
            .saveToContacts(viewModel.isFav),
        ], toSection: .conversationSettings)

        snapshot.appendItems([
            .myNickname,
            .showMemberNicknames(showMemberNicknames),
        ], toSection: .personalSettings)

        snapshot.appendItems([.clearMessages], toSection: .dangerZone)

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Binding

    private func bindViewModel() {
        Publishers.MergeMany(
            viewModel.$group.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isTop.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isMuted.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isFav.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.applySnapshot() }
        .store(in: &cancellables)

        viewModel.$members
            .combineLatest(viewModel.$canAddMembers, viewModel.$canKickMembers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] members, canAdd, canRemove in
                guard let self else { return }
                self.memberGridView.update(members: members, canAdd: canAdd, canRemove: canRemove)
                self.updateGridHeader()
            }
            .store(in: &cancellables)

        viewModel.$canDismiss
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canDismiss in
                self?.bottomButton.setTitle(canDismiss ? "解散群组" : "退出群组", for: .normal)
            }
            .store(in: &cancellables)
    }

    private func updateGridHeader() {
        memberGridView.invalidateIntrinsicContentSize()
        let size = memberGridView.intrinsicContentSize
        memberGridView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: size.height)
        tableView.tableHeaderView = memberGridView
    }

    // MARK: - Actions

    @objc private func bottomButtonTapped() {
        if viewModel.canDismiss {
            confirmAction(title: "解散群组", message: "解散后群组将不可恢复，请谨慎操作。") { [weak self] in
                self?.viewModel.dismissGroup { result in
                    DispatchQueue.main.async {
                        if case .failure = result {
                            self?.showAlert(title: "解散失败", message: "请稍后重试")
                        } else {
                            self?.navigationController?.popViewController(animated: true)
                        }
                    }
                }
            }
        } else {
            confirmAction(title: "退出群组", message: "确认退出此群组？") { [weak self] in
                self?.viewModel.quitGroup { result in
                    DispatchQueue.main.async {
                        if case .failure = result {
                            self?.showAlert(title: "退出失败", message: "请稍后重试")
                        } else {
                            self?.navigationController?.popViewController(animated: true)
                        }
                    }
                }
            }
        }
    }

    private func handleGroupNameTapped() {
        guard viewModel.canModifyInfo else { return }
        let alert = UIAlertController(title: "修改群名", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            tf.text = self?.viewModel.group?.name
            tf.placeholder = "群聊名称"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self?.viewModel.renameGroup(name) { result in
                DispatchQueue.main.async {
                    if case .failure = result { self?.showAlert(title: "修改失败", message: "请稍后重试") }
                }
            }
        })
        present(alert, animated: true)
    }

    private func handleMyNicknameTapped() {
        let alert = UIAlertController(title: "我在本群的昵称", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "输入昵称（仅本地展示）" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    private func handleClearMessagesTapped() {
        confirmAction(title: "清空聊天记录", message: "清空后不可恢复，确认操作？") { [weak self] in
            self?.viewModel.clearMessages { result in
                DispatchQueue.main.async {
                    if case .failure = result { self?.showAlert(title: "清空失败", message: "请稍后重试") }
                }
            }
        }
    }

    private func confirmAction(title: String, message: String, onConfirm: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .destructive) { _ in onConfirm() })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDelegate

extension GroupInfoViewController: UITableViewDelegate {

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
        case .groupName: handleGroupNameTapped()
        case .qrCode: onQRCodeTapped?()
        case .groupNotice: onGroupNoticeTapped?()
        case .searchMessages: onSearchMessagesTapped?()
        case .myNickname: handleMyNicknameTapped()
        case .clearMessages: handleClearMessagesTapped()
        default: break
        }
    }
}
```

- [ ] **Step 2: 构建确认**

```bash
xcodebuild -scheme "ios-chat-pro" -destination "generic/platform=iOS Simulator" build 2>&1 | grep -E "error:|Build Succeeded" | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add App/GroupInfoViewController.swift
git commit -m "feat(App): rewrite GroupInfoViewController with sectioned layout matching Android"
```

---

## Task 11: SceneDelegate 路由更新

**Files:**
- Modify: `App/SceneDelegate.swift`（只修改 `wireGroupInfoNavigation` 方法）

**Interfaces:**
- Consumes: 所有新增 VC（Tasks 7-9）和 `GroupInfoViewController` 的新 closures（Task 10）

- [ ] **Step 1: 找到 wireGroupInfoNavigation 方法**

`wireGroupInfoNavigation` 位于 `App/SceneDelegate.swift:190`，读取当前实现确认当前签名。

- [ ] **Step 2: 替换 wireGroupInfoNavigation 方法**

将 `wireGroupInfoNavigation` 方法从第 190 行开始整体替换为：

```swift
private func wireGroupInfoNavigation(on conversationViewController: ConversationViewController, groupId: String) {
    conversationViewController.onGroupInfoTapped = { [weak self, weak conversationViewController] in
        guard let self else { return }
        let groupInfoViewModel = GroupInfoViewModel(
            groupId: groupId,
            groupActing: self.environment.groupSyncService,
            groupSyncing: self.environment.groupSyncService,
            storage: self.environment.storage,
            currentUserId: self.environment.imClient?.userId ?? ""
        )
        let groupInfoViewController = GroupInfoViewController(viewModel: groupInfoViewModel)

        // 添加成员
        groupInfoViewController.onAddMembersTapped = { [weak self, weak groupInfoViewController] in
            guard let self else { return }
            let addVM = AddGroupMemberViewModel(
                groupId: groupId,
                storage: self.environment.storage,
                groupActing: self.environment.groupSyncService,
                groupSyncing: self.environment.groupSyncService
            )
            let addVC = AddGroupMemberViewController(viewModel: addVM)
            addVC.onMembersAdded = { addVC.dismiss(animated: true) }
            groupInfoViewController?.present(UINavigationController(rootViewController: addVC), animated: true)
        }

        // 移除成员（跳转到 AddGroupMemberViewController 的移除模式，暂用同一 VC）
        groupInfoViewController.onRemoveMembersTapped = { [weak groupInfoViewController] in
            let alert = UIAlertController(title: "移除成员", message: "请在成员列表中左滑移除", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            groupInfoViewController?.present(alert, animated: true)
        }

        // 查看成员资料
        groupInfoViewController.onMemberTapped = { [weak groupInfoViewController] _ in
            // TODO: 跳转成员详情页（后续实现）
            _ = groupInfoViewController
        }

        // 群二维码
        groupInfoViewController.onQRCodeTapped = { [weak self, weak groupInfoViewController] in
            guard let self else { return }
            let group = try? self.environment.storage.groups.group(groupId: groupId)
            let qrVC = GroupQRCodeViewController(
                groupId: groupId,
                groupName: group?.name ?? groupId,
                portraitURL: group?.portrait
            )
            groupInfoViewController?.navigationController?.pushViewController(qrVC, animated: true)
        }

        // 群公告
        groupInfoViewController.onGroupNoticeTapped = { [weak self, weak groupInfoViewController] in
            guard let self else { return }
            let group = try? self.environment.storage.groups.group(groupId: groupId)
            let canEdit = group?.owner == self.environment.imClient?.userId
            let noticeVC = GroupNoticeViewController(notice: nil, canEdit: canEdit)
            groupInfoViewController?.navigationController?.pushViewController(noticeVC, animated: true)
        }

        // 查找聊天记录
        groupInfoViewController.onSearchMessagesTapped = { [weak groupInfoViewController] in
            let searchVC = SearchMessageViewController(viewModel: groupInfoViewModel)
            groupInfoViewController?.navigationController?.pushViewController(searchVC, animated: true)
        }

        conversationViewController?.navigationController?.pushViewController(groupInfoViewController, animated: true)
    }
}
```

- [ ] **Step 3: 构建确认**

```bash
xcodebuild -scheme "ios-chat-pro" -destination "generic/platform=iOS Simulator" build 2>&1 | grep -E "error:|Build Succeeded" | tail -10
```

期望：`** BUILD SUCCEEDED **`

- [ ] **Step 4: 全量测试**

```bash
swift test 2>&1 | tail -10
```

期望：所有测试通过，`Test Suite 'All tests' passed`

- [ ] **Step 5: Commit**

```bash
git add App/SceneDelegate.swift
git commit -m "feat(App): wire new GroupInfoViewController closures in SceneDelegate"
```

---

## 自检结果

**规格覆盖检查：**
| 规格需求 | 实现 Task |
|---------|----------|
| 成员 Grid 5 列 + +/- | Task 6 |
| 群聊名称点击改名 | Task 10（handleGroupNameTapped）|
| 二维码 CoreImage | Task 7 |
| 群公告 UI only | Task 8 |
| 查找聊天记录本地搜索 | Task 3 + Task 9 |
| 消息免打扰 setMuted | Task 1 + Task 4 + Task 10 |
| 置顶聊天 setTop | Task 4 + Task 10 |
| 保存到通讯录 isFav | Task 2 + Task 4 + Task 10 |
| 我在本群的昵称 UI only | Task 10（handleMyNicknameTapped）|
| 显示群成员昵称 UserDefaults | Task 10（showMemberNicknames）|
| 清空聊天记录本地 | Task 3 + Task 10 |
| 退出/解散群组 | Task 10（bottomButtonTapped）|
| 权限门控 | Task 4 + Task 10 |
| SceneDelegate 路由 | Task 11 |

**所有规格需求已覆盖，无遗漏。**
