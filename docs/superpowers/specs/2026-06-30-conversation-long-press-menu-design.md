# 会话列表长按菜单设计文档

**日期：** 2026-06-30  
**状态：** 已批准，待实施  
**参考：** Android 版飞享 IM 会话列表长按菜单

---

## 1. 功能概述

在会话列表（`ConversationListViewController`）中长按任意会话行，弹出 iOS 原生上下文菜单（`UIContextMenuConfiguration`），提供三项操作：

- **置顶 / 取消置顶**：将会话固定在列表顶部，再次选择取消置顶
- **清空会话**：删除该会话所有消息，保留会话行（预览文本清空）
- **删除会话**：从列表彻底移除该会话及其所有消息

---

## 2. 架构

### 2.1 分层概览

```
App/ConversationListViewController   ← UI 层：实现长按代理、弹出确认 Alert
IMKit/ConversationListViewModel      ← ViewModel 层：新增三个 action 方法
IMStorage/ConversationStore          ← Storage 层：新增两个写方法
IMStorage/MessageStore               ← 已有 clearMessages，无需改动
```

### 2.2 依赖方向

仅在已有依赖方向上新增代码，不引入新的跨层引用。

---

## 3. 数据层（`IMStorage`）

### 3.1 `ConversationStore` 新增方法

#### `deleteConversation(conversationType:target:line:)`

```swift
public func deleteConversation(
    conversationType: ConversationType,
    target: String,
    line: Int = 0
) throws
```

- 执行 `DELETE FROM conversation WHERE conversationType = ? AND target = ? AND line = ?`
- 写事务自包含（单次 `dbQueue.write`）
- 行删除触发 GRDB `ValueObservation`，`conversationsPublisher` 自动下发更新，列表动画移除该行

#### `resetLastMessage(conversationType:target:line:)`

```swift
public func resetLastMessage(
    conversationType: ConversationType,
    target: String,
    line: Int = 0
) throws
```

- 将现有会话行的 `lastMessageUid` 设为 `NULL` 并 re-save
- 若会话行不存在则 no-op
- re-save 触发 GRDB `ValueObservation`，ViewModel 重新派生 `previewText`（`lastMessage` 为 nil → 空字符串）
- `timestamp` 和排序不受影响，会话行继续留在列表中

### 3.2 `MessageStore` — 无改动

`clearMessages(conversationType:target:line:)` 已存在，直接复用。

---

## 4. ViewModel 层（`IMKit/ConversationListViewModel`）

新增三个公开 action 方法（均为同步、可抛出，调用方在主队列调用）：

### `setTop(_:for:)`

```swift
public func setTop(_ isTop: Bool, for row: ConversationRow) throws
```

调用 `storage.conversations.setTop(isTop, conversationType: row.conversationType, target: row.target, line: row.line)`。

### `clearConversation(_:)`

```swift
public func clearConversation(_ row: ConversationRow) throws
```

顺序执行：
1. `storage.messages.clearMessages(conversationType: row.conversationType, target: row.target, line: row.line)`
2. `storage.conversations.resetLastMessage(conversationType: row.conversationType, target: row.target, line: row.line)`

两步独立写事务，SQLite 本地操作，顺序写不需原子性保证。

### `deleteConversation(_:)`

```swift
public func deleteConversation(_ row: ConversationRow) throws
```

顺序执行：
1. `storage.messages.clearMessages(conversationType: row.conversationType, target: row.target, line: row.line)`
2. `storage.conversations.deleteConversation(conversationType: row.conversationType, target: row.target, line: row.line)`

---

## 5. UI 层（`App/ConversationListViewController`）

### 5.1 上下文菜单

实现 `UITableViewDelegate` 方法：

```swift
func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
) -> UIContextMenuConfiguration?
```

- 通过 `dataSource.itemIdentifier(for: indexPath)` 获取 `ConversationRow`
- 返回 `UIContextMenuConfiguration`，`previewProvider` 为 nil（使用系统默认 Cell 预览）

### 5.2 菜单项定义

| 菜单项 | SF Symbol | `UIAction.Attributes` | 行为 |
|---|---|---|---|
| 清空会话 | `trash` | `.destructive` | 弹确认 Alert，确认后调 `viewModel.clearConversation(_:)` |
| 删除会话 | `xmark.circle` | `.destructive` | 弹确认 Alert，确认后调 `viewModel.deleteConversation(_:)` |
| 置顶 / 取消置顶 | `pin` / `pin.slash` | 无（普通） | 直接调 `viewModel.setTop(!row.isTop, for: row)` |

菜单文案"置顶"或"取消置顶"根据 `row.isTop` 动态决定。

### 5.3 确认 Alert（清空 & 删除）

```
标题：清空会话 / 删除会话
正文：此操作不可撤销。
按钮：[取消]  [确认]（.destructive 红色）
```

置顶操作可逆，无需确认 Alert，直接执行。

### 5.4 错误处理

若 storage 方法抛出，展示 `UIAlertController`：

```
标题：操作失败
正文：error.localizedDescription
按钮：好
```

不使用 `try!` / `try?`，错误必须向用户明示。

### 5.5 列表自动刷新

三项操作均会改写 `conversation` 表：

- `setTop` → 更新 `isTop` 字段
- `clearConversation` → `resetLastMessage` re-save 行
- `deleteConversation` → DELETE 行

GRDB `ValueObservation` 自动触发 `conversationsPublisher` → ViewModel re-derive rows → `DiffableDataSource.apply` 动画更新，无需手动 `reloadData`。

---

## 6. 文件变更清单

| 文件 | 变更类型 |
|---|---|
| `Sources/IMStorage/ConversationStore.swift` | 新增 `deleteConversation` 和 `resetLastMessage` 方法 |
| `Sources/IMKit/ConversationListViewModel.swift` | 新增 `setTop(_:for:)` / `clearConversation(_:)` / `deleteConversation(_:)` |
| `App/ConversationListViewController.swift` | 实现 `contextMenuConfigurationForRowAt` 代理方法 |
| `Tests/IMStorageTests/ConversationStoreTests.swift` | 新增两个新方法的单元测试 |
| `Tests/IMKitTests/ConversationListViewModelTests.swift` | 新增三个 action 方法的单元测试 |

---

## 7. 测试策略

### 单元测试（`ConversationStoreTests`）

- `testDeleteConversation_removesRow`：插入行 → delete → 查询应为 nil
- `testResetLastMessage_clearsUidAndFiresObservation`：插入行（有 lastMessageUid）→ reset → 查询 lastMessageUid 应为 nil

### 单元测试（`ConversationListViewModelTests`）

- `testSetTop_updatesIsTop`：调用后 rows 中对应行 `isTop` 应变更
- `testClearConversation_clearsPreviewText`：插入消息 → clearConversation → rows 中对应行 `previewText` 应为空
- `testDeleteConversation_removesRow`：调用后 rows 中不应再包含该会话

### UI 验证（手动）

- 长按会话 → 菜单出现，三项文案正确
- 已置顶会话长按 → 菜单显示"取消置顶"
- 清空确认 → 会话行留存，预览文本消失
- 删除确认 → 会话行从列表移除
- 置顶后列表重排，置顶行排在最前
