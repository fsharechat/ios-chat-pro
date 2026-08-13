# 用户设置多端同步（ios-chat-pro）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 iOS 端把用户保存的群组、会话置顶、会话免打扰通过 `UG`/`UP`/`UN` 三个信令同步到服务端，重新登录时拉回来，多端在线时实时互通。

**Architecture:** 服务端已在 2.2.12-SNAPSHOT 打通这三个信令。iOS 侧的本地存储与 UI 入口**全部已存在**（`groupInfo.isFav`、`conversation.isTop/isMuted` 三列都已持久化，群详情页开关、`FavGroupListViewController` 都在用），缺的纯粹是网络同步。本计划新增一张 `userSetting` 表作为服务端数据的本地镜像与真值来源，把它投影到既有的三列上；新增 `UserSettingSyncService` 负责发 UG/UP 并注册两个 handler；最后接进 `AppEnvironment` 的登录流程与各 ViewModel 的写入点。

**Tech Stack:** Swift 5.8、SwiftPM（`IMCore` 包）、GRDB 6、SwiftProtobuf、XCTest、XcodeGen。

**设计文档:** `chat-server-pro` 仓库的 `docs/superpowers/specs/2026-08-12-user-setting-sync-design.md`

**服务端依赖:** 需要服务端 2.2.12-SNAPSHOT（`push-group` + `push-connector` 都要更新，且 `push-group` 必须先上）已部署到联调环境，否则 UG/UP 会收到未知 topic 的错误码。

## Global Constraints

- **仓库路径**：`/Users/liaojinlong/Share/GitWorkplace/github/fshare/ios-chat-pro`。`chat-server-pro`、`android-chat-pro` 是**另外的独立 git 工作区**，本计划不改它们，也不能把它们的文件放进本仓库的提交。
- **单元测试用 `swift test`**（见仓库 `CLAUDE.md`）：全部 `swift test`，按模块 `swift test --filter IMStorageTests`，单例 `swift test --filter IMStorageTests/UserSettingStoreTests/testXxx`。
- **App 构建用 xcodebuild**：`xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build`。注意 CLAUDE.md 的警告：destination 写错不会报错，`xcodebuild` 会静默回退去构建真机 SDK。
- **新增 Swift 文件后不需要改 `project.yml`**：XcodeGen 按目录通配收集源文件；但**新增 target/module 需要改**，本计划刻意不新增 module。
- **`SubSignal` 只允许在枚举末尾追加**，禁止插入或重排。它的 rawValue 是二进制协议的一部分，与 `chat-server-pro/push-common`、`chat-server-pro/push-sdk/push-nio-sdk`、`android-chat-pro/push-sdk` 三份 Java 副本逐位对齐。改动前末位是 `sai = 40`，新增固定为 `ug = 41`、`up = 42`、`un = 43`。
- **会话类 setting 的 key 格式固定为 `type-line-target`**（连字符，如 `1-0-groupId`），与服务端 `MemoryMessagesStore.getUserConversationSlient()` 的读取格式一致。`type` 用 `ConversationType` 的 rawValue，`line` 一律传 0。
- **取消操作写 value `"0"`（tombstone）**，不删除记录；从服务端拉回 `"0"` 时也只是把它当普通值存下。读取方一律以「是否等于 `"1"`」判断是否生效，其余值（含 `"0"`）都视为未设置。
- **scope 取值**：`6` 保存到通讯录的群组（key 为 groupId）、`3` 会话置顶、`1` 会话免打扰、`2` 全局免打扰（key 为空串）。
- **不修改 protobuf**。`Sources/IMProto/Generated/WFCMessage.pb.swift` 是生成产物（`Scripts/generate-proto.sh` 需要 repo-local protoc，本计划不碰）。用到的 `Im_Version`、`Im_ModifyUserSettingReq`、`Im_GetUserSettingResult`、`Im_UserSettingEntry`、`Im_ConnectAckPayload.settingHead` **全部已存在**。
- **`PUB_ACK` 响应体统一是「1 字节错误码 + protobuf」**，见 `FriendSyncHandler`。`PUBLISH` 通知体没有这个前缀。
- **提交信息沿用仓库的 conventional commits 中文格式**：`feat(IMStorage): 描述` / `fix(App): 描述`。

---

## 现状（已逐一核实，实现前不必重新调研）

**已经就绪、本计划不用新建的东西比缺失的多得多：**

- **四个 proto message 全都在**：`Im_Version:873`、`Im_UserSettingEntry:1739`、`Im_ModifyUserSettingReq:1790`、`Im_GetUserSettingResult:1831`（`Sources/IMProto/Generated/WFCMessage.pb.swift`）。`Im_ConnectAckPayload.settingHead` 也在（`:56`）。
- **`ConnectAckHandler` 已经解析并暴露了 `settingHead`**：`ConnectAckSyncState` 结构体带 `settingHead` 字段，通过 `onSyncState` 回调抛出。接线点在 `Sources/AppCore/AppEnvironment.swift:157`，目前用 `_ in` 忽略了整个 payload。
- **`syncState` 表已经有持久化的 `settingHead` 列**（`IMDatabase.swift:96`），`SyncStateStore.get()/set()` 可读写。**iOS 与 android 在这一点上正好相反**：android 的设置存在纯内存 map、所以 version 绝不能持久化；iOS 的设置和 version 都在同一个 GRDB 库里，一起生一起死，持久化是正确的。
- **三个派生列都已持久化**：`conversation.isTop`、`conversation.isMuted`（`IMDatabase.swift:75-76`）、`groupInfo.isFav`（迁移 `v7_addGroupIsFav`）。
- **UI 入口全齐**：`App/GroupInfoViewController.swift:174`「保存到通讯录」开关 → `GroupInfoViewModel.setFav()`；`:162` 免打扰开关 → `setMuted()`；`App/SingleConversationInfoViewController.swift:116` 免打扰开关；`App/FavGroupListViewController.swift:50` 群列表页读 `storage.groups.favGroupsPublisher()`。
- **三个 ViewModel setter 都只写本地、不发网络**：`GroupInfoViewModel.setTop():223` / `setMuted():228` / `setFav():233`，`SingleConversationInfoViewModel.setTop():26` / `setMuted():31`，`ConversationListViewModel.setTop(_:for:):142`。
- **handler 范式现成**：`Sources/IMContacts/FriendSyncHandler.swift` 是 `PUB_ACK` 应答的模板（含 1 字节错误码处理），`FriendNotifyHandler` 是 `PUBLISH` 通知的模板，`ContactSyncService` 是「注册 handler + 拥有发送方法」的服务模板。
- **发送 API**：`IMClient.sendFrame(signal:subSignal:body:completion:) -> UInt16`（`Sources/IMClient/IMClient.swift:400`），fire-and-forget，响应由注册的 handler 按 `canHandle` 线性匹配。
- 迁移已到 `v8_markExistingFriendRequestsAsRead`，下一个是 `v9`。

**缺失的：**

