# 会话列表长按菜单 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在会话列表长按任意会话行，弹出原生上下文菜单，支持置顶/取消置顶、清空会话、删除会话三项操作。

**Architecture:** 在 `ConversationStore` 新增两个写方法；在 `ConversationListViewModel` 新增三个 action 方法；在 `ConversationListViewController` 实现 `UITableViewDelegate` 的 `contextMenuConfigurationForRowAt` 方法。全部通过 GRDB `ValueObservation` 自动刷新列表，无需手动 reload。

**Tech Stack:** Swift, UIKit, GRDB (ValueObservation/Publisher), Combine, XCTest

## Global Constraints

- 所有 Storage 层操作必须可抛出（`throws`），调用方在主队列调用，无内部锁
- 不使用 `try!` / `try?` 屏蔽错误；错误必须向用户明示（`UIAlertController`）
- 不引入新的第三方依赖
- 测试全部用内存数据库（`IMStorage.openInMemory()` / `IMDatabase.openInMemory()`）
- 编译目标：iOS 16+，Swift Package + Xcode App target

---

## 文件变更概览

| 文件 | 操作 |
|---|---|
| `Sources/IMStorage/ConversationStore.swift` | 新增 `deleteConversation` / `resetLastMessage` |
| `Sources/IMKit/ConversationListViewModel.swift` | 新增 `setTop(_:for:)` / `clearConversation(_:)` / `deleteConversation(_:)` |
| `App/ConversationListViewController.swift` | 新增 `contextMenuConfigurationForRowAt` 及辅助私有方法 |
| `Tests/IMStorageTests/ConversationStoreTests.swift` | 新增 5 个测试 |
| `Tests/IMKitTests/ConversationListViewModelTests.swift` | 新增 3 个测试 |

---

## Task 1: ConversationStore — 新增 deleteConversation 和 resetLastMessage

**Files:**
- Modify: `Sources/IMStorage/ConversationStore.swift`
- Test: `Tests/IMStorageTests/ConversationStoreTests.swift`

**Interfaces:**
- Produces:
  - `ConversationStore.deleteConversation(conversationType: ConversationType, target: String, line: Int) throws`
  - `ConversationStore.resetLastMessage(conversationType: ConversationType, target: String, line: Int) throws`

- [ ] **Step 1: 写失败测试（deleteConversation）**

在 `Tests/IMStorageTests/ConversationStoreTests.swift` 末尾（`}` 前）追加：

```swift
func test_deleteConversation_removesRow() throws {
    try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: false)

    try store.deleteConversation(conversationType: .single, target: "u2", line: 0)

    XCTAssertNil(try store.conversation(conversationType: .single, target: "u2"))
}

func test_deleteConversation_whenRowDoesNotExist_isNoOp() throws {
    XCTAssertNoThrow(try store.deleteConversation(conversationType: .single, target: "nonexistent", line: 0))
}
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
swift test --filter IMStorageTests/ConversationStoreTests/test_deleteConversation
```

预期：编译错误 `value of type 'ConversationStore' has no member 'deleteConversation'`

- [ ] **Step 3: 写失败测试（resetLastMessage）**

继续在同文件追加：

```swift
func test_resetLastMessage_clearsLastMessageUid() throws {
    try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 42, timestamp: 1_000, incrementUnread: false)

    try store.resetLastMessage(conversationType: .single, target: "u2", line: 0)

    XCTAssertNil(try store.conversation(conversationType: .single, target: "u2")?.lastMessageUid)
}

func test_resetLastMessage_preservesTimestampAndOtherFields() throws {
    try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 42, timestamp: 1_000, incrementUnread: true)

    try store.resetLastMessage(conversationType: .single, target: "u2", line: 0)

    let conversation = try store.conversation(conversationType: .single, target: "u2")
    XCTAssertEqual(conversation?.timestamp, 1_000)
    XCTAssertEqual(conversation?.unreadCount, 1)
}

func test_resetLastMessage_whenRowDoesNotExist_isNoOp() throws {
    XCTAssertNoThrow(try store.resetLastMessage(conversationType: .single, target: "nonexistent", line: 0))
}
```

- [ ] **Step 4: 实现 deleteConversation 和 resetLastMessage**

在 `Sources/IMStorage/ConversationStore.swift` 中，在 `setMuted` 方法后（第 137 行 `}` 之前）追加两个方法：

