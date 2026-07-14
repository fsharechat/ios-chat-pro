# 退群/解散群/被踢后清理本地会话 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 退出/解散群组成功后清理本地会话并连退两级导航；收到群解散、自己退群回显、自己被踢出群的通知后同样清理本地会话。

**Architecture:** 在 `IMStorage` 的 `MessageStore`/`ConversationStore` 上补齐两个 `db:` 事务重载；`IMMessaging.ReceiveMessageHandler` 在既有的批量写事务里按通知类型规则调用它们；`IMKit.GroupInfoViewModel` 的 `quitGroup`/`dismissGroup` 成功回调里做乐观本地删除；`App.GroupInfoViewController` 把成功后的单级 pop 换成连退两级。全部改动都是在已有方法/文件上做小范围扩展，不引入新文件、新协议、新回调。

**Tech Stack:** Swift, GRDB (SQLite), Combine, XCTest, SPM (`swift test`)。

## Global Constraints

- `ReceiveMessageHandler.persist(_:db:...)` 内新增的删除逻辑必须用 `db:` 重载调用，不能自己开 `dbQueue.write`——它运行在调用方已持有的批量写事务里，GRDB 串行队列不可重入，嵌套写会直接 `fatalError` 崩溃。
- `GroupInfoViewModel` 的乐观本地删除用现有的非 `db:` 版本（`storage.messages.clearMessages(...)` / `storage.conversations.deleteConversation(...)`），因为它运行在异步网络回调里，不在任何事务内。
- 不新增 `SceneDelegate` 回调；导航连退两级完全在 `GroupInfoViewController` 内部用 `self.navigationController` 完成。
- 「别人退群」（`.quitGroup` 且非自己）不清理会话，只落一条通知消息——与 Android 端 `fromSelf` 判断一致，不能扩大范围。
- 每个 Task 结束都跑一次对应模块的 `swift test --filter <Target>`，全绿再进下一个 Task。

---

### Task 1: `MessageStore.clearMessages` 的 `db:` 事务重载

**Files:**
- Modify: `Sources/IMStorage/MessageStore.swift:110-117`
- Test: `Tests/IMStorageTests/MessageStoreTests.swift`

**Interfaces:**
- Produces: `MessageStore.clearMessages(conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws` — Task 3 (`ReceiveMessageHandler`) 调用这个重载。
- 原有 `MessageStore.clearMessages(conversationType:target:line:)`（无 `db:`）签名和行为不变，Task 4 (`GroupInfoViewModel`) 继续用这个。

- [ ] **Step 1: 写失败测试**

在 `Tests/IMStorageTests/MessageStoreTests.swift` 里，紧跟在 `test_clearMessages_deletesAllMessagesForConversation()`（第 283-292 行）后面添加：

```swift
    func test_clearMessages_db_deletesAllMessagesForConversationWithinCallerManagedTransaction() throws {
        try store.insert(makeMessage(localMessageId: 1, target: "g1", text: "hello"))
        try store.insert(makeMessage(localMessageId: 2, target: "g1", text: "world"))
        try store.insert(makeMessage(localMessageId: 3, target: "u2", text: "other"))

        try database.dbQueue.write { db in
            try store.clearMessages(conversationType: .single, target: "g1", db: db)
        }

        XCTAssertTrue(try store.messages(conversationType: .single, target: "g1").isEmpty)
        XCTAssertEqual(try store.messages(conversationType: .single, target: "u2").count, 1)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMStorageTests.MessageStoreTests/test_clearMessages_db_deletesAllMessagesForConversationWithinCallerManagedTransaction`
Expected: FAIL，编译错误 `extra argument 'db' in call` — `clearMessages(conversationType:target:line:db:)` 还不存在。

- [ ] **Step 3: 实现**

把 `Sources/IMStorage/MessageStore.swift:110-117` 的

```swift
    public func clearMessages(conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM message WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [conversationType.rawValue, target, line]
            )
        }
    }
```

换成：