- `SubSignal` 没有 `ug`/`up`/`un`（`Sources/IMTransport/SubSignal.swift` 末位 `sai = 40`）。
- 没有本地设置表，没有任何发 UG/UP 的代码，没有处理 UG/UN 的 handler。
- 长按会话菜单缺免打扰项：`App/ConversationListViewController.swift:115` 的 `makeMenuItems` 硬编码三项（置顶/取消置顶、清空会话、删除会话）。

**一处会被本功能推翻的既有假设（重要）：**

`IMStorage.clearSessionData()` 的文档注释里写着 `isFav`「purely local（never resynced from the server — there is no "list my groups" wire API）」。**本功能正是那个 wire API**，所以这句话在实现后不成立，必须订正。同时 `clearSessionData()` 必须一并清空新的 `userSetting` 表——它已经把 `syncState` 重置为全零（含 `settingHead`），但如果设置表不清，换账号登录会拿着上一个账号的设置、且 `settingHead` 归零后拉取虽会发生，旧数据仍会残留。android 端就在最终评审时踩到了这个坑的变体，这里从一开始就写进计划。

---

## 恢复时序（本计划要达成的目标状态）

冷启动登录后：

```
CONNECT_ACK → ConnectAckHandler.onSyncState(settingHead)
        ↓
settingHead > 本地 syncState.settingHead  →  syncUserSettings()  发 UG(本地 settingHead)
        ↓
UG 应答 → UserSettingSyncHandler
        ├─ 全部条目 upsert 进 userSetting 表（含 value "0" 的 tombstone）
        ├─ 投影到派生列：scope 3 → conversation.isTop，scope 1 → conversation.isMuted，
        │                scope 6 → groupInfo.isFav
        ├─ syncState.settingHead = 本批最大 updateDt
        └─ 回调 onSavedGroupsResolved(未在本地建行的已保存群 id) → 拉群信息
```

**为什么必须有 `userSetting` 表，不能只写派生列**：`GroupStore.setFav()` 是纯 `UPDATE ... WHERE groupId = ?`，群行不存在时静默无效。而重装后本地一个群行都没有，恰恰是最需要恢复群列表的场景——只写派生列会把数据丢光。`userSetting` 表是真值来源，派生列是给既有 UI（`favGroupsPublisher`、会话排序）用的投影。

**已保存但本地无群行的群**：由 `onSavedGroupsResolved` 回调交给 `GroupSyncService.refreshGroup(targetId:)` 逐个拉取（`AppEnvironment` 已经在用这个方法处理群通知消息）。

**订正（整支分支的最终评审发现，原文误导）**：UG-apply 时的投影只碰得到**已经存在**的群行/会话行——重装后本地是空库，投影当时无行可写，全部 no-op；而 `settingHead` 在同一事务里已经推进，这些条目此后不会再被返回，设置就此永久丢失。`GroupStore.upsertGroup`（`:12-20`）「写入前读出现有行的 `isFav` 并沿用」这句话本身没错，但只覆盖「群行已存在」的分支，对重装这个「群行还不存在」的场景完全不适用——本节原先据此得出「无需改动」的结论是错的。

现在的做法（已修复）：`upsertGroup` 与 `ConversationStore.recordIncomingMessage` 各自的**建行分支**（此前分别是"沿用旧值"和"全部留默认 false"）都改为在建行时从 `userSetting` 表按对应 scope/key 查一次，把查到的 "1" 播种进 `isFav`/`isTop`/`isMuted`；已存在的行完全不受影响，UG-apply 时的投影不变。这样无论 `.gpgi`/消息拉取是先于还是晚于 UG 到达，最终都会收敛到已保存的状态——`userSetting` 作为真值来源，任何一条建行路径都会去读它，而不是只在 UG-apply 那一次性的窗口内投影。

---

### Task 1: `SubSignal` 追加 ug / up / un 并锁定 rawValue 契约

**Files:**
- Modify: `Sources/IMTransport/SubSignal.swift`（末尾，`case sai = 40` 之后）
- Test: `Tests/IMTransportTests/SubSignalOrdinalTest.swift`（新建）

**Interfaces:**
- Produces: `SubSignal.ug`（rawValue 41）、`SubSignal.up`（42）、`SubSignal.un`（43）

- [ ] **Step 1: 写失败的测试**

创建 `Tests/IMTransportTests/SubSignalOrdinalTest.swift`：

```swift
import XCTest
@testable import IMTransport

/// SubSignal 的 rawValue 是二进制协议的一部分，与 chat-server-pro 的两份
/// Java 副本、android-chat-pro 的一份逐位对齐。只允许在末尾追加；
/// 任何插入或重排都会让线上客户端解析错位。
final class SubSignalOrdinalTest: XCTestCase {

    func testExistingRawValuesAreNotShifted() {
        XCTAssertEqual(SubSignal.none.rawValue, 0)
        XCTAssertEqual(SubSignal.us.rawValue, 9)
        XCTAssertEqual(SubSignal.gpgi.rawValue, 22)
        XCTAssertEqual(SubSignal.sai.rawValue, 40)
    }

    func testUserSettingSignalsAreAppendedAtTheEnd() {
        XCTAssertEqual(SubSignal.ug.rawValue, 41)
        XCTAssertEqual(SubSignal.up.rawValue, 42)
        XCTAssertEqual(SubSignal.un.rawValue, 43)
    }

    func testRawValueInitResolvesUserSettingSignals() {
        XCTAssertEqual(SubSignal(rawValue: 41), .ug)
        XCTAssertEqual(SubSignal(rawValue: 42), .up)
        XCTAssertEqual(SubSignal(rawValue: 43), .un)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
swift test --filter IMTransportTests/SubSignalOrdinalTest
```

Expected: 编译失败，`type 'SubSignal' has no member 'ug'`

- [ ] **Step 3: 追加枚举值**

`Sources/IMTransport/SubSignal.swift`，把末尾的

```swift
    case sai = 40
}
```

改为

```swift
    case sai = 40
    // 用户设置同步：ug 拉取、up 上报、un 服务端通知。
    // 只允许在末尾追加，rawValue 与服务端 push-common / push-nio-sdk、
    // android push-sdk 三份 Java 副本对齐
    case ug = 41
    case up = 42
    case un = 43
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
swift test --filter IMTransportTests/SubSignalOrdinalTest
```

Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/IMTransport/SubSignal.swift Tests/IMTransportTests/SubSignalOrdinalTest.swift
git commit -m "feat(IMTransport): SubSignal 追加 UG/UP/UN 并补 rawValue 契约测试"
```

---

### Task 2: `userSetting` 表与 `UserSettingStore`

本地设置的真值来源。派生列（`isTop`/`isMuted`/`isFav`）由它投影而来，不再是唯一状态。

**Files:**
- Create: `Sources/IMStorage/StoredUserSetting.swift`
- Create: `Sources/IMStorage/UserSettingStore.swift`
- Create: `Sources/IMStorage/UserSettingKeys.swift`
- Modify: `Sources/IMStorage/IMDatabase.swift`（在 `v8` 迁移之后追加 `v9`）
- Modify: `Sources/IMStorage/IMStorage.swift`（新增 `userSettings` store、`clearSessionData()` 清表、订正 `isFav` 的过期注释）
- Modify: `Sources/IMStorage/GroupStore.swift`（upsert 时保留 `isFav`）
- Test: `Tests/IMStorageTests/UserSettingStoreTests.swift`（新建）

**Interfaces:**
- Produces:
  - `StoredUserSetting`（`scope: Int`、`key: String`、`value: String`、`updateDt: Int64`，表名 `userSetting`，主键 `(scope, key)`）
  - `UserSettingStore.upsert(_ settings: [StoredUserSetting]) throws`
  - `UserSettingStore.upsert(_ settings: [StoredUserSetting], db: Database) throws`
  - `UserSettingStore.value(scope: Int, key: String) throws -> String?`
  - `UserSettingStore.enabledKeys(scope: Int) throws -> [String]` —— 只返回 value == `"1"` 的 key
  - `UserSettingStore.deleteAll(db: Database) throws`
  - `static UserSettingKeys.conversationKey(conversationType: ConversationType, line: Int, target: String) -> String`
  - `static UserSettingKeys.Scope`：`favoriteGroup = 6`、`conversationTop = 3`、`conversationSilent = 1`、`globalSilent = 2`
  - `IMStorage.userSettings: UserSettingStore`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/IMStorageTests/UserSettingStoreTests.swift`：

