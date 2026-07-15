# 消息提醒(震动+响铃 / 仅震动)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 收到新消息时，按"是否命中当前打开的会话 / 是否免打扰 / 是否群系统通知 / 是否撤回"这几个信号，在前台触发"震动+响铃"或"仅震动"或"静默"，行为参考微信。

**Architecture:** `IMStorage.ConversationStore` 的 db 内读写方法顺带把 `isMuted` 返回给调用方；`IMMessaging.ReceiveMessageHandler.persist` 在现有的未读计数判定旁收集提醒候选，写事务结束后统一触发新回调 `onIncomingMessageAlert`；`MessagingService` 转发该回调；`AppCore.AppEnvironment` 提供跨重连生命周期存活的中继属性(同 `onConnectionStatusChange` 的模式)；纯限流判定逻辑放进新增的 `AppCore.MessageAlertPolicy`(可单测);真正"怎么响/怎么震"放进新增的 `App.MessageAlertPlayer`(镜像现有 `CallRingtonePlayer`),由 `SceneDelegate` 持有并在场景连接时接上 `AppEnvironment` 的中继。

**Tech Stack:** Swift 5.8, GRDB(SQLite), Combine, AudioToolbox(`AudioServicesPlaySystemSound`)，SPM 单元测试(`swift test`),Xcode App target 无 SPM 测试覆盖(与现有 `CallRingtonePlayer` 一致，装机手测)。

## Global Constraints

- 仅覆盖前台(TCP 连接存活期间)场景，不涉及 APNs/远程推送/锁屏通知。
- 决策表(顺序：先看 content 类型排除规则，再看 isMuted，再看 isActiveConversation)：
  - `.recalled` → 不触发，完全排除。
  - `.groupNotification` 且 `isMuted == true` → 静默；`isMuted == false` → 仅震动(不区分是否命中当前会话)。
  - 普通消息(含 `.callRecord`)且 `isMuted == true` → 静默；`isMuted == false && isActiveConversation == true` → 仅震动；`isMuted == false && isActiveConversation == false` → 震动+响铃。
- `isActiveConversation` 必须是"消息命中的会话是否等于当前打开的那个会话"的精确匹配（沿用 `ReceiveMessageHandler.activeConversation`），不是"是否在任意聊天页"或"是否在消息 tab"。
- `direction == .send`(自己其他端回显的消息)与 `suppressUnreadIncrement == true` 期间(首次登录/长时间离线补拉)一律不触发提醒。
- 限流：全局 2 秒 leading-edge 冷却窗口——窗口内第一次触发决定档位，窗口内后续候选一律丢弃(不升级、不补放)。
- 提示音使用系统音效 id `1007`，遵循静音拨片；纯震动使用 `kSystemSoundID_Vibrate`(id `4095`)，不受拨片影响。不使用 `AVAudioPlayer`，不强制切换 `AVAudioSession` 分类。
- 新增/修改的 Swift 源文件全部落在现有模块边界内(`IMStorage`/`IMMessaging`/`AppCore`/`App`)，不引入新 SPM 模块。
- 改完 `App/` 下任何新文件后必须跑一次 `bash Scripts/generate-xcodeproj.sh` 让 xcodegen 重新识别（`project.yml` 里 `App.sources` 是整个目录 glob，新文件会被自动纳入，但仍需重跑脚本刷新 `.xcodeproj`）。

---

## 文件结构

- **Modify** `Sources/IMStorage/ConversationStore.swift` — `recordIncomingMessage(..., db:)` 返回 `Bool`(更新后的 `isMuted`)。
- **Modify** `Sources/IMMessaging/ReceiveMessageHandler.swift` — 新增 `onIncomingMessageAlert` 闭包属性；`persist`/`handle(frame:)` 收集并派发提醒候选。
- **Modify** `Sources/IMMessaging/MessagingService.swift` — 转发 `onIncomingMessageAlert`。
- **Modify** `Sources/AppCore/AppEnvironment.swift` — 新增跨重连存活的 `onIncomingMessageAlert` 中继属性，在 `connectIfPossible()` 里接到新建的 `MessagingService` 上。
- **Create** `Sources/AppCore/MessageAlertPolicy.swift` — 纯逻辑：接收 `(isMuted, isActiveConversation, isGroupNotification)` 三个信号 + 当前时间，返回该播放的提醒档位(`.silent`/`.vibrate`/`.vibrateAndSound`)，内部维护 2 秒冷却窗口。可单测，不依赖 UIKit/AudioToolbox。
- **Create** `App/MessageAlertPlayer.swift` — 镜像 `CallRingtonePlayer` 的写法：持有一个 `MessageAlertPolicy`，接收 `AppEnvironment.onIncomingMessageAlert` 的回调，按返回的档位调用 `AudioServicesPlaySystemSound`。
- **Modify** `App/SceneDelegate.swift` — 持有 `messageAlertPlayer`，在 `scene(_:willConnectTo:...)` 里把 `environment.onIncomingMessageAlert` 接到它上面。
- **Test** `Tests/IMStorageTests/ConversationStoreTests.swift` — 新增 db 内重载返回值断言。
- **Test** `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift` — 新增决策表覆盖用例。
- **Test** `Tests/IMMessagingTests/MessagingServiceTests.swift` — 新增转发用例。
- **Test** `Tests/AppCoreTests/AppEnvironmentTests.swift` — 新增中继用例。
- **Test** `Tests/AppCoreTests/MessageAlertPolicyTests.swift`(新建) — 限流+分档单测。