```swift
    public func clearMessages(conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in try self.clearMessages(conversationType: conversationType, target: target, line: line, db: db) }
    }

    /// Same as `clearMessages(...)`, run against a caller-managed transaction
    /// — see `ReceiveMessageHandler`, which deletes a group's messages in the
    /// same write transaction as persisting the notification that triggered it.
    public func clearMessages(conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM message WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [conversationType.rawValue, target, line]
        )
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMStorageTests.MessageStoreTests`
Expected: PASS，全部用例（含新用例）通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/IMStorage/MessageStore.swift Tests/IMStorageTests/MessageStoreTests.swift
git commit -m "feat(IMStorage): add db: transaction overload for MessageStore.clearMessages"
```

---

### Task 2: `ConversationStore.deleteConversation` 的 `db:` 事务重载

**Files:**
- Modify: `Sources/IMStorage/ConversationStore.swift:139-146`
- Test: `Tests/IMStorageTests/ConversationStoreTests.swift`

**Interfaces:**
- Produces: `ConversationStore.deleteConversation(conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws` — Task 3 调用。
- 原有 `ConversationStore.deleteConversation(conversationType:target:line:)`（无 `db:`）签名和行为不变，Task 4 继续用这个。

- [ ] **Step 1: 写失败测试**

在 `Tests/IMStorageTests/ConversationStoreTests.swift` 里，紧跟在 `test_deleteConversation_whenRowDoesNotExist_isNoOp()` 后面添加：

```swift
    func test_deleteConversation_db_removesRowWithinCallerManagedTransaction() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)

        try database.dbQueue.write { db in
            try store.deleteConversation(conversationType: .single, target: "u2", line: 0, db: db)
        }

        XCTAssertNil(try store.conversation(conversationType: .single, target: "u2"))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMStorageTests.ConversationStoreTests/test_deleteConversation_db_removesRowWithinCallerManagedTransaction`
Expected: FAIL，编译错误 `extra argument 'db' in call`。

- [ ] **Step 3: 实现**

把 `Sources/IMStorage/ConversationStore.swift:139-146` 的

```swift
    public func deleteConversation(conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM conversation WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [conversationType.rawValue, target, line]
            )
        }
    }
```

换成：

```swift
    public func deleteConversation(conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in try self.deleteConversation(conversationType: conversationType, target: target, line: line, db: db) }
    }

    /// Same as `deleteConversation(...)`, run against a caller-managed
    /// transaction — see `ReceiveMessageHandler`, which removes a group's
    /// conversation in the same write transaction as persisting the
    /// notification that triggered it (dismiss/self-quit/self-kicked).
    public func deleteConversation(conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM conversation WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [conversationType.rawValue, target, line]
        )
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMStorageTests.ConversationStoreTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/IMStorage/ConversationStore.swift Tests/IMStorageTests/ConversationStoreTests.swift
git commit -m "feat(IMStorage): add db: transaction overload for ConversationStore.deleteConversation"
```

---

### Task 3: `ReceiveMessageHandler` 按通知类型清理本地群会话

**Files:**
- Modify: `Sources/IMMessaging/ReceiveMessageHandler.swift:244-246` (以及紧邻位置新增一个 private helper)
- Test: `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `MessageStore.clearMessages(conversationType:target:line:db:)`、Task 2 的 `ConversationStore.deleteConversation(conversationType:target:line:db:)`。
- 不新增公开 API——纯内部行为变更，外部可观察的效果是「特定群通知消息落库后，该群会话/消息在同一批更新里一并消失」。

- [ ] **Step 1: 写失败测试**

在 `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift` 末尾（`}`之前，即第 555 行之前）添加：