```swift
import XCTest
import GRDB
@testable import IMStorage

final class UserSettingStoreTests: XCTestCase {

    private func makeStorage() throws -> IMStorage {
        try IMStorage.openInMemory()
    }

    private func setting(_ scope: Int, _ key: String, _ value: String, _ updateDt: Int64) -> StoredUserSetting {
        StoredUserSetting(scope: scope, key: key, value: value, updateDt: updateDt)
    }

    func testConversationKeyIsHyphenSeparatedTypeLineTarget() {
        // 必须与服务端 MemoryMessagesStore.getUserConversationSlient 的拼法完全一致
        XCTAssertEqual(
            UserSettingKeys.conversationKey(conversationType: .group, line: 0, target: "group123"),
            "1-0-group123"
        )
        XCTAssertEqual(
            UserSettingKeys.conversationKey(conversationType: .single, line: 0, target: "user456"),
            "0-0-user456"
        )
    }

    func testScopeConstantsMatchServer() {
        XCTAssertEqual(UserSettingKeys.Scope.conversationSilent, 1)
        XCTAssertEqual(UserSettingKeys.Scope.globalSilent, 2)
        XCTAssertEqual(UserSettingKeys.Scope.conversationTop, 3)
        XCTAssertEqual(UserSettingKeys.Scope.favoriteGroup, 6)
    }

    func testUpsertThenReadBack() throws {
        let storage = try makeStorage()

        try storage.userSettings.upsert([setting(6, "group-a", "1", 100)])

        XCTAssertEqual(try storage.userSettings.value(scope: 6, key: "group-a"), "1")
    }

    func testUpsertOverwritesSameScopeAndKey() throws {
        let storage = try makeStorage()

        try storage.userSettings.upsert([setting(6, "group-a", "1", 100)])
        try storage.userSettings.upsert([setting(6, "group-a", "0", 200)])

        XCTAssertEqual(try storage.userSettings.value(scope: 6, key: "group-a"), "0")
    }

    func testSameKeyUnderDifferentScopesCoexist() throws {
        let storage = try makeStorage()

        try storage.userSettings.upsert([
            setting(3, "1-0-group-a", "1", 100),
            setting(1, "1-0-group-a", "1", 100)
        ])

        XCTAssertEqual(try storage.userSettings.value(scope: 3, key: "1-0-group-a"), "1")
        XCTAssertEqual(try storage.userSettings.value(scope: 1, key: "1-0-group-a"), "1")
    }

    func testValueReturnsNilForUnknownKey() throws {
        let storage = try makeStorage()

        XCTAssertNil(try storage.userSettings.value(scope: 6, key: "nope"))
    }

    func testEnabledKeysExcludesTombstones() throws {
        // 取消保存写的是 "0"，不是删除记录；enabledKeys 只认 "1"
        let storage = try makeStorage()
        try storage.userSettings.upsert([
            setting(6, "group-a", "1", 100),
            setting(6, "group-b", "0", 200),
            setting(6, "group-c", "1", 300),
            setting(3, "1-0-group-d", "1", 400)
        ])

        let keys = try storage.userSettings.enabledKeys(scope: 6).sorted()

        XCTAssertEqual(keys, ["group-a", "group-c"])
    }

    func testEnabledKeysReturnsEmptyForUnusedScope() throws {
        let storage = try makeStorage()

        XCTAssertEqual(try storage.userSettings.enabledKeys(scope: 2), [])
    }

    func testClearSessionDataWipesUserSettings() throws {
        // 换账号登录时必须清干净，否则新账号会看到上一个账号保存的群
        let storage = try makeStorage()
        try storage.userSettings.upsert([setting(6, "group-a", "1", 100)])

        try storage.clearSessionData()

        XCTAssertNil(try storage.userSettings.value(scope: 6, key: "group-a"))
        XCTAssertEqual(try storage.syncState.get().settingHead, 0)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
swift test --filter IMStorageTests/UserSettingStoreTests
```

Expected: 编译失败，`cannot find 'StoredUserSetting' in scope`

- [ ] **Step 3: 创建 `UserSettingKeys`**

`Sources/IMStorage/UserSettingKeys.swift`：

```swift
/// 用户设置 key 与 scope 的唯一定义处。
/// 会话类 setting 的 key 格式为 type-line-target，必须与服务端
/// MemoryMessagesStore.getUserConversationSlient() 的拼法完全一致，
/// 否则上传的设置服务端读不到。
public enum UserSettingKeys {

    /// 与服务端 UserSettingScope 对齐
    public enum Scope {
        public static let conversationSilent = 1
        public static let globalSilent = 2
        public static let conversationTop = 3
        public static let favoriteGroup = 6
    }

    public static func conversationKey(conversationType: ConversationType, line: Int, target: String) -> String {
        "\(conversationType.rawValue)-\(line)-\(target)"
    }
}
```

- [ ] **Step 4: 创建 `StoredUserSetting`**

`Sources/IMStorage/StoredUserSetting.swift`：

```swift
import GRDB

/// 服务端 t_user_setting 的本地镜像，也是本地设置的真值来源。
/// conversation.isTop/isMuted 与 groupInfo.isFav 是从这里投影出去的派生列 ——
/// 之所以两边都留，是因为那三列上已经挂着既有 UI（favGroupsPublisher、
/// 会话列表排序），而这张表在群行/会话行尚未建立时也能保住设置。
public struct StoredUserSetting: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "userSetting"

    public var scope: Int
    public var key: String
    public var value: String
    public var updateDt: Int64

    public init(scope: Int, key: String, value: String, updateDt: Int64) {
        self.scope = scope
        self.key = key
        self.value = value
        self.updateDt = updateDt
    }
}
```

- [ ] **Step 5: 创建 `UserSettingStore`**

`Sources/IMStorage/UserSettingStore.swift`：