---

### Task 1: `ConversationStore` 的 db 内重载返回 `isMuted`

**Files:**
- Modify: `Sources/IMStorage/ConversationStore.swift:62-88`
- Test: `Tests/IMStorageTests/ConversationStoreTests.swift`

**Interfaces:**
- Consumes: 现有 `StoredConversation.isMuted: Bool`(`Sources/IMStorage/StoredConversation.swift:14`)。
- Produces: `@discardableResult public func recordIncomingMessage(conversationType:target:line:messageUid:timestamp:incrementUnread:incrementMention:db:) throws -> Bool` — 返回值是这次 upsert 后该会话的 `isMuted`。后续任务(Task 2)读取这个返回值。

- [ ] **Step 1: 写失败测试**

在 `Tests/IMStorageTests/ConversationStoreTests.swift` 末尾(第 165 行 `}` 前)新增：

```swift
    func test_recordIncomingMessage_dbOverload_returnsCurrentIsMutedFlag() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)

        let notMuted = try database.dbQueue.write { db in
            try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 2, timestamp: 2_000, incrementUnread: false, db: db)
        }
        XCTAssertFalse(notMuted)

        try store.setMuted(true, conversationType: .single, target: "u2")

        let muted = try database.dbQueue.write { db in
            try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 3, timestamp: 3_000, incrementUnread: false, db: db)
        }
        XCTAssertTrue(muted)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMStorageTests/ConversationStoreTests/test_recordIncomingMessage_dbOverload_returnsCurrentIsMutedFlag`
Expected: FAIL —（`db:` 重载当前返回 `Void`，`try database.dbQueue.write { db in try store.recordIncomingMessage(..., db: db) }` 无法赋值给 `Bool`，编译错误 "cannot convert value of type '()' to specified type 'Bool'"）

- [ ] **Step 3: 实现**

把 `Sources/IMStorage/ConversationStore.swift:62-88` 的方法改为：

```swift
    /// Same as `recordIncomingMessage(...)`, run against a caller-managed
    /// transaction — see `ReceiveMessageHandler`, the first caller batching
    /// many of these into one transaction. Returns the conversation's
    /// `isMuted` flag *after* the upsert (mute status itself is never
    /// changed here) — `ReceiveMessageHandler` uses it to decide whether a
    /// newly persisted message should trigger a local vibrate/sound alert,
    /// at no extra query cost since this method already `fetchOne`s the row.
    @discardableResult
    public func recordIncomingMessage(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        messageUid: Int64,
        timestamp: Int64,
        incrementUnread: Bool,
        incrementMention: Bool = false,
        db: Database
    ) throws -> Bool {
        let existing = try StoredConversation
            .filter(Column("conversationType") == conversationType.rawValue)
            .filter(Column("target") == target)
            .filter(Column("line") == line)
            .fetchOne(db)

        var conversation = existing ?? StoredConversation(conversationType: conversationType, target: target, line: line)
        conversation.lastMessageUid = messageUid
        conversation.timestamp = timestamp
        if incrementUnread {
            conversation.unreadCount += 1
        }
        if incrementMention {
            conversation.unreadMentionCount += 1
        }
        try conversation.save(db)
        return conversation.isMuted
    }
```