```swift
    // MARK: - Group dismiss/quit/kick conversation cleanup

    private func makeGroupNotificationWireMessage(uid: Int64, type: Int32, from: String, groupId: String, memberUids: [String] = [], timestamp: Int64 = 1_000) -> Im_Message {
        var message = Im_Message()
        message.messageID = uid
        message.fromUser = from
        message.conversation.type = 1 // group
        message.conversation.target = groupId
        message.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = type
        let memberUidsJSON = memberUids.map { "\"\($0)\"" }.joined(separator: ",")
        wireContent.data = Data("""
        {"g":"\(groupId)","o":"\(from)","ms":[\(memberUidsJSON)]}
        """.utf8)
        message.content = wireContent
        message.serverTimestamp = timestamp
        return message
    }

    /// 先用一条普通群消息建立会话和历史消息,再投递通知消息,证明清理逻辑
    /// 真的删掉了已有数据,不只是"从未创建过"。
    private func seedExistingGroupConversation(groupId: String) throws {
        var textMessage = makeWireMessage(uid: 9_000, from: "them", target: groupId, text: "existing history")
        textMessage.conversation.type = 1
        textMessage.conversation.target = groupId
        handler.handle(frame: try makePullResultFrame(messages: [textMessage], head: 9_000))
        XCTAssertNotNil(try storage.conversations.conversation(conversationType: .group, target: groupId), "precondition: conversation must exist before the notification arrives")
    }

    func test_handle_dismissGroupNotification_deletesLocalConversationRegardlessOfDirection() throws {
        try seedExistingGroupConversation(groupId: "g1")
        let message = makeGroupNotificationWireMessage(uid: 1_001, type: 108, from: "owner1", groupId: "g1") // dismissGroup

        handler.handle(frame: try makePullResultFrame(messages: [message], head: 1_001))

        XCTAssertNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
        XCTAssertTrue(try storage.messages.messages(conversationType: .group, target: "g1").isEmpty)
    }

    func test_handle_quitGroupNotificationFromSelf_deletesLocalConversation() throws {
        try seedExistingGroupConversation(groupId: "g1")
        let message = makeGroupNotificationWireMessage(uid: 1_002, type: 107, from: "me", groupId: "g1") // quitGroup, fromUser == myUserId()

        handler.handle(frame: try makePullResultFrame(messages: [message], head: 1_002))

        XCTAssertNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
    }

    func test_handle_quitGroupNotificationFromOther_doesNotDeleteLocalConversation() throws {
        try seedExistingGroupConversation(groupId: "g1")
        let message = makeGroupNotificationWireMessage(uid: 1_003, type: 107, from: "other-member", groupId: "g1") // someone else quit

        handler.handle(frame: try makePullResultFrame(messages: [message], head: 1_003))

        XCTAssertNotNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
    }

    func test_handle_kickoffGroupMemberIncludingSelf_deletesLocalConversation() throws {
        try seedExistingGroupConversation(groupId: "g1")
        let message = makeGroupNotificationWireMessage(uid: 1_004, type: 106, from: "owner1", groupId: "g1", memberUids: ["me"]) // I was kicked

        handler.handle(frame: try makePullResultFrame(messages: [message], head: 1_004))

        XCTAssertNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
    }

    func test_handle_kickoffGroupMemberExcludingSelf_doesNotDeleteLocalConversation() throws {
        try seedExistingGroupConversation(groupId: "g1")
        let message = makeGroupNotificationWireMessage(uid: 1_005, type: 106, from: "owner1", groupId: "g1", memberUids: ["someone-else"])

        handler.handle(frame: try makePullResultFrame(messages: [message], head: 1_005))

        XCTAssertNotNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMMessagingTests.ReceiveMessageHandlerTests/test_handle_dismissGroupNotification_deletesLocalConversationRegardlessOfDirection`
Expected: FAIL——`XCTAssertNil` 断言失败（会话依然存在），因为清理逻辑还没实现。其余 4 个新用例同理（跑 `swift test --filter IMMessagingTests.ReceiveMessageHandlerTests` 会看到 `test_handle_kickoffGroupMemberExcludingSelf_doesNotDeleteLocalConversation` 和 `test_handle_quitGroupNotificationFromOther_doesNotDeleteLocalConversation` 这两个反例暂时是通过的——这是巧合,不代表已实现,后面加了实现后仍要保持通过）。

- [ ] **Step 3: 实现**