```swift
import GRDB

/// **Threading contract:** 与本代码库其余部分一致，没有内部加锁，
/// 必须从单一一致的队列调用。
public final class UserSettingStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ settings: [StoredUserSetting]) throws {
        try dbQueue.write { db in try self.upsert(settings, db: db) }
    }

    /// 与 `upsert(_:)` 相同，跑在调用方管理的事务里 —— UG 拉取要把设置写入、
    /// 派生列投影、syncState 更新合并成一次事务，避免中间态被 UI 的 publisher 看到。
    public func upsert(_ settings: [StoredUserSetting], db: Database) throws {
        for setting in settings {
            try setting.save(db)
        }
    }

    public func value(scope: Int, key: String) throws -> String? {
        try dbQueue.read { db in
            try StoredUserSetting
                .filter(Column("scope") == scope && Column("key") == key)
                .fetchOne(db)?
                .value
        }
    }

    /// 只返回 value 为 "1" 的 key。取消操作写的是 "0"（tombstone）而非删除记录，
    /// 所以不能用「记录是否存在」判断是否生效。
    public func enabledKeys(scope: Int) throws -> [String] {
        try dbQueue.read { db in
            try StoredUserSetting
                .filter(Column("scope") == scope && Column("value") == "1")
                .fetchAll(db)
                .map(\.key)
        }
    }

    public func deleteAll(db: Database) throws {
        try StoredUserSetting.deleteAll(db)
    }
}
```

- [ ] **Step 6: 加迁移 v9**

`Sources/IMStorage/IMDatabase.swift`，在 `v8_markExistingFriendRequestsAsRead` 那段迁移之后追加：

```swift
        migrator.registerMigration("v9_addUserSettingTable") { db in
            try db.create(table: "userSetting") { t in
                t.column("scope", .integer).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.column("updateDt", .integer).notNull().defaults(to: 0)
                t.primaryKey(["scope", "key"])
            }
        }
```

- [ ] **Step 7: 接进 `IMStorage` 门面并修 `clearSessionData`**

`Sources/IMStorage/IMStorage.swift` 三处改动：

1. 属性与初始化（跟着现有六个 store 的写法）：

```swift
    public let groups: GroupStore
    public let userSettings: UserSettingStore
```

```swift
        groups = GroupStore(dbQueue: database.dbQueue)
        userSettings = UserSettingStore(dbQueue: database.dbQueue)
```

类型注释开头写的是 "get all six stores"，改成 "get all seven stores"。

2. `clearSessionData()` 里加一行清表（放在 `groups.clearAllFav(db:)` 之后、`StoredSyncState(...)` 之前）：

```swift
            try userSettings.deleteAll(db: db)
```

3. **订正 `clearSessionData()` 文档注释里那句已经失效的话**。原文说 `isFav`「purely local（never resynced from the server — there is no "list my groups" wire API，see `StoredGroup`'s doc comment）」。本功能就是那个 wire API。改写为：`isFav` 现在由服务端 scope 6 同步（见 `UserSettingSyncService`），换账号时仍必须清掉，且必须连同 `userSetting` 表一起清 —— 只清派生列而留下设置表，下次登录会把上个账号的设置重新投影回来。

- [ ] **Step 8: 给三个 setter 补 `db:` 事务重载**

Task 3 的 UG 应答要把「写设置表 + 投影派生列 + 更新 syncState」合并成一次事务，否则 UI 的 GRDB publisher 会看到中间态（比如设置已写、`isFav` 还没投影，群列表闪一下）。但 `ConversationStore.setTop/setMuted`、`GroupStore.setFav/group(groupId:)` 目前都只有各自开写事务的版本，**没有 `db:` 重载**。照 `SyncStateStore.get(db:)`/`set(_:db:)` 的现成写法补上：原方法退化成包装，实现搬进 `db:` 版本。

`Sources/IMStorage/ConversationStore.swift`，把 `setTop`（`:118`）与 `setMuted`（`:136`）各拆成两个：

```swift
    public func setTop(_ isTop: Bool, conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try self.setTop(isTop, conversationType: conversationType, target: target, line: line, db: db)
        }
    }

    /// 与上面相同，跑在调用方管理的事务里 —— 见 `UserSettingSyncHandler`，
    /// 它要把设置写入与派生列投影合并成一次事务。
    public func setTop(_ isTop: Bool, conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws {
        try db.execute(
            sql: "UPDATE conversation SET isTop = ? WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [isTop, conversationType.rawValue, target, line]
        )
    }
```

```swift
    public func setMuted(_ isMuted: Bool, conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try self.setMuted(isMuted, conversationType: conversationType, target: target, line: line, db: db)
        }
    }

    /// 与上面相同，跑在调用方管理的事务里。
    public func setMuted(_ isMuted: Bool, conversationType: ConversationType, target: String, line: Int = 0, db: Database) throws {
        try db.execute(
            sql: "UPDATE conversation SET isMuted = ? WHERE conversationType = ? AND target = ? AND line = ?",
            arguments: [isMuted, conversationType.rawValue, target, line]
        )
    }
```

`Sources/IMStorage/GroupStore.swift`，`setFav`（`:73`）与 `group(groupId:)`（`:22`）同样处理：

```swift
    public func setFav(_ isFav: Bool, groupId: String) throws {
        try dbQueue.write { db in try self.setFav(isFav, groupId: groupId, db: db) }
    }

    /// 与上面相同，跑在调用方管理的事务里。
    public func setFav(_ isFav: Bool, groupId: String, db: Database) throws {
        try db.execute(
            sql: "UPDATE groupInfo SET isFav = ? WHERE groupId = ?",
            arguments: [isFav, groupId]
        )
    }
```

```swift
    public func group(groupId: String) throws -> StoredGroup? {
        try dbQueue.read { db in try self.group(groupId: groupId, db: db) }
    }

    /// 与上面相同，跑在调用方管理的事务里。
    public func group(groupId: String, db: Database) throws -> StoredGroup? {
        try StoredGroup.fetchOne(db, key: groupId)
    }
```

**订正（整支分支的最终评审发现）**：本步骤原文断言「`GroupStore.upsertGroup` 不用改」——这在「群行已存在」时是对的，但重装后群行还不存在，`upsertGroup` 的建行分支当时把 `isFav` 留在入参默认值 `false` 上，把 UG 已经写好的 `userSetting` 悄悄丢掉。已在整支分支的最终评审后修复：`upsertGroup` 的建行分支改为从 `userSetting` 按 `scope 6 / key=groupId` 查一次并播种 `isFav`；已存在的行分支不变。详见「恢复时序」一节。

- [ ] **Step 9: 运行测试确认通过**

```bash
swift test --filter IMStorageTests
```

Expected: `UserSettingStoreTests` 9 个全过，`IMStorageTests` 其余既有测试无回归。

- [ ] **Step 10: 提交**

```bash
git add Sources/IMStorage/ Tests/IMStorageTests/UserSettingStoreTests.swift
git commit -m "feat(IMStorage): 新增 userSetting 表与 UserSettingStore，登出时一并清空"
```

---

### Task 3: UG / UP 网络层与两个 handler