（只改这一个重载；`Sources/IMStorage/ConversationStore.swift:41-57` 的公开 `dbQueue.write` 版本不需要改——当前没有调用方需要它的返回值。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMStorageTests/ConversationStoreTests/test_recordIncomingMessage_dbOverload_returnsCurrentIsMutedFlag`
Expected: PASS

- [ ] **Step 5: 跑整个 IMStorageTests 确认没有回归**

Run: `swift test --filter IMStorageTests`
Expected: 全部 PASS（原有调用 `recordIncomingMessage(..., db:)` 的唯一生产代码调用方在 `ReceiveMessageHandler.swift`，Task 2 会同步改它；改之前它仍是 `try storage.conversations.recordIncomingMessage(...)` 语句形式，`@discardableResult` 保证这行不会因忽略返回值报警告/报错)

- [ ] **Step 6: 提交**

```bash
git add Sources/IMStorage/ConversationStore.swift Tests/IMStorageTests/ConversationStoreTests.swift
git commit -m "feat(IMStorage): recordIncomingMessage(db:) returns isMuted for alert gating"
```

---

### Task 2: `ReceiveMessageHandler` 新增 `onIncomingMessageAlert` 并按决策表派发

**Files:**
- Modify: `Sources/IMMessaging/ReceiveMessageHandler.swift`
- Test: `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift`

**Interfaces:**
- Consumes: Task 1 产出的 `ConversationStore.recordIncomingMessage(..., db:) -> Bool`。
- Produces: `public var onIncomingMessageAlert: ((_ isMuted: Bool, _ isActiveConversation: Bool, _ isGroupNotification: Bool) -> Void)?` — Task 3 (`MessagingService`)转发这个闭包，签名必须完全一致。

- [ ] **Step 1: 写失败测试(先加最基础的一条：普通消息全部信号为 false)**

在 `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift` 里，`test_handle_newReceivedMessage_persistsAndIncrementsConversationUnread`(第 48-57 行)之后插入：

```swift
    func test_handle_newReceivedMessage_firesOnIncomingMessageAlertWithAllSignalsFalse() throws {
        var captured: (isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool)?
        handler.onIncomingMessageAlert = { isMuted, isActiveConversation, isGroupNotification in
            captured = (isMuted, isActiveConversation, isGroupNotification)
        }
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 950, from: "them", target: "them")], head: 950)

        handler.handle(frame: frame)

        XCTAssertEqual(captured?.isMuted, false)
        XCTAssertEqual(captured?.isActiveConversation, false)
        XCTAssertEqual(captured?.isGroupNotification, false)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMMessagingTests/ReceiveMessageHandlerTests/test_handle_newReceivedMessage_firesOnIncomingMessageAlertWithAllSignalsFalse`
Expected: FAIL（编译错误 "value of type 'ReceiveMessageHandler' has no member 'onIncomingMessageAlert'"）

- [ ] **Step 3: 实现——新增属性、收集候选、事务后派发**

在 `Sources/IMMessaging/ReceiveMessageHandler.swift` 里，紧跟 `onCallSignal`(第 58 行)之后、`suppressUnreadIncrement`(第 60-63 行)之前，插入新属性：

```swift
    /// Fired after persisting any *received*, non-suppressed message that
    /// should produce a local vibrate/sound alert. Never fired for
    /// `.recalled` content (a recall is a system event, not a new message),
    /// own echoed-back sends, or messages absorbed into an initial-sync/
    /// catch-up pull (`suppressUnreadIncrement == true`). `isMuted`/
    /// `isActiveConversation` are the exact same signals `recordIncomingMessage`
    /// uses to decide the unread badge; `isGroupNotification` tells the
    /// consumer (`App.MessageAlertPlayer`) to cap the alert at vibrate-only
    /// even when the other two signals would otherwise call for a full
    /// vibrate+sound alert.
    public var onIncomingMessageAlert: ((_ isMuted: Bool, _ isActiveConversation: Bool, _ isGroupNotification: Bool) -> Void)?
```

在 `handle(frame:)`(第 79-124 行)里，`var callEvents: [CallEvent] = []`(第 94 行)后面加一行：

```swift
        var alertCandidates: [(isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool)] = []
```

把第 98 行的调用

```swift
                persist(wireMessage, db: db, suppressUnread: shouldSuppressUnread, groupNotificationTargets: &groupNotificationTargets, callEvents: &callEvents)
```

改成：

```swift
                persist(wireMessage, db: db, suppressUnread: shouldSuppressUnread, groupNotificationTargets: &groupNotificationTargets, callEvents: &callEvents, alertCandidates: &alertCandidates)
```

在第 111-113 行的 `for target in groupNotificationTargets { onGroupNotificationMessage?(target) }` 循环之后（仍在写事务外，和其它两个事务后派发循环挨着）加：

```swift
        for candidate in alertCandidates {
            onIncomingMessageAlert?(candidate.isMuted, candidate.isActiveConversation, candidate.isGroupNotification)
        }