在 `Sources/IMMessaging/ReceiveMessageHandler.swift` 里，`persist` 方法内把第 244-246 行的

```swift
            if case .groupNotification = content {
                groupNotificationTargets.insert(target)
            }
```

换成：

```swift
            if case .groupNotification(let notificationType, _, let memberUids, _) = content {
                groupNotificationTargets.insert(target)
                if shouldDeleteLocalGroupConversation(type: notificationType, direction: direction, memberUids: memberUids) {
                    try? storage.messages.clearMessages(conversationType: conversationType, target: target, line: line, db: db)
                    try? storage.conversations.deleteConversation(conversationType: conversationType, target: target, line: line, db: db)
                }
            }
```

然后在同一个文件里，紧跟在 `persist(_:db:...)` 方法结束的右花括号之后（即 253 行 `}` 之后，`advanceSyncHead` 方法之前）新增私有方法：

```swift
    /// 群通知消息落库后是否要连带清掉本地会话——规则对齐 Android
    /// `ConversationListViewModel.onReceiveMessage` 里对 `DismissGroupNotificationContent`
    /// 和 `fromSelf` 的 `QuitGroupNotificationContent` 的处理（`fromSelf` 即
    /// `消息发送者 == 当前用户`，对应这里的 `direction == .send`）。
    /// `kickoffGroupMember` 命中自己是 Android 没做的行为，是本次专门为
    /// iOS 加的——群解散/自己退群/自己被踢，会话都失去意义,不该继续留在列表里。
    private func shouldDeleteLocalGroupConversation(type: MessageContentType, direction: MessageDirection, memberUids: [String]) -> Bool {
        switch type {
        case .dismissGroup:
            return true
        case .quitGroup:
            return direction == .send
        case .kickoffGroupMember:
            return memberUids.contains(myUserId())
        default:
            return false
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMMessagingTests.ReceiveMessageHandlerTests`
Expected: PASS，全部用例（含 5 个新用例和已有用例）通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/IMMessaging/ReceiveMessageHandler.swift Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift
git commit -m "feat(IMMessaging): delete local group conversation on dismiss/self-quit/self-kicked notifications"
```

---

### Task 4: `GroupInfoViewModel` 退群/解散群成功后本地立即清理

**Files:**
- Modify: `Sources/IMKit/GroupInfoViewModel.swift:156-162` (以及新增一个 private helper)
- Modify: `Tests/IMKitTests/CreateGroupViewModelTests.swift:159-178` （`FakeGroupActing` 需要真正调用 completion）
- Test: `Tests/IMKitTests/GroupInfoViewModelTests.swift`

**Interfaces:**
- Consumes: `storage.messages.clearMessages(conversationType:target:line:)`、`storage.conversations.deleteConversation(conversationType:target:line:)`（已存在的非 `db:` 版本，`IMKit` 不在任何事务里调用它们）。
- `GroupInfoViewModel.quitGroup(completion:)` / `dismissGroup(completion:)` 的公开签名不变，只是成功分支多了一步本地删除。

- [ ] **Step 1: 让 `FakeGroupActing` 支持配置 quit/dismiss 的结果**

把 `Tests/IMKitTests/CreateGroupViewModelTests.swift:159-178` 的

```swift
final class FakeGroupActing: GroupActing {
    var resultToReturn: Result<String, Error> = .success("g1")
    var addMembersResultToReturn: Result<Void, Error> = .success(())
    private(set) var lastName: String?
    private(set) var lastMemberIds: [String]?

    func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void) {
        lastName = name
        lastMemberIds = memberIds
        completion(resultToReturn)
    }
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        lastMemberIds = memberIds
        completion(addMembersResultToReturn)
    }
    func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
}
```

换成：

```swift
final class FakeGroupActing: GroupActing {
    var resultToReturn: Result<String, Error> = .success("g1")
    var addMembersResultToReturn: Result<Void, Error> = .success(())
    var quitGroupResult: Result<Void, Error> = .success(())
    var dismissGroupResult: Result<Void, Error> = .success(())
    private(set) var lastName: String?
    private(set) var lastMemberIds: [String]?