**Files:**
- Create: `Sources/IMContacts/UserSettingSyncHandler.swift`
- Create: `Sources/IMContacts/UserSettingNotifyHandler.swift`
- Create: `Sources/IMContacts/UserSettingSyncService.swift`
- Test: `Tests/IMContactsTests/UserSettingSyncHandlerTests.swift`（新建）

放在 `IMContacts` 而不是新开 module：该模块已经承载「我自己这个账号的数据」的同步（`ContactSyncService.updateDisplayName` / `updatePortrait` 改的就是本账号资料），用户设置是同一类东西；新开 module 需要同时改 `Package.swift` 与 `project.yml`，对三个文件而言不划算。

**Interfaces:**
- Consumes: Task 1 的 `SubSignal.ug/.up/.un`；Task 2 的 `UserSettingStore`、`StoredUserSetting`、`UserSettingKeys`
- Produces:
  - `UserSettingSyncService.init(imClient: IMClient, storage: IMStorage)` —— 构造时注册两个 handler
  - `UserSettingSyncService.syncUserSettings()` —— 发 UG，version 取 `storage.syncState.get().settingHead`
  - `UserSettingSyncService.updateUserSetting(scope: Int, key: String, value: String)` —— 发 UP，同时把这条写进本地 `userSetting` 表
  - `UserSettingSyncService.onSavedGroupsResolved: (([String]) -> Void)?` —— UG 应用完毕后，回调「已保存但本地无群行」的群 id 列表
  - `static UserSettingSyncHandler.projectedConversationUpdates(_ entries: [Im_UserSettingEntry]) -> [(scope: Int, conversationType: ConversationType, line: Int, target: String, enabled: Bool)]` —— 纯函数，把 scope 3/1 的条目解析成派生列更新指令；不合法的 key 直接跳过
  - `static UserSettingSyncHandler.maxUpdateDt(_ entries: [Im_UserSettingEntry], current: Int64) -> Int64` —— 纯函数，版本号只增不减

- [ ] **Step 1: 写失败的测试**

两个纯函数是这个任务里唯一能脱离运行时验证的部分，重点测它们。创建 `Tests/IMContactsTests/UserSettingSyncHandlerTests.swift`：

```swift
import XCTest
import IMProto
import IMStorage
@testable import IMContacts

final class UserSettingSyncHandlerTests: XCTestCase {

    private func entry(_ scope: Int32, _ key: String, _ value: String, _ updateDt: Int64) -> Im_UserSettingEntry {
        var e = Im_UserSettingEntry()
        e.scope = scope
        e.key = key
        e.value = value
        e.updateDt = updateDt
        return e
    }

    func testProjectedConversationUpdatesParsesTopAndSilent() {
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(3, "1-0-group-a", "1", 100),
            entry(1, "0-0-user-b", "1", 200)
        ])

        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].scope, 3)
        XCTAssertEqual(updates[0].conversationType, .group)
        XCTAssertEqual(updates[0].line, 0)
        XCTAssertEqual(updates[0].target, "group-a")
        XCTAssertTrue(updates[0].enabled)
        XCTAssertEqual(updates[1].conversationType, .single)
        XCTAssertEqual(updates[1].target, "user-b")
    }

    func testProjectedConversationUpdatesTreatsTombstoneAsDisabled() {
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(3, "1-0-group-a", "0", 100)
        ])

        XCTAssertEqual(updates.count, 1)
        XCTAssertFalse(updates[0].enabled)
    }

    func testProjectedConversationUpdatesIgnoresNonConversationScopes() {
        // scope 6 的 key 是群 id、scope 2 的 key 是空串，都不是会话三元组
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(6, "group-a", "1", 100),
            entry(2, "", "1", 200)
        ])

        XCTAssertTrue(updates.isEmpty)
    }

    func testProjectedConversationUpdatesSkipsMalformedKeys() {
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(3, "not-a-key", "1", 100),
            entry(3, "", "1", 200),
            entry(3, "x-0-target", "1", 300),
            entry(3, "1-0-good", "1", 400)
        ])

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].target, "good")
    }

    func testProjectedConversationUpdatesKeepsHyphensInsideTarget() {
        // 群 id 本身可能含连字符，只能按前两个分隔符切
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(3, "1-0-abc-def-ghi", "1", 100)
        ])

        XCTAssertEqual(updates[0].target, "abc-def-ghi")
    }

    func testMaxUpdateDtNeverGoesBackwards() {
        let entries = [entry(6, "a", "1", 100), entry(6, "b", "1", 50)]

        XCTAssertEqual(UserSettingSyncHandler.maxUpdateDt(entries, current: 200), 200)
        XCTAssertEqual(UserSettingSyncHandler.maxUpdateDt(entries, current: 0), 100)
        XCTAssertEqual(UserSettingSyncHandler.maxUpdateDt([], current: 77), 77)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
swift test --filter IMContactsTests/UserSettingSyncHandlerTests
```

Expected: 编译失败，`cannot find 'UserSettingSyncHandler' in scope`

- [ ] **Step 3: 创建 UG 应答 handler**

`Sources/IMContacts/UserSettingSyncHandler.swift`：

```swift
import Foundation
import IMClient
import IMProto
import IMStorage
import IMTransport

/// 处理 `PUB_ACK`/`UG` 的用户设置增量拉取应答。线上格式与其他 PUB_ACK 一致：
/// 1 字节错误码 + `Im_GetUserSettingResult`。
///
/// 全部条目写进 `userSetting` 表（含 value "0" 的 tombstone —— 保留它才能表达
/// 「这条被取消过」，读取方一律只认 "1"），再投影到 conversation.isTop /
/// conversation.isMuted / groupInfo.isFav 三个派生列。
///
/// **Threading contract:** 与本代码库其余部分一致，没有内部加锁，
/// 必须从单一一致的队列调用。
public final class UserSettingSyncHandler: MessageHandler {
    private let storage: IMStorage

    /// UG 应用完毕后回调「已保存(scope 6 = "1")但本地还没有群行」的群 id。
    /// 由 AppEnvironment 接到 GroupSyncService.refreshGroup(targetId:) —— 重装后
    /// 本地一个群行都没有，不拉群信息的话 FavGroupListViewController 是空的。
    public var onSavedGroupsResolved: (([String]) -> Void)?

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .ug
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_GetUserSettingResult(serializedBytes: frame.body.dropFirst()) else { return }

        let entries = result.entry
        guard !entries.isEmpty else { return }

        var unresolvedGroupIds: [String] = []
        do {
            try storage.write { db in
                try storage.userSettings.upsert(entries.map {
                    StoredUserSetting(scope: Int($0.scope), key: $0.key, value: $0.value, updateDt: $0.updateDt)
                }, db: db)

                for update in Self.projectedConversationUpdates(entries) {
                    if update.scope == UserSettingKeys.Scope.conversationTop {
                        try storage.conversations.setTop(update.enabled, conversationType: update.conversationType, target: update.target, line: update.line, db: db)
                    } else {
                        try storage.conversations.setMuted(update.enabled, conversationType: update.conversationType, target: update.target, line: update.line, db: db)
                    }
                }

                for entry in entries where Int(entry.scope) == UserSettingKeys.Scope.favoriteGroup {
                    let isFav = entry.value == "1"
                    try storage.groups.setFav(isFav, groupId: entry.key, db: db)
                    if isFav, try storage.groups.group(groupId: entry.key, db: db) == nil {
                        unresolvedGroupIds.append(entry.key)
                    }
                }

                var syncState = try storage.syncState.get(db: db)
                syncState.settingHead = Self.maxUpdateDt(entries, current: syncState.settingHead)
                try storage.syncState.set(syncState, db: db)
            }
        } catch {
            return
        }

        if !unresolvedGroupIds.isEmpty {
            onSavedGroupsResolved?(unresolvedGroupIds)
        }
    }

    /// 把 scope 3/1 的条目解析成派生列更新指令。key 不是合法会话三元组的直接跳过 ——
    /// scope 6 的 key 是群 id、scope 2 的 key 是空串，都不该走这里。
    public static func projectedConversationUpdates(
        _ entries: [Im_UserSettingEntry]
    ) -> [(scope: Int, conversationType: ConversationType, line: Int, target: String, enabled: Bool)] {
        var updates: [(scope: Int, conversationType: ConversationType, line: Int, target: String, enabled: Bool)] = []
        for entry in entries {
            let scope = Int(entry.scope)
            guard scope == UserSettingKeys.Scope.conversationTop
                    || scope == UserSettingKeys.Scope.conversationSilent else { continue }
            // target 里可能含连字符（群 id），只按前两个分隔符切
            let parts = entry.key.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let typeRaw = Int(parts[0]),
                  let conversationType = ConversationType(rawValue: typeRaw),
                  let line = Int(parts[1]),
                  !parts[2].isEmpty else { continue }
            updates.append((scope, conversationType, line, String(parts[2]), entry.value == "1"))
        }
        return updates
    }

    /// 版本号只增不减：以当前值为起点取最大，重叠拉取也不会回退。
    public static func maxUpdateDt(_ entries: [Im_UserSettingEntry], current: Int64) -> Int64 {
        entries.reduce(current) { max($0, $1.updateDt) }
    }
}
```

