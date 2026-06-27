# 群组详情页重设计规格

**日期：** 2026-06-27  
**目标：** iOS 群组详情页（`GroupInfoViewController`）对标 Android `GroupConversationInfoFragment`，补齐全部功能，采用方案 B（分节 TableView + 类型化 Row 枚举）实现。

---

## 1. 背景

现有 iOS `GroupInfoViewController` 仅有：顶部横条（头像 + 群名）、成员竖列表（`ContactListCell`）、底部退出/解散按钮。Android 版本已实现完整的分节详情页，iOS 缺失以下功能：成员 Grid 布局、二维码、群公告、查找聊天记录、消息免打扰、置顶聊天、保存到通讯录、我的群昵称、显示成员昵称、清空聊天记录。

---

## 2. 功能范围

### 2.1 实现功能

| 功能 | 实现深度 |
|------|---------|
| 成员 Grid（5 列）+ +/- 按钮 | 完整实现，权限门控 |
| 群聊名称（点击改名） | 完整实现（已有，保留） |
| 二维码 | CoreImage 生成，push 全屏展示页 |
| 群公告 | 仅 UI（展示 + 编辑框架，不接 wire API） |
| 查找聊天记录 | 本地 DB LIKE 查询，新增搜索页 |
| 消息免打扰 | 写 `ConversationStore.setMuted()`（新增） |
| 置顶聊天 | 写 `ConversationStore.setTop()`（已有） |
| 保存到通讯录 | 本地 `StoredGroup.isFav` 字段持久化 |
| 我在本群的昵称 | 仅 UI 弹框，不持久化 |
| 显示群成员昵称 | `UserDefaults` 本地开关 |
| 清空聊天记录 | 本地删除，`MessageStore.clearMessages()` |
| 退出群组 / 解散群组 | 已有，保留 |

### 2.2 不在本次范围

- 群公告 wire API 持久化
- 我在本群的昵称 wire API 持久化
- 保存到通讯录 wire API 同步
- 群管理入口（Android 也未实现）
- 消息搜索高亮、分页

---

## 3. 页面布局

```
┌─────────────────────────────────────┐
│  < 返回        会话详情              │  NavigationBar
├─────────────────────────────────────┤
│  [头像] [头像] [头像] [头像] [头像]  │  成员 Grid（5 列）
│  [头像] [头像] [ + ] [ - ]          │  +/- 按钮尾部追加
├─ 灰色间距 ──────────────────────────┤
│  群聊名称          【群名称】    >   │
│  ─────────────────────────────────  │  Section A
│  二维码                        [QR] │  群信息
│  ─────────────────────────────────  │
│  群公告                         >   │
├─ 灰色间距 ──────────────────────────┤
│  查找聊天记录                   >   │  Section B
├─ 灰色间距 ──────────────────────────┤
│  消息免打扰              [Switch]   │
│  ─────────────────────────────────  │  Section C
│  置顶聊天                [Switch]   │  会话设置
│  ─────────────────────────────────  │
│  保存到通讯录            [Switch]   │
├─ 灰色间距 ──────────────────────────┤
│  我在本群的昵称                 >   │  Section D
│  ─────────────────────────────────  │  个人设置
│  显示群成员昵称          [Switch]   │
├─ 灰色间距 ──────────────────────────┤
│  清空聊天记录                   >   │  Section E
├─────────────────────────────────────┤
│  ┌─────────────────────────────┐    │
│  │   退出群组 / 解散群组（红）  │    │  固定底部
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

### 视觉规范

- 页面标题：「会话详情」
- Section 间距背景色：`Theme.backgroundSecondary`（灰），高度 10pt
- Section 内部背景：`Theme.backgroundPrimary`（白）
- 行高：50pt
- 行内分隔线：左侧 15pt 缩进，颜色 `UIColor.separator`
- 成员 Grid 上下 padding：15pt，左右 7pt
- 底部按钮：高 44pt，圆角 4pt，`UIColor.systemRed` 背景，白色文字，左右各 16pt margin，距底 safeArea 20pt

---

## 4. 架构设计

### 4.1 Row 枚举建模

```swift
// GroupInfoViewController 内部
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
    case groupNotice(String?)
    case searchMessages
    case mute(Bool)
    case stickTop(Bool)
    case saveToContacts(Bool)
    case myNickname(String?)
    case showMemberNicknames(Bool)
    case clearMessages
}
```

`UITableViewDiffableDataSource<Section, Row>` 驱动，Bool 状态变更只 reapply snapshot 对应行。

### 4.2 Cell 类型

| Cell | 用途 | 注册标识符 |
|------|------|-----------|
| `ToggleSwitchCell` | 左 label + 右 UISwitch | `"ToggleSwitchCell"` |
| `NavigationRowCell` | 左 label + 右 detail text + 箭头 | `"NavigationRowCell"` |
| `TextValueRowCell` | 左 label + 右灰色值文本 | `"TextValueRowCell"` |

所有 Cell 在 `viewDidLoad` 统一注册，配置逻辑在 `cellProvider` 闭包内按 `Row` case switch。

### 4.3 GroupMemberGridView

- `UICollectionView`，`UICollectionViewFlowLayout`，`numberOfColumns = 5`
- 每个 item 尺寸 = `(width - 14) / 5`，正方形
- 数据末尾追加 `+` cell（`canAdd`）、`-` cell（`canRemove`）
- `var onAddTapped: (() -> Void)?`
- `var onRemoveTapped: (() -> Void)?`
- `var onMemberTapped: ((String) -> Void)?`
- 作为 `tableView.tableHeaderView` 嵌入，高度自适应行数

### 4.4 GroupInfoViewModel 扩展

在现有 `GroupInfoViewModel` 增加：

```swift
// 会话设置状态（从 ConversationStore 初始化）
@Published public private(set) var isTop: Bool = false
@Published public private(set) var isMuted: Bool = false
@Published public private(set) var isFav: Bool = false