    func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void) {
        lastName = name
        lastMemberIds = memberIds
        completion(resultToReturn)
    }
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        lastMemberIds = memberIds
        completion(addMembersResultToReturn)
    }
    func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(quitGroupResult) }
    func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(dismissGroupResult) }
}
```

这一步是纯测试基础设施改动，不影响任何现有用例（之前没有测试依赖 quit/dismiss 不调用 completion）。

- [ ] **Step 2: 写失败测试**

在 `Tests/IMKitTests/GroupInfoViewModelTests.swift` 末尾（第 166 行 `}` 之前）添加：

```swift
    // --- Quit/dismiss cleanup

    func test_quitGroup_onSuccess_deletesLocalConversationAndMessages() throws {
        try seedGroup(type: .normal, owner: "owner1")
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "owner1",
            content: .text("hi"), timestamp: 1_000, status: .sent, direction: .receive
        ))
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)
        let viewModel = makeViewModel(currentUserId: "member1")

        var succeeded = false
        viewModel.quitGroup { if case .success = $0 { succeeded = true } }

        XCTAssertTrue(succeeded)
        XCTAssertNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
        XCTAssertTrue(try storage.messages.messages(conversationType: .group, target: "g1").isEmpty)
    }

    func test_dismissGroup_onSuccess_deletesLocalConversationAndMessages() throws {
        try seedGroup(type: .normal, owner: "me")
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
        let viewModel = makeViewModel(currentUserId: "me")

        var succeeded = false
        viewModel.dismissGroup { if case .success = $0 { succeeded = true } }

        XCTAssertTrue(succeeded)
        XCTAssertNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
    }

    func test_quitGroup_onFailure_doesNotDeleteLocalConversation() throws {
        try seedGroup(type: .normal, owner: "owner1")
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
        fakeActing.quitGroupResult = .failure(NSError(domain: "test", code: 1))
        let viewModel = makeViewModel(currentUserId: "member1")

        var failed = false
        viewModel.quitGroup { if case .failure = $0 { failed = true } }

        XCTAssertTrue(failed)
        XCTAssertNotNil(try storage.conversations.conversation(conversationType: .group, target: "g1"))
    }
```

- [ ] **Step 3: 跑测试确认失败**

Run: `swift test --filter IMKitTests.GroupInfoViewModelTests/test_quitGroup_onSuccess_deletesLocalConversationAndMessages`
Expected: FAIL——`XCTAssertNil` 失败，会话仍存在，因为 `quitGroup` 还没有清理逻辑。

- [ ] **Step 4: 实现**

把 `Sources/IMKit/GroupInfoViewModel.swift:156-162` 的

```swift
    public func quitGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.quitGroup(groupId: groupId, completion: completion)
    }

    public func dismissGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.dismissGroup(groupId: groupId, completion: completion)
    }