```

把 `persist` 的签名(第 139 行)：

```swift
    private func persist(_ wireMessage: Im_Message, db: Database, suppressUnread: Bool, groupNotificationTargets: inout Set<String>, callEvents: inout [CallEvent]) {
```

改成：

```swift
    private func persist(_ wireMessage: Im_Message, db: Database, suppressUnread: Bool, groupNotificationTargets: inout Set<String>, callEvents: inout [CallEvent], alertCandidates: inout [(isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool)]) {
```

在 `persist` 内部，把第 234-243 行：

```swift
            let isActiveConversation = activeConversation.map {
                $0.conversationType == conversationType && $0.target == target && $0.line == line
            } ?? false
            try storage.conversations.recordIncomingMessage(
                conversationType: conversationType,
                target: target,
                line: line,
                messageUid: wireMessage.messageID,
                timestamp: wireMessage.serverTimestamp,
                incrementUnread: direction == .receive && !suppressUnread && !isActiveConversation,
                incrementMention: isMentioned && !suppressUnread && !isActiveConversation,
                db: db
            )
```

改成：

```swift
            let isActiveConversation = activeConversation.map {
                $0.conversationType == conversationType && $0.target == target && $0.line == line
            } ?? false
            let isMuted = try storage.conversations.recordIncomingMessage(
                conversationType: conversationType,
                target: target,
                line: line,
                messageUid: wireMessage.messageID,
                timestamp: wireMessage.serverTimestamp,
                incrementUnread: direction == .receive && !suppressUnread && !isActiveConversation,
                incrementMention: isMentioned && !suppressUnread && !isActiveConversation,
                db: db
            )
            // 撤回是对已有消息的修正、不是新消息，不触发提醒；其余类型
            // （含 `.groupNotification`、`.callRecord`）按 onIncomingMessageAlert
            // 的决策表交给消费方分档 —— 这里只负责收集信号。
            if direction == .receive, !suppressUnread, !isRecalledContent(content) {
                let isGroupNotification: Bool
                if case .groupNotification = content {
                    isGroupNotification = true
                } else {
                    isGroupNotification = false
                }
                alertCandidates.append((isMuted: isMuted, isActiveConversation: isActiveConversation, isGroupNotification: isGroupNotification))
            }
```

并在 `shouldDeleteLocalGroupConversation` 方法(第 265-276 行)之前加一个小helper：

```swift
    private func isRecalledContent(_ content: MessageContent) -> Bool {
        if case .recalled = content { return true }
        return false
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMMessagingTests/ReceiveMessageHandlerTests/test_handle_newReceivedMessage_firesOnIncomingMessageAlertWithAllSignalsFalse`
Expected: PASS

- [ ] **Step 5: 补齐决策表其余分支的测试(一次性写完，逐个跑绿)**

在同一个测试文件里继续追加：

```swift
    func test_handle_messageForActiveConversation_firesOnIncomingMessageAlertWithIsActiveConversationTrue() throws {
        handler.activeConversation = (conversationType: .single, target: "them", line: 0)
        var captured: (isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool)?
        handler.onIncomingMessageAlert = { isMuted, isActiveConversation, isGroupNotification in
            captured = (isMuted, isActiveConversation, isGroupNotification)
        }
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 951, from: "them", target: "them")], head: 951)

        handler.handle(frame: frame)

        XCTAssertEqual(captured?.isActiveConversation, true)
        XCTAssertEqual(captured?.isMuted, false)
    }

    func test_handle_messageForOtherConversationWhileOneIsActive_firesOnIncomingMessageAlertWithIsActiveConversationFalse() throws {
        handler.activeConversation = (conversationType: .single, target: "them", line: 0)
        var captured: (isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool)?
        handler.onIncomingMessageAlert = { isMuted, isActiveConversation, isGroupNotification in
            captured = (isMuted, isActiveConversation, isGroupNotification)
        }
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 952, from: "other", target: "other")], head: 952)

        handler.handle(frame: frame)

        XCTAssertEqual(captured?.isActiveConversation, false)
    }

    func test_handle_messageForMutedConversation_firesOnIncomingMessageAlertWithIsMutedTrue() throws {
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 1, timestamp: 500, incrementUnread: false)
        try storage.conversations.setMuted(true, conversationType: .single, target: "them")
        var captured: (isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool)?
        handler.onIncomingMessageAlert = { isMuted, isActiveConversation, isGroupNotification in
            captured = (isMuted, isActiveConversation, isGroupNotification)
        }
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 953, from: "them", target: "them")], head: 953)

        handler.handle(frame: frame)

        XCTAssertEqual(captured?.isMuted, true)
    }

    func test_handle_duringSuppressedInitialSync_doesNotFireOnIncomingMessageAlert() throws {
        handler.suppressUnreadIncrement = true
        var fired = false
        handler.onIncomingMessageAlert = { _, _, _ in fired = true }
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 954, from: "them", target: "them")], head: 954)

        handler.handle(frame: frame)

        XCTAssertFalse(fired)
    }

    func test_handle_ownSentMessageInPull_doesNotFireOnIncomingMessageAlert() throws {
        var fired = false
        handler.onIncomingMessageAlert = { _, _, _ in fired = true }
        let frame = try makePullResultFrame(messages: [makeWireMessage(uid: 955, from: "me", target: "them")], head: 955)

        handler.handle(frame: frame)

        XCTAssertFalse(fired)
    }

    func test_handle_groupNotificationMessage_firesOnIncomingMessageAlertAsGroupNotification() throws {
        var captured: (isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool)?
        handler.onIncomingMessageAlert = { isMuted, isActiveConversation, isGroupNotification in
            captured = (isMuted, isActiveConversation, isGroupNotification)
        }
        let message = makeGroupNotificationWireMessage(uid: 956, type: 105, from: "them", groupId: "g1", memberUids: ["me"])

        handler.handle(frame: try makePullResultFrame(messages: [message], head: 956))

        XCTAssertEqual(captured?.isGroupNotification, true)
        XCTAssertEqual(captured?.isMuted, false)
    }

    func test_handle_recalledMessageInPull_doesNotFireOnIncomingMessageAlert() throws {
        var fired = false
        handler.onIncomingMessageAlert = { _, _, _ in fired = true }

        var message = Im_Message()
        message.messageID = 957
        message.fromUser = "them"
        message.conversation.type = 0
        message.conversation.target = "them"
        message.conversation.line = 0
        var wireContent = Im_MessageContent()
        wireContent.type = 80 // recalled
        wireContent.content = "them"
        message.content = wireContent
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 957)

        handler.handle(frame: frame)

        XCTAssertFalse(fired)
    }

    func test_handle_receivedCallStart_stillFiresOnIncomingMessageAlertLikeANormalMessage() throws {
        var fired = false
        handler.onIncomingMessageAlert = { _, _, _ in fired = true }

        var message = Im_Message()
        message.messageID = 958
        message.fromUser = "them"
        message.conversation.type = 0
        message.conversation.target = "them"
        message.conversation.line = 0
        message.content = MessageContentCodec.encode(.callRecord(callId: "call-alert-1", targetId: "me", audioOnly: false, status: 0, connectTime: 0, endTime: 0))
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 958)

        handler.handle(frame: frame)

        XCTAssertTrue(fired)
    }