上面用到的 `ConversationStore.setTop/setMuted(..., db:)` 与 `GroupStore.setFav(..., db:)`/`group(groupId:db:)` 四个事务重载由 **Task 2 Step 8** 提供，本任务直接用即可。不要绕开事务把它们拆成独立写入——那样 UI 的 publisher 会看到中间态。

- [ ] **Step 4: 创建 UN 通知 handler**

`Sources/IMContacts/UserSettingNotifyHandler.swift`：

```swift
import Foundation
import IMClient
import IMTransport

/// `PUBLISH`/`UN`：服务端告知「你的设置变了」。body 是 8 字节大端 version，
/// 但这里不需要解析它 —— 直接触发一次增量拉取，由 UG 应答带回真正的数据。
/// 发起修改的那台设备也会收到自己的 UN，多拉一次是幂等的。
///
/// **Threading contract:** 与本代码库其余部分一致，没有内部加锁，
/// 必须从单一一致的队列调用。
public final class UserSettingNotifyHandler: MessageHandler {
    public var onUserSettingUpdateNotified: (() -> Void)?

    public init() {}

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .publish && subSignal == .un
    }

    public func handle(frame: Frame) {
        onUserSettingUpdateNotified?()
    }
}
```

- [ ] **Step 5: 创建 `UserSettingSyncService`**

`Sources/IMContacts/UserSettingSyncService.swift`：

```swift
import Foundation
import IMClient
import IMProto
import IMStorage

/// 用户设置同步的唯一入口：构造时注册 UG 应答与 UN 通知两个 handler，
/// 对外暴露 `syncUserSettings()`（拉）与 `updateUserSetting(scope:key:value:)`（推）。
///
/// 放在 IMContacts 而非新开 module：该模块已经承载「我自己这个账号的数据」的同步
/// （ContactSyncService.updateDisplayName / updatePortrait），用户设置是同一类东西。
///
/// **Threading contract:** 与本代码库其余部分一致，没有内部加锁，
/// 必须从单一一致的队列调用。
public final class UserSettingSyncService {
    private let imClient: IMClient
    private let storage: IMStorage

    /// 转发自 `UserSettingSyncHandler.onSavedGroupsResolved`：已保存但本地无群行的
    /// 群 id。AppEnvironment 把它接到 GroupSyncService.refreshGroup(targetId:)。
    public var onSavedGroupsResolved: (([String]) -> Void)? {
        get { syncHandler.onSavedGroupsResolved }
        set { syncHandler.onSavedGroupsResolved = newValue }
    }

    private let syncHandler: UserSettingSyncHandler

    public init(imClient: IMClient, storage: IMStorage) {
        self.imClient = imClient
        self.storage = storage
        syncHandler = UserSettingSyncHandler(storage: storage)
        imClient.register(syncHandler)

        let notifyHandler = UserSettingNotifyHandler()
        notifyHandler.onUserSettingUpdateNotified = { [weak self] in self?.syncUserSettings() }
        imClient.register(notifyHandler)
    }

    /// 增量拉取：version 取本地已同步到的 settingHead，新设备为 0 即全量。
    public func syncUserSettings() {
        let version = (try? storage.syncState.get().settingHead) ?? 0
        var request = Im_Version()
        request.version = version
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .ug, body: body)
    }

    /// 上报一条设置，同时立刻写本地，UI 不必等服务端往返。
    /// 取消操作传 value "0"（tombstone），不要用删除表达。
    /// 上报失败不回滚本地，下次登录以服务端为准 —— 与 android 端行为一致。
    public func updateUserSetting(scope: Int, key: String, value: String) {
        try? storage.userSettings.upsert([
            StoredUserSetting(scope: scope, key: key, value: value,
                              updateDt: Int64(Date().timeIntervalSince1970 * 1000))
        ])

        var request = Im_ModifyUserSettingReq()
        request.scope = Int32(scope)
        request.key = key
        request.value = value
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .up, body: body)
    }
}
```

- [ ] **Step 6: 运行测试确认通过**

```bash
swift test --filter IMContactsTests
```

Expected: `UserSettingSyncHandlerTests` 6 个全过，`IMContactsTests` 其余既有测试无回归。

两个 handler 的 `handle(frame:)` 与 service 的发送方法**没有单测**：前者需要构造真实 `Frame` 与带库的 `IMStorage`、后者需要活的连接，可测的解析与版本号逻辑已抽成上面两个静态纯函数并覆盖。端到端由 Task 5 的真机清单兜底。

- [ ] **Step 7: 提交**

```bash
git add Sources/IMContacts/UserSettingSyncHandler.swift \
        Sources/IMContacts/UserSettingNotifyHandler.swift \
        Sources/IMContacts/UserSettingSyncService.swift \
        Sources/IMStorage/ \
        Tests/IMContactsTests/UserSettingSyncHandlerTests.swift
git commit -m "feat(IMContacts): 新增用户设置 UG/UP 同步服务与 UG/UN 两个 handler"
```

（若 Step 3 给 `ConversationStore`/`GroupStore` 补了 `db:` 重载，它们在 `Sources/IMStorage/` 里，一并提交。）

---