```swift
public func deleteConversation(conversationType: ConversationType, target: String, line: Int = 0) throws {
    try dbQueue.write { db in
        try db.execute(
            sql: "DELETE FROM conversation WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [conversationType.rawValue, target, line]
        )
    }
}

public func resetLastMessage(conversationType: ConversationType, target: String, line: Int = 0) throws {
    try dbQueue.write { db in
        guard var conversation = try StoredConversation
            .filter(Column("conversationType") == conversationType.rawValue)
            .filter(Column("target") == target)
            .filter(Column("line") == line)
            .fetchOne(db) else { return }
        conversation.lastMessageUid = nil
        try conversation.save(db)
    }
}
```

- [ ] **Step 5: 运行全部 ConversationStore 测试，确认通过**

```bash
swift test --filter IMStorageTests/ConversationStoreTests
```

预期输出：`Test Suite 'ConversationStoreTests' passed`（全部绿色，包括已有测试）

- [ ] **Step 6: 提交**

```bash
git add Sources/IMStorage/ConversationStore.swift Tests/IMStorageTests/ConversationStoreTests.swift
git commit -m "feat(IMStorage): add deleteConversation and resetLastMessage to ConversationStore"
```

---

## Task 2: ConversationListViewModel — 新增三个 action 方法

**Files:**
- Modify: `Sources/IMKit/ConversationListViewModel.swift`
- Test: `Tests/IMKitTests/ConversationListViewModelTests.swift`

**Interfaces:**
- Consumes（来自 Task 1）:
  - `storage.conversations.deleteConversation(conversationType:target:line:) throws`
  - `storage.conversations.resetLastMessage(conversationType:target:line:) throws`
  - `storage.conversations.setTop(_:conversationType:target:line:) throws`（已有）
  - `storage.messages.clearMessages(conversationType:target:line:) throws`（已有）
- Produces:
  - `ConversationListViewModel.setTop(_ isTop: Bool, for row: ConversationRow) throws`
  - `ConversationListViewModel.clearConversation(_ row: ConversationRow) throws`
  - `ConversationListViewModel.deleteConversation(_ row: ConversationRow) throws`

- [ ] **Step 1: 写失败测试**

在 `Tests/IMKitTests/ConversationListViewModelTests.swift` 中，在 `waitForRow` 方法前追加三个测试：

```swift
func test_setTop_true_updatesIsTopInRow() throws {
    try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
    _ = try waitForRow(target: "them")
    let row = try XCTUnwrap(viewModel.rows.first { $0.target == "them" })

    try viewModel.setTop(true, for: row)

    let expectation = expectation(description: "isTop becomes true")
    expectation.assertForOverFulfill = false
    viewModel.$rows.sink { rows in
        if rows.first(where: { $0.target == "them" })?.isTop == true { expectation.fulfill() }
    }.store(in: &cancellables)
    wait(for: [expectation], timeout: 2)
}

func test_clearConversation_emptiesPreviewText() throws {
    try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hello"), timestamp: 1_000, status: .unread, direction: .receive))
    try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)
    _ = try waitForRow(target: "them")
    let row = try XCTUnwrap(viewModel.rows.first { $0.target == "them" })

    try viewModel.clearConversation(row)

    let expectation = expectation(description: "previewText becomes empty")
    expectation.assertForOverFulfill = false
    viewModel.$rows.sink { rows in
        if rows.first(where: { $0.target == "them" })?.previewText == "" { expectation.fulfill() }
    }.store(in: &cancellables)
    wait(for: [expectation], timeout: 2)
}

func test_deleteConversation_removesRowFromList() throws {
    try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
    _ = try waitForRow(target: "them")
    let row = try XCTUnwrap(viewModel.rows.first { $0.target == "them" })

    try viewModel.deleteConversation(row)

    let expectation = expectation(description: "row disappears")
    expectation.assertForOverFulfill = false
    viewModel.$rows.sink { rows in
        if !rows.contains(where: { $0.target == "them" }) { expectation.fulfill() }
    }.store(in: &cancellables)
    wait(for: [expectation], timeout: 2)
}
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
swift test --filter IMKitTests/ConversationListViewModelTests/test_setTop
swift test --filter IMKitTests/ConversationListViewModelTests/test_clearConversation
swift test --filter IMKitTests/ConversationListViewModelTests/test_deleteConversation
```

预期：编译错误 `value of type 'ConversationListViewModel' has no member 'setTop'`

- [ ] **Step 3: 实现三个 action 方法**