```

- [ ] **Step 6: 跑整个测试类确认全部通过**

Run: `swift test --filter IMMessagingTests/ReceiveMessageHandlerTests`
Expected: 全部 PASS（包含此前已有的所有用例——本任务不改变未读计数行为，只是在旁边新增一路独立的回调）

- [ ] **Step 7: 提交**

```bash
git add Sources/IMMessaging/ReceiveMessageHandler.swift Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift
git commit -m "feat(IMMessaging): emit onIncomingMessageAlert per the vibrate/ring decision table"
```

---

### Task 3: `MessagingService` 转发 `onIncomingMessageAlert`

**Files:**
- Modify: `Sources/IMMessaging/MessagingService.swift:52-58`
- Test: `Tests/IMMessagingTests/MessagingServiceTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `ReceiveMessageHandler.onIncomingMessageAlert`。
- Produces: `public var onIncomingMessageAlert: ((_ isMuted: Bool, _ isActiveConversation: Bool, _ isGroupNotification: Bool) -> Void)?` on `MessagingService`（签名与 Task 2 一致）。Task 4 (`AppEnvironment`)会赋值/读取这个属性。

- [ ] **Step 1: 写失败测试**

在 `Tests/IMMessagingTests/MessagingServiceTests.swift` 里 `test_onGroupNotificationMessage_forwardsToTheInternalReceiveMessageHandler`(第 250-278 行)之后插入：

```swift
    func test_onIncomingMessageAlert_forwardsToTheInternalReceiveMessageHandler() throws {
        var captured: (isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool)?
        service.onIncomingMessageAlert = { isMuted, isActiveConversation, isGroupNotification in
            captured = (isMuted, isActiveConversation, isGroupNotification)
        }

        var wireMessage = Im_Message()
        wireMessage.messageID = 960
        wireMessage.fromUser = "them"
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = "them"
        wireMessage.conversation.line = 0
        wireMessage.content.type = 1
        wireMessage.content.searchableContent = "hi"
        wireMessage.serverTimestamp = 1_000

        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = 960
        result.head = 960
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(captured?.isMuted, false)
        XCTAssertEqual(captured?.isActiveConversation, false)
        XCTAssertEqual(captured?.isGroupNotification, false)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IMMessagingTests/MessagingServiceTests/test_onIncomingMessageAlert_forwardsToTheInternalReceiveMessageHandler`
Expected: FAIL（"value of type 'MessagingService' has no member 'onIncomingMessageAlert'"）

- [ ] **Step 3: 实现**

在 `Sources/IMMessaging/MessagingService.swift:52-58`(`onCallSignal` 转发属性)之后插入：