```

换成：

```swift
    public func quitGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.quitGroup(groupId: groupId) { [weak self] result in
            if case .success = result { self?.deleteLocalConversation() }
            completion(result)
        }
    }

    public func dismissGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.dismissGroup(groupId: groupId) { [weak self] result in
            if case .success = result { self?.deleteLocalConversation() }
            completion(result)
        }
    }

    /// 乐观本地清理：不等服务器把 `.dismissGroup`/`.quitGroup` 通知回显回来
    /// （那条路径见 `ReceiveMessageHandler.shouldDeleteLocalGroupConversation`），
    /// 退出/解散一确认成功就立即删掉本地会话，避免会话列表出现短暂的过期数据。
    /// 与回显路径重复调用是安全的——对已删除的会话/消息是空操作。
    private func deleteLocalConversation() {
        try? storage.messages.clearMessages(conversationType: .group, target: groupId)
        try? storage.conversations.deleteConversation(conversationType: .group, target: groupId)
    }
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter IMKitTests.GroupInfoViewModelTests`
Expected: PASS，全部用例（含 3 个新用例）通过。

- [ ] **Step 6: 提交**

```bash
git add Sources/IMKit/GroupInfoViewModel.swift Tests/IMKitTests/GroupInfoViewModelTests.swift Tests/IMKitTests/CreateGroupViewModelTests.swift
git commit -m "feat(IMKit): delete local group conversation on quitGroup/dismissGroup success"
```

---

### Task 5: `GroupInfoViewController` 退出/解散成功后连退两级导航

**Files:**
- Modify: `App/GroupInfoViewController.swift:286-316`

**Interfaces:**
- Consumes: Task 4 之后的 `GroupInfoViewModel.quitGroup(completion:)` / `dismissGroup(completion:)`（签名不变，行为多了本地清理，本 Task 不需要关心）。
- 无新公开接口——纯 `UIViewController` 内部导航行为变更。

这个 Task 是纯 UIKit 导航逻辑，仓库没有 UI 测试基础设施（`CLAUDE.md`/既有 spec 的惯例都是装机手测），跳过 TDD 的写测试步骤，直接实现 + 装机验证。

- [ ] **Step 1: 实现**

把 `App/GroupInfoViewController.swift:286-316` 的

```swift
    @objc private func bottomButtonTapped() {
        if presentsAsPreview {
            handlePreviewBottomTapped()
            return
        }
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
```

换成：

```swift
    @objc private func bottomButtonTapped() {
        if presentsAsPreview {
            handlePreviewBottomTapped()
            return
        }
        if viewModel.canDismiss {
            confirmAction(title: "解散群组", message: "解散后群组将不可恢复，请谨慎操作。") { [weak self] in
                self?.viewModel.dismissGroup { result in
                    DispatchQueue.main.async {
                        if case .failure = result {
                            self?.showAlert(title: "解散失败", message: "请稍后重试")
                        } else {
                            self?.popPastConversation()
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
                            self?.popPastConversation()
                        }
                    }
                }
            }
        }
    }

    /// 退出/解散群组成功后，聊天页也失去了意义——连退两级（自己 + 聊天页），
    /// 而不是只退一级停在已经没有内容的聊天页上。不依赖具体上一级是
    /// `ConversationViewController` 还是别的类型（群列表 → 聊天页 → 群详情，
    /// 或扫码预览等路径），只按导航栈里自己的位置往前找两级；找不到（自己
    /// 不在导航栈里，或前面不够两级)时退化为 popViewController。
    private func popPastConversation() {
        guard let nav = navigationController,
              let selfIndex = nav.viewControllers.firstIndex(of: self),
              selfIndex >= 2 else {
            navigationController?.popViewController(animated: true)
            return
        }
        nav.popToViewController(nav.viewControllers[selfIndex - 2], animated: true)
    }
```

- [ ] **Step 2: 编译确认无误**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add App/GroupInfoViewController.swift
git commit -m "feat(App): pop past the chat screen too after successfully quitting/dismissing a group"
```

- [ ] **Step 4: 装机手测（用户验证，不要在模拟器里代为验证）**

按 spec 的验证清单：
1. 群主解散群组 → 群详情页和聊天页一起消失，回到列表，会话消失。
2. 普通成员退出群组 → 同上。
3. 另一台设备上，群主解散群组后，本机（普通成员）打开 App → 会话自动消失。
4. 另一台设备上，群主把自己移出群组 → 本机打开 App → 会话自动消失。
5. 另一台设备上，别的成员退群/被踢（不是自己）→ 本机会话保留，仅出现一条通知消息。

---

## Final Verification

- [ ] `swift test`（全量）无新增失败——已知基线失败（`GroupInfoViewModelTests.test_members_excludesRemovedAndMarksOwner`、`MediaUploadServiceTests` 两条、`MessageContentCodecTests` 两条）与本次改动无关，照旧存在即可，不要试图修复。
- [ ] 五个 Task 的 commit 都已创建。
- [ ] 装机验证清单（Task 5 Step 4）全部过一遍，用户确认后再考虑合并。