### Task 4: 接进登录流程与各 ViewModel 的写入点

**Files:**
- Create: `Sources/IMKit/UserSettingWriting.swift`
- Modify: `Sources/AppCore/AppEnvironment.swift:148-160`（构造 service、接 `onSyncState`、接 `onSavedGroupsResolved`）
- Modify: `Sources/IMKit/GroupInfoViewModel.swift:59`（init）与 `:223-238`（三个 setter 发 UP）
- Modify: `Sources/IMKit/SingleConversationInfoViewModel.swift:13`（init）与 `:26-35`（两个 setter 发 UP）
- Modify: `Sources/IMKit/ConversationListViewModel.swift:19`（init）与 `:142`（`setTop(_:for:)` 发 UP）

**Interfaces:**
- Consumes: Task 3 的 `UserSettingSyncService`；Task 2 的 `UserSettingKeys.conversationKey(conversationType:line:target:)` 与 `UserSettingKeys.Scope`
- Produces:
  - `protocol UserSettingWriting: AnyObject { func updateUserSetting(scope: Int, key: String, value: String) }`，并 `extension UserSettingSyncService: UserSettingWriting {}`
  - 完整链路——UI 改设置 → 本地立即生效 + UP 上报；登录 → 按 settingHead 决定是否 UG

**依赖方向要求**：ViewModel **不得直接依赖 `UserSettingSyncService`**。IMKit 的既有惯例是为每个跨模块依赖定义一个窄协议（`GroupSyncing.swift`、`ContactInfoFetching.swift`、`ProfileUpdating.swift` 等十来个文件都是这个形状：`import IMContacts` + 声明协议 + `extension 具体服务: 协议 {}`），ViewModel 只认协议。照抄这个形状。

- [ ] **Step 0: 定义 `UserSettingWriting` 协议**

`Sources/IMKit/UserSettingWriting.swift`（照 `Sources/IMKit/GroupSyncing.swift` 的形状）：

```swift
// Sources/IMKit/UserSettingWriting.swift
import IMContacts

/// Narrow interface the conversation/group view models depend on instead of
/// the concrete `UserSettingSyncService`.
public protocol UserSettingWriting: AnyObject {
    func updateUserSetting(scope: Int, key: String, value: String)
}

extension UserSettingSyncService: UserSettingWriting {}
```

- [ ] **Step 1: `AppEnvironment` 构造并接线**

`Sources/AppCore/AppEnvironment.swift`，在 `let groupSync = GroupSyncService(...)` 那一行之后新增：

```swift
        let userSettingSync = UserSettingSyncService(imClient: client, storage: storage)
        userSettingSync.onSavedGroupsResolved = { [weak groupSync] groupIds in
            for groupId in groupIds { groupSync?.refreshGroup(targetId: groupId) }
        }
```

把 `onSyncState` 的闭包从忽略 payload 改成使用它：

```swift
        connectAckHandler.onSyncState = { [weak service, weak contactSync, weak userSettingSync, storage, userId = credentials.userId] state in
            // 服务端有设置且比本地新才拉。settingHead 为 0 表示服务端确实没有任何设置。
            let localSettingHead = (try? storage.syncState.get().settingHead) ?? 0
            if state.settingHead > localSettingHead {
                userSettingSync?.syncUserSettings()
            }
            service?.pullMessagesSinceLastSync()
            contactSync?.syncFriendList()
            contactSync?.syncFriendRequests()
            contactSync?.fetchUserInfo(uids: [userId], forceRefresh: false)
        }
```

**顺序要求**：`syncUserSettings()` 排在 `pullMessagesSinceLastSync()` 之前。iOS 的会话行由消息拉取创建，设置先到位可以少一轮「先建成未置顶、再被投影纠正」的界面抖动。与 android 不同的是，iOS 有 `userSetting` 表兜底，顺序颠倒不会丢数据，所以这是优化项而非正确性要求。

还要把 service 存进属性以免被释放——照现有 `contactSyncService`/`groupSyncService` 的写法加一个 `userSettingSyncService` 属性并在下方赋值。

- [ ] **Step 2: `GroupInfoViewModel` 三个 setter 发 UP**

`Sources/IMKit/GroupInfoViewModel.swift`。先在 init（`:59`）末尾追加一个带默认值的参数并存成属性，其余参数顺序不动：

```swift
    public init(groupId: String, groupActing: GroupActing?, groupSyncing: GroupSyncing?, storage: IMStorage, contactSync: ContactInfoFetching? = nil, currentUserId: String, userSettingWriting: UserSettingWriting? = nil) {
```

`= nil` 默认值是为了既有的测试与预览构造点不必全部改签名——`GroupInfoViewModel` 已经在用同样的手法（`contactSync: ContactInfoFetching? = nil`）。

然后把三个 setter 改为：

```swift
    public func setTop(_ value: Bool) {
        isTop = value
        try? storage.conversations.setTop(value, conversationType: .group, target: groupId)
        userSettingWriting?.updateUserSetting(
            scope: UserSettingKeys.Scope.conversationTop,
            key: UserSettingKeys.conversationKey(conversationType: .group, line: 0, target: groupId),
            value: value ? "1" : "0")
    }

    public func setMuted(_ value: Bool) {
        isMuted = value
        try? storage.conversations.setMuted(value, conversationType: .group, target: groupId)
        userSettingWriting?.updateUserSetting(
            scope: UserSettingKeys.Scope.conversationSilent,
            key: UserSettingKeys.conversationKey(conversationType: .group, line: 0, target: groupId),
            value: value ? "1" : "0")
    }

    public func setFav(_ value: Bool) {
        isFav = value
        try? storage.groups.setFav(value, groupId: groupId)
        userSettingWriting?.updateUserSetting(
            scope: UserSettingKeys.Scope.favoriteGroup,
            key: groupId,
            value: value ? "1" : "0")
    }
```

属性名统一用 `userSettingWriting`（类型 `UserSettingWriting?`），与 init 参数同名。

- [ ] **Step 3: `SingleConversationInfoViewModel` 两个 setter 发 UP**

`Sources/IMKit/SingleConversationInfoViewModel.swift`。init（`:13`）末尾追加同样的参数：

```swift
    public init(userId: String, storage: IMStorage, userSettingWriting: UserSettingWriting? = nil) {
```

两个 setter 改为：

```swift
    public func setTop(_ value: Bool) {
        isTop = value
        try? storage.conversations.setTop(value, conversationType: .single, target: userId)
        userSettingWriting?.updateUserSetting(
            scope: UserSettingKeys.Scope.conversationTop,
            key: UserSettingKeys.conversationKey(conversationType: .single, line: 0, target: userId),
            value: value ? "1" : "0")
    }

    public func setMuted(_ value: Bool) {
        isMuted = value
        try? storage.conversations.setMuted(value, conversationType: .single, target: userId)
        userSettingWriting?.updateUserSetting(
            scope: UserSettingKeys.Scope.conversationSilent,
            key: UserSettingKeys.conversationKey(conversationType: .single, line: 0, target: userId),
            value: value ? "1" : "0")
    }
```

- [ ] **Step 4: `ConversationListViewModel.setTop` 发 UP**