```swift
    /// Forwards to the internal `ReceiveMessageHandler`'s closure of the
    /// same name — see that type's doc comment. `AppEnvironment` relays this
    /// to `App.MessageAlertPlayer` so it survives `MessagingService` being
    /// torn down/recreated across logout/re-login.
    public var onIncomingMessageAlert: ((_ isMuted: Bool, _ isActiveConversation: Bool, _ isGroupNotification: Bool) -> Void)? {
        get { receiveMessageHandler.onIncomingMessageAlert }
        set { receiveMessageHandler.onIncomingMessageAlert = newValue }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IMMessagingTests/MessagingServiceTests`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/IMMessaging/MessagingService.swift Tests/IMMessagingTests/MessagingServiceTests.swift
git commit -m "feat(IMMessaging): MessagingService forwards onIncomingMessageAlert"
```

---

### Task 4: `AppEnvironment` 新增跨重连存活的中继属性

**Files:**
- Modify: `Sources/AppCore/AppEnvironment.swift`
- Test: `Tests/AppCoreTests/AppEnvironmentTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `MessagingService.onIncomingMessageAlert`。
- Produces: `public var onIncomingMessageAlert: ((_ isMuted: Bool, _ isActiveConversation: Bool, _ isGroupNotification: Bool) -> Void)?` on `AppEnvironment`（签名同上）。Task 6 (`SceneDelegate`)赋值这个属性。

- [ ] **Step 1: 写失败测试**

在 `Tests/AppCoreTests/AppEnvironmentTests.swift` 里 `test_connectIfPossible_withCredentials_alsoTriggersAFriendListSync`(第 69-91 行)之后插入：

```swift
    func test_connectIfPossible_incomingMessage_relaysOnIncomingMessageAlert() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))
        var captured: (isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool)?
        environment.onIncomingMessageAlert = { isMuted, isActiveConversation, isGroupNotification in
            captured = (isMuted, isActiveConversation, isGroupNotification)
        }

        XCTAssertTrue(environment.connectIfPossible())

        var wireMessage = Im_Message()
        wireMessage.messageID = 970
        wireMessage.fromUser = "them"
        wireMessage.conversation.type = 0
        wireMessage.conversation.target = "them"
        wireMessage.conversation.line = 0
        wireMessage.content.type = 1
        wireMessage.content.searchableContent = "hi"
        wireMessage.serverTimestamp = 1_000

        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.current = 970
        result.head = 970
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)
        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(captured?.isMuted, false)
        XCTAssertEqual(captured?.isActiveConversation, false)
        XCTAssertEqual(captured?.isGroupNotification, false)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AppCoreTests/AppEnvironmentTests/test_connectIfPossible_incomingMessage_relaysOnIncomingMessageAlert`
Expected: FAIL（"value of type 'AppEnvironment' has no member 'onIncomingMessageAlert'"）

- [ ] **Step 3: 实现**

在 `Sources/AppCore/AppEnvironment.swift:29`(`onConnectionStatusChange` 属性)之后插入同款注释+属性：

```swift
    /// 新消息提醒中继，由 `SceneDelegate` 赋值。挂在 AppEnvironment 而非
    /// MessagingService 上，理由与 `onConnectionStatusChange` 完全一致：
    /// 退出重登会重建 MessagingService，这个中继跨重建存活，
    /// `connectIfPossible()` 每次都会把新 service 的回调接到它上面。
    public var onIncomingMessageAlert: ((_ isMuted: Bool, _ isActiveConversation: Bool, _ isGroupNotification: Bool) -> Void)?
```

在 `connectIfPossible()`(第 102-153 行)里，紧跟第 123 行

```swift
        service.onGroupNotificationMessage = { [weak groupSync] groupId in groupSync?.refreshGroup(targetId: groupId) }
```

之后插入：

```swift
        service.onIncomingMessageAlert = { [weak self] isMuted, isActiveConversation, isGroupNotification in
            self?.onIncomingMessageAlert?(isMuted, isActiveConversation, isGroupNotification)
        }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AppCoreTests/AppEnvironmentTests`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/AppCore/AppEnvironment.swift Tests/AppCoreTests/AppEnvironmentTests.swift
git commit -m "feat(AppCore): AppEnvironment relays onIncomingMessageAlert across relogin"
```

---

### Task 5: `MessageAlertPolicy`——纯限流+分档逻辑

**Files:**
- Create: `Sources/AppCore/MessageAlertPolicy.swift`
- Test: `Tests/AppCoreTests/MessageAlertPolicyTests.swift`(新建)

**Interfaces:**
- Consumes: 无(纯逻辑，输入是三个 `Bool` + `Date`)。
- Produces: `public struct MessageAlertPolicy` with `public enum Alert: Equatable { case silent, vibrate, vibrateAndSound }` and `public mutating func evaluate(isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool, now: Date) -> Alert`。Task 6 (`App.MessageAlertPlayer`)持有一个实例并调用它。

- [ ] **Step 1: 写失败测试**

创建 `Tests/AppCoreTests/MessageAlertPolicyTests.swift`：

```swift
import XCTest
@testable import AppCore