// 初始化时增加 conversationType + conversationStore 参数
// 订阅 ConversationStore publisher，同步 isTop/isMuted

func setTop(_ value: Bool)        // ConversationStore.setTop()
func setMuted(_ value: Bool)      // ConversationStore.setMuted()（新增）
func setFav(_ value: Bool)        // GroupStore.setFav()（新增，写 isFav 字段）
func clearMessages(completion: @escaping (Result<Void, Error>) -> Void)
func searchMessages(keyword: String) -> [StoredMessage]
```

### 4.5 导航路由（closure 注入，SceneDelegate 负责绑定）

```swift
var onAddMembersTapped: (() -> Void)?       // 已有
var onRemoveMembersTapped: (() -> Void)?    // 新增
var onMemberTapped: ((String) -> Void)?     // 新增
var onQRCodeTapped: (() -> Void)?           // 新增
var onGroupNoticeTapped: (() -> Void)?      // 新增
var onSearchMessagesTapped: (() -> Void)?   // 新增
```

---

## 5. Storage 层改动

### 5.1 ConversationStore.setMuted()（新增）

```swift
// IMStorage/ConversationStore.swift
public func setMuted(_ isMuted: Bool, conversationType: ConversationType, target: String, line: Int = 0) throws {
    try dbQueue.write { db in
        try db.execute(
            sql: "UPDATE conversation SET isMuted = ? WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [isMuted, conversationType.rawValue, target, line]
        )
    }
}
```

### 5.2 StoredGroup.isFav 字段（新增）

- `IMStorage/StoredGroup.swift`：增加 `public var isFav: Bool = false`
- `IMStorage/IMDatabase.swift`：migration 中 `ALTER TABLE groupInfo ADD COLUMN isFav BOOLEAN NOT NULL DEFAULT 0`
- `GroupStore`：新增 `setFav(_ isFav: Bool, groupId: String)` 方法

### 5.3 MessageStore.clearMessages()（新增）

```swift
// IMStorage/MessageStore.swift
public func clearMessages(conversationType: ConversationType, target: String, line: Int = 0) throws {
    try dbQueue.write { db in
        try db.execute(
            sql: "DELETE FROM message WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [conversationType.rawValue, target, line]
        )
    }
}
```

### 5.4 MessageStore.searchMessages()（新增）

```swift
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

---

## 6. 新增页面

### GroupQRCodeViewController
- 展示：群头像（中心大图）、群名（标题）、CoreImage 生成的 QR 码
- QR 内容：`"group:<groupId>"`
- 无交互，`navigationItem.rightBarButtonItem` 可选「分享」（本次不实现）

### GroupNoticeViewController
- 展示群公告文本（`UITextView`，只读）
- Owner 权限时右上角「编辑」按钮 → 切换 `UITextView` 为可编辑（不调 API，仅本地展示）

### SearchMessageViewController
- 顶部 `UISearchBar`
- 结果 `UITableView`，每行显示：发送人头像 + 名称、消息摘要、时间
- 输入变化时调 `viewModel.searchMessages(keyword:)` 实时过滤
- 点击结果行（本次仅 dismiss，后续可跳转到具体消息位置）

---

## 7. 权限控制矩阵

| UI 元素 | 条件 |
|---------|------|
| [+] 添加成员 | `canAddMembers == true` |
| [-] 移除成员 | `canKickMembers == true` |
| 群聊名称（可点击） | `canModifyInfo == true`；否则不可点 |
| 群公告「编辑」按钮 | `canModifyInfo == true` |
| 底部按钮文字 | Owner → 「解散群组」；普通成员 → 「退出群组」|

---

## 8. 文件改动清单

### 新建文件
- `App/GroupMemberGridView.swift`
- `App/ToggleSwitchCell.swift`
- `App/NavigationRowCell.swift`
- `App/TextValueRowCell.swift`
- `App/GroupQRCodeViewController.swift`
- `App/GroupNoticeViewController.swift`
- `App/SearchMessageViewController.swift`

### 修改文件
- `App/GroupInfoViewController.swift` — 全面重写
- `Sources/IMKit/GroupInfoViewModel.swift` — 新增会话设置字段和方法
- `Sources/IMStorage/ConversationStore.swift` — 新增 `setMuted()`
- `Sources/IMStorage/StoredGroup.swift` — 新增 `isFav` 字段
- `Sources/IMStorage/GroupStore.swift` — 新增 `setFav()`
- `Sources/IMStorage/MessageStore.swift` — 新增 `clearMessages()` 和 `searchMessages()`
- `Sources/IMStorage/IMDatabase.swift` — 新增 migration
- `App/SceneDelegate.swift` — 绑定新增 closure

---

## 9. 不涉及改动的文件

- `Sources/IMKit/GroupActing.swift` — 无新 wire API
- `Sources/IMGroups/GroupSyncService.swift` — 无新 wire 调用
- `App/AddGroupMemberViewController.swift` — 保持不变
- `App/ConversationViewController.swift` — 保持不变