在 `Sources/IMKit/ConversationListViewModel.swift` 中，在 `recalledPreviewText` 方法前（第 139 行前）追加：

```swift
public func setTop(_ isTop: Bool, for row: ConversationRow) throws {
    try storage.conversations.setTop(isTop, conversationType: row.conversationType, target: row.target, line: row.line)
}

public func clearConversation(_ row: ConversationRow) throws {
    try storage.messages.clearMessages(conversationType: row.conversationType, target: row.target, line: row.line)
    try storage.conversations.resetLastMessage(conversationType: row.conversationType, target: row.target, line: row.line)
}

public func deleteConversation(_ row: ConversationRow) throws {
    try storage.messages.clearMessages(conversationType: row.conversationType, target: row.target, line: row.line)
    try storage.conversations.deleteConversation(conversationType: row.conversationType, target: row.target, line: row.line)
}
```

- [ ] **Step 4: 运行全部 ConversationListViewModel 测试，确认通过**

```bash
swift test --filter IMKitTests/ConversationListViewModelTests
```

预期输出：`Test Suite 'ConversationListViewModelTests' passed`

- [ ] **Step 5: 提交**

```bash
git add Sources/IMKit/ConversationListViewModel.swift Tests/IMKitTests/ConversationListViewModelTests.swift
git commit -m "feat(IMKit): add setTop/clearConversation/deleteConversation actions to ConversationListViewModel"
```

---

## Task 3: ConversationListViewController — 实现长按上下文菜单

**Files:**
- Modify: `App/ConversationListViewController.swift`

**Interfaces:**
- Consumes（来自 Task 2）:
  - `viewModel.setTop(_ isTop: Bool, for row: ConversationRow) throws`
  - `viewModel.clearConversation(_ row: ConversationRow) throws`
  - `viewModel.deleteConversation(_ row: ConversationRow) throws`
- Produces: 长按会话 Cell 弹出 `UIContextMenu`，三项操作均可交互

- [ ] **Step 1: 在 UITableViewDelegate extension 中添加 contextMenu 方法**

打开 `App/ConversationListViewController.swift`，将底部的 `extension ConversationListViewController: UITableViewDelegate` 替换为：

```swift
extension ConversationListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        onConversationSelected?(row)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu(title: "", children: []) }
            return self.makeContextMenu(for: row)
        }
    }
}
```

- [ ] **Step 2: 添加辅助私有方法**

在文件末尾（最后一个 `}` 之前）新增一个私有 extension：

```swift
private extension ConversationListViewController {
    func makeContextMenu(for row: ConversationRow) -> UIMenu {
        let clearAction = UIAction(
            title: "清空会话",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmDestructive(title: "清空会话") {
                try self?.viewModel.clearConversation(row)
            }
        }

        let deleteAction = UIAction(
            title: "删除会话",
            image: UIImage(systemName: "xmark.circle"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmDestructive(title: "删除会话") {
                try self?.viewModel.deleteConversation(row)
            }
        }

        let pinTitle = row.isTop ? "取消置顶" : "置顶"
        let pinSymbol = row.isTop ? "pin.slash" : "pin"
        let pinAction = UIAction(
            title: pinTitle,
            image: UIImage(systemName: pinSymbol)
        ) { [weak self] _ in
            do {
                try self?.viewModel.setTop(!row.isTop, for: row)
            } catch {
                self?.showStorageError(error)
            }
        }

        return UIMenu(title: "", children: [clearAction, deleteAction, pinAction])
    }

    func confirmDestructive(title: String, action: @escaping () throws -> Void) {
        let alert = UIAlertController(title: title, message: "此操作不可撤销。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .destructive) { [weak self] _ in
            do {
                try action()
            } catch {
                self?.showStorageError(error)
            }
        })
        present(alert, animated: true)
    }

    func showStorageError(_ error: Error) {
        let alert = UIAlertController(title: "操作失败", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
```

- [ ] **Step 3: 编译 App target，确认无错误**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -E "error:|warning:|BUILD"
```

预期：`BUILD SUCCEEDED`，无 `error:`

- [ ] **Step 4: 运行全部单元测试，确认无回归**

```bash
swift test 2>&1 | tail -5
```

预期：`Test Suite 'All tests' passed`

- [ ] **Step 5: 提交**

```bash
git add App/ConversationListViewController.swift
git commit -m "feat(App): add long-press context menu to conversation list (pin/clear/delete)"
```