final class MessageAlertPolicyTests: XCTestCase {
    func test_evaluate_mutedConversation_returnsSilentRegardlessOfOtherSignals() {
        var policy = MessageAlertPolicy()

        XCTAssertEqual(policy.evaluate(isMuted: true, isActiveConversation: false, isGroupNotification: false, now: Date()), .silent)
    }

    func test_evaluate_activeConversationNotMuted_returnsVibrate() {
        var policy = MessageAlertPolicy()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: true, isGroupNotification: false, now: Date()), .vibrate)
    }

    func test_evaluate_notActiveNotMutedNotGroupNotification_returnsVibrateAndSound() {
        var policy = MessageAlertPolicy()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: Date()), .vibrateAndSound)
    }

    func test_evaluate_groupNotificationNotMuted_alwaysReturnsVibrateEvenWhenNotActiveConversation() {
        var policy = MessageAlertPolicy()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: true, now: Date()), .vibrate)
    }

    func test_evaluate_secondCallWithinCooldownWindow_returnsSilent() {
        var policy = MessageAlertPolicy(cooldown: 2)
        let t0 = Date()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0), .vibrateAndSound)
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(1)), .silent)
    }

    func test_evaluate_callAfterCooldownWindowElapses_firesAgain() {
        var policy = MessageAlertPolicy(cooldown: 2)
        let t0 = Date()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0), .vibrateAndSound)
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(2.1)), .vibrateAndSound)
    }

    func test_evaluate_droppedCallDuringCooldown_doesNotExtendTheCooldownWindow() {
        var policy = MessageAlertPolicy(cooldown: 2)
        let t0 = Date()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0), .vibrateAndSound)
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(1)), .silent) // dropped, doesn't reset lastFiredAt
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(2.1)), .vibrateAndSound) // 2.1s after t0, not after the dropped call at t0+1
    }

    func test_evaluate_mutedCallDuringCooldown_doesNotConsumeOrExtendTheWindow() {
        var policy = MessageAlertPolicy(cooldown: 2)
        let t0 = Date()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0), .vibrateAndSound)
        XCTAssertEqual(policy.evaluate(isMuted: true, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(0.5)), .silent)
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(2.1)), .vibrateAndSound)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AppCoreTests/MessageAlertPolicyTests`
Expected: FAIL（编译错误——`MessageAlertPolicy` 不存在）

- [ ] **Step 3: 实现**

创建 `Sources/AppCore/MessageAlertPolicy.swift`：

```swift
import Foundation

/// Pure decision logic for the message-alert feature: given the three
/// signals `ReceiveMessageHandler.onIncomingMessageAlert` carries, decides
/// whether/how loudly to alert, and applies a simple global leading-edge
/// cooldown so a burst of messages (e.g. an active group chat) doesn't
/// vibrate/ring repeatedly. No UIKit/AudioToolbox dependency — the actual
/// playback lives in `App.MessageAlertPlayer`, which owns one instance of
/// this type.
///
/// **Cooldown semantics:** only a call that would otherwise produce
/// `.vibrate`/`.vibrateAndSound` starts or is subject to the cooldown.
/// `.silent` calls (muted conversation) neither consume nor extend the
/// window — a muted conversation's messages interleaved with real ones
/// don't eat into the throttle budget.
public struct MessageAlertPolicy {
    public enum Alert: Equatable {
        case silent
        case vibrate
        case vibrateAndSound
    }

    private let cooldown: TimeInterval
    private var lastFiredAt: Date?

    public init(cooldown: TimeInterval = 2.0) {
        self.cooldown = cooldown
    }