`Sources/IMKit/ConversationListViewModel.swift`。init（`:19`）末尾追加参数：

```swift
    public init(storage: IMStorage, contactSync: ContactInfoFetching?, groupSync: GroupSyncing? = nil, currentUserId: String = "", userSettingWriting: UserSettingWriting? = nil) {
```

`setTop(_:for:)`（`:142`）在既有的 `storage.conversations.setTop(...)` 之后追加上报。`ConversationRow` 上有现成的 `conversationType` / `target` / `line` / `isTop` / `isMuted` 字段（`Sources/IMKit/ConversationRow.swift:4-14`）：

```swift
    public func setTop(_ isTop: Bool, for row: ConversationRow) throws {
        try storage.conversations.setTop(isTop, conversationType: row.conversationType, target: row.target, line: row.line)
        userSettingWriting?.updateUserSetting(
            scope: UserSettingKeys.Scope.conversationTop,
            key: UserSettingKeys.conversationKey(conversationType: row.conversationType, line: row.line, target: row.target),
            value: isTop ? "1" : "0")
    }
```

- [ ] **Step 5: 构建并回归全部测试**

```bash
swift test
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: 两条都成功；`swift test` 中 Task 1-3 新增的测试与既有测试全过。

若 `ios-chat-pro.xcodeproj` 不存在或报缺文件，先跑 `Scripts/generate-xcodeproj.sh` 重新生成。

- [ ] **Step 6: 提交**

```bash
git add Sources/AppCore/AppEnvironment.swift Sources/IMKit/
git commit -m "feat(AppCore): 登录时按 settingHead 拉取用户设置，三个 ViewModel 的开关改为同时上报"
```

---

### Task 5: 长按会话菜单补免打扰，真机验证

**Files:**
- Modify: `App/ConversationListViewController.swift:115-136`（`makeMenuItems`）
- Modify: `Sources/IMKit/ConversationListViewModel.swift`（新增 `setMuted(_:for:)`）

**Interfaces:**
- Consumes: Task 4 打通的完整链路
- Produces: `ConversationListViewModel.setMuted(_ isMuted: Bool, for row: ConversationRow) throws`

- [ ] **Step 1: ViewModel 补 `setMuted`**

`Sources/IMKit/ConversationListViewModel.swift`，照 `setTop(_:for:)`（`:142`）的形状新增：

```swift
    public func setMuted(_ isMuted: Bool, for row: ConversationRow) throws {
        try storage.conversations.setMuted(isMuted, conversationType: row.conversationType, target: row.target, line: row.line)
        userSettingWriting?.updateUserSetting(
            scope: UserSettingKeys.Scope.conversationSilent,
            key: UserSettingKeys.conversationKey(conversationType: row.conversationType, line: row.line, target: row.target),
            value: isMuted ? "1" : "0")
    }
```

- [ ] **Step 2: 长按菜单加一项**

`App/ConversationListViewController.swift` 的 `makeMenuItems(for:)`，在置顶那一项之后、「清空会话」之前插入：

```swift
            .init(symbolName: row.isMuted ? "bell" : "bell.slash",
                  title: row.isMuted ? "取消免打扰" : "消息免打扰") { [weak self] in
                do {
                    try self?.viewModel.setMuted(!row.isMuted, for: row)
                } catch {
                    self?.showStorageError(error)
                }
            },
```

与置顶项一致：按 `row.isMuted` 二选一显示标题与图标，错误走同一个 `showStorageError`。

- [ ] **Step 3: 构建并装真机**

```bash
swift test
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

测试机：于任飞的 iPhone（iPhone 14 Pro），UDID `00008120-001945391147401E`，bundleID `cn.comsince.fschat`。本机是 2017 Intel MacBook Pro（macOS 13.7）+ Xcode 15.2，按 `CLAUDE.md` 的说明用 Xcode 或 `devicectl` 安装。

- [ ] **Step 4: 真机验证清单**

需要联调环境的服务端已更新到 2.2.12-SNAPSHOT（`push-group` 先于 `push-connector`）。

| # | 操作 | 预期 |
|---|---|---|
| 1 | 群详情页打开「保存到通讯录」 | 该群出现在 `FavGroupListViewController`；`userSetting` 表出现 scope 6 记录 |
| 2 | 杀进程重新登录 | 群列表仍在（本地库未清，走 `groupInfo.isFav`） |
| 3 | 删除 App 重装后登录 | 对应恢复时序：先 UG 拉回设置写入 `userSetting` 表，再投影 `isFav`；本地无群行的已保存群通过 `onSavedGroupsResolved` 逐个拉回群信息，最终「我的群组」页完整恢复 |
| 4 | 长按会话选「消息免打扰」，再长按 | 菜单变为「取消免打扰」 |
| 5 | 会话详情页置顶后重装登录 | 该会话恢复置顶（消息拉回来建会话行后 `isTop` 被投影上去） |
| 6 | 同账号第二台设备在线时改任一设置 | 第二台设备收到 UN 后自动拉取并更新界面 |
| 7 | 群详情页关闭「保存到通讯录」，重装登录 | 该群不再出现在「我的群组」（服务端返回 tombstone `"0"`，`enabledKeys` 不认它） |
| 8 | **登出后换第二个账号登录** | 「我的群组」显示的是第二个账号的群，不是第一个账号的（`clearSessionData()` 清了 `userSetting` 表与 `settingHead`） |

第 3 条和第 8 条是这个计划里最容易出问题的两条，不要跳过。

- [ ] **Step 5: 提交**

```bash
git add App/ConversationListViewController.swift Sources/IMKit/ConversationListViewModel.swift
git commit -m "feat(App): 长按会话菜单新增消息免打扰，与置顶项一样按当前状态二选一"
```

---

## 已知限制与后续项

- **全局免打扰（scope 2）没有 UI 入口**，本计划只保证协议侧可用：`UserSettingSyncHandler` 会把它写进 `userSetting` 表，但没有任何界面读它。
- **`userSetting` 表与三个派生列（`groupInfo.isFav`/`conversation.isTop`/`conversation.isMuted`）存在冗余**。真值在表里，派生列是给既有 UI（`favGroupsPublisher`、会话排序）用的投影。保留派生列是为了不改动那些 UI；代价是每一条建行路径都要记得从 `userSetting` 播种（`GroupStore.upsertGroup`、`ConversationStore.recordIncomingMessage`），漏一处就是一次重装后设置丢失。Android 端没有这层派生列，直接读 `userSetting` 表。若将来把 iOS 的 UI 也改成直接读 `userSetting`，这三个派生列可以退役，同时消除"建行路径必须记得播种"这类隐患。
- **老服务端兼容**：若联调环境还没更新到 2.2.12-SNAPSHOT，UG/UP 会收到未知 topic 的错误码。两个发送方法都是 fire-and-forget，不会阻塞登录流程，但设置不会同步。真机验证前先确认服务端版本。
- **UP 没有 ack 处理**：`sendFrame` 的 completion 只反映「发出去了」，服务端是否成功不可观测。与 android 端当前状态一致，需要时再补 `PUB_ACK`/`UP` 的 handler。