    public mutating func evaluate(isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool, now: Date) -> Alert {
        guard !isMuted else { return .silent }

        let tier: Alert = (isGroupNotification || isActiveConversation) ? .vibrate : .vibrateAndSound

        if let lastFiredAt, now.timeIntervalSince(lastFiredAt) < cooldown {
            return .silent
        }
        lastFiredAt = now
        return tier
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AppCoreTests/MessageAlertPolicyTests`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/AppCore/MessageAlertPolicy.swift Tests/AppCoreTests/MessageAlertPolicyTests.swift
git commit -m "feat(AppCore): add MessageAlertPolicy for alert-tier + cooldown decisions"
```

---

### Task 6: `App.MessageAlertPlayer` + `SceneDelegate` 接线(实际播放，装机手测)

**Files:**
- Create: `App/MessageAlertPlayer.swift`
- Modify: `App/SceneDelegate.swift`

**Interfaces:**
- Consumes: Task 4 的 `AppEnvironment.onIncomingMessageAlert`；Task 5 的 `AppCore.MessageAlertPolicy`。
- Produces: 无(叶子任务，终端行为)。

- [ ] **Step 1: 创建 `App/MessageAlertPlayer.swift`**

```swift
import AudioToolbox
import AppCore

/// 新消息本地提醒：按 `MessageAlertPolicy` 给出的档位播放系统提示音或纯
/// 震动。由 `SceneDelegate` 持有，接到 `AppEnvironment.onIncomingMessageAlert`
/// 上（见该属性的文档——中继跨重登存活，这里只需要接一次）。
///
/// 不用 `AVAudioPlayer`：`AudioServicesPlaySystemSound` 播放系统音效，
/// 天然遵循静音拨片，不需要像 `CallRingtonePlayer` 那样手动管理
/// `AVAudioSession` 分类。
final class MessageAlertPlayer {
    /// 系统 "SMS 收到 1" 三音效——遵循静音拨片。
    private static let messageSoundID: SystemSoundID = 1007
    /// 纯震动，不受静音拨片影响。
    private static let vibrateSoundID: SystemSoundID = kSystemSoundID_Vibrate

    private var policy = MessageAlertPolicy()

    func handle(isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool) {
        switch policy.evaluate(isMuted: isMuted, isActiveConversation: isActiveConversation, isGroupNotification: isGroupNotification, now: Date()) {
        case .silent:
            break
        case .vibrate:
            AudioServicesPlaySystemSound(Self.vibrateSoundID)
        case .vibrateAndSound:
            AudioServicesPlaySystemSound(Self.messageSoundID)
        }
    }
}
```

> **2026-07-15 装机验证后修正**：上面这版震动用 `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)`，装机实测只有单次统一节奏，和微信"动动-动"的双击节奏对不上。最终实现改为 `UINotificationFeedbackGenerator(.success)`（两档都用它触发震动，`.vibrateAndSound` 档在此基础上额外播放系统提示音 1007），并同步更新了 spec 里的"提示音/震动实现"一节。实际文件内容以 `App/MessageAlertPlayer.swift` 为准。

- [ ] **Step 2: 在 `App/SceneDelegate.swift` 接线**

在第 20 行 `private let ringtonePlayer = CallRingtonePlayer()` 之后加一行：

```swift
    private let messageAlertPlayer = MessageAlertPlayer()
```

在 `scene(_:willConnectTo:...)`(第 22-43 行)里，第 35 行 `environment = AppEnvironment(storage: storage)` 之后插入：

```swift
        environment.onIncomingMessageAlert = { [weak self] isMuted, isActiveConversation, isGroupNotification in
            self?.messageAlertPlayer.handle(isMuted: isMuted, isActiveConversation: isActiveConversation, isGroupNotification: isGroupNotification)
        }
```

- [ ] **Step 3: 重新生成 Xcode 工程**

Run: `bash Scripts/generate-xcodeproj.sh`
Expected: 成功退出，无报错；`App/MessageAlertPlayer.swift` 出现在工程里(`project.yml` 的 `App.sources` glob 整个 `App/` 目录，新文件自动纳入)。

- [ ] **Step 4: 编译 App target**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 装机手测(不通过模拟器，由用户在真机验证)**

对照 spec 的验证清单(`docs/superpowers/specs/2026-07-15-message-alert-notification-design.md` 末尾)逐条过一遍：
1. 停留在会话列表/联系人/我的 tab 时收到消息 → 震动+响铃。
2. 进入某会话详情页，该会话收到新消息 → 仅震动。
3. 进入会话 A 详情页，会话 B 收到新消息 → 震动+响铃。
4. 免打扰会话收到消息 → 完全无反应。
5. 打开静音拨片，非免打扰会话收到消息 → 只震动不响铃。
6. 活跃群聊短时间连续多条消息 → 不连续震动/响铃(2 秒内合并)。
7. 群成员变动通知 → 仅震动，无响铃。
8. 撤回一条消息 → 无任何提醒。
9. 冷启动登录后拉取历史消息 → 无提醒；断线重连补拉消息 → 正常按规则提醒。

- [ ] **Step 6: 提交**

```bash
git add App/MessageAlertPlayer.swift App/SceneDelegate.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): add MessageAlertPlayer wired to AppEnvironment.onIncomingMessageAlert"
```

（用户在 Step 5 验证通过后再执行本步——遵循"改完先装机等用户验证，通过后再 commit"的约定。）

---

## 收尾

- [ ] 跑一次全量 SPM 测试确认无整体回归：`swift test`(允许既有的 WebRTC/环境相关基线失败，不属于本次改动范围)。
