# Plan K: 好友管理(搜索加好友 + 好友请求)— 设计文档

**状态:** 已与用户确认,待写实施计划。

## 目标

实现 Phase 2 的第一个子计划:按 UID/手机号搜索用户 → 发起好友请求 → "新的朋友"页面展示好友请求(待处理/已同意)→ 接受。联系人列表顶部新增"新的朋友"固定入口(带未读数徽章),"联系人"Tab Bar 图标同步显示同一个未读数徽章。

## 调研中发现的关键事实(决定了本计划的范围边界)

逐一核实了 `chat-proto`/`android-chat-pro`/`chat-server-pro` 三端的真实实现(不是只看协议定义),发现:

1. **删除好友未实现**:`chat-proto`/服务端定义了 `FDL` topic,但 `chat-server-pro` 的 `handler/im/` 目录下没有对应 Handler 类;Android 客户端 `JavaProtoLogic.deleteFriend()` 是空方法体。整个系统都没做完,因此明确排除。
2. **拒绝好友请求未实现**:`HandleFriendRequestHandler` 的真实处理路径(`MemoryMessagesStore.handleFriendRequest` 的非管理员分支)不读取客户端传入的 `status` 字段,无条件把请求状态硬编码为 `RequestStatus_Accepted`。Android 客户端 UI 也从未调用过 `accept=false` 的路径(只有"接受"按钮)。因此 iOS 端"新的朋友"页面**只做"接受"按钮,不做"拒绝"按钮**,语义上完全贴合现状,不会对用户造成"点了拒绝却被服务端处理成同意"的误导。
3. **搜索用户(`US`)完整实现**:服务端 `UserSearchHandler.java` 真实可用,这是"加好友"流程里"先搜到人,再发请求"必需的一环,在范围内。
4. **好友备注(alias)完整实现但与本计划无依赖关系**:服务端 `SetFriendAliasRequestHandler`、Android `ChatManager.setFriendAlias`/`getFriendAlias` 都齐备,但这是一个独立的小功能,留给以后单独的 Plan。
5. **同意好友请求会触发服务端自动生成的系统消息**("以上是打招呼信息"、"你们已经成为好友了…"),以普通单聊消息形式推送给双方——iOS 这边只需要已有的消息展示能力正常处理,不是新概念。
6. **`FRUS`(标记已读)是真实的服务端往返**,不是纯客户端本地状态:服务端 `persistFriendRequestUnreadStatus` 会把指定时间点之前的请求标记已读,并通过 `FRN` 推送新的 head 回来。

## 范围

**包含:**
- 按关键字(UID/手机号)搜索用户,展示结果,点击发起好友请求(带验证信息)。
- "新的朋友"页面:展示收到的好友请求列表(待处理 / 已同意两种状态),"接受"按钮。
- 实时通知:对方处理或我发出的请求有更新时,服务端通过 `FRN` 推送,本地自动重新拉取。
- 未读数徽章:"联系人"Tab Bar 图标 + 联系人列表顶部"新的朋友"入口行,两处共用同一个数据源。
- 联系人列表顶部新增"新的朋友"固定入口(参照 Android `ContactFragment` 的 header-view-holder 模式)。

**明确排除(原因见上节):**
- 删除好友。
- 拒绝好友请求。
- 好友备注(alias)。

## 架构(模块划分,不新增 SPM target)

```
IMContacts (协议/网络层,新增):
  UserSearchHandler.swift + UserSearchTracker.swift
  FriendRequestSyncHandler.swift  (FRP 增量拉取 + FRN 实时通知)
  FriendRequestActionTracker.swift (FAR 发起请求 + FHR 接受请求)
  ContactSyncService 新增方法

IMStorage (数据层,新增):
  StoredFriendRequest.swift + FriendRequestStore
  v3_addFriendRequestTable 迁移

IMKit (ViewModel 层,新增):
  UserSearching / FriendRequestSending / FriendRequestSyncing 三个协议
  SearchUserViewModel.swift
  NewFriendsViewModel.swift
  ContactListViewModel 新增 unreadFriendRequestCount

App (UI 层,新增 + 改动):
  SearchUserViewController.swift
  NewFriendsViewController.swift + FriendRequestCell.swift
  ContactListViewController 改动(tableHeaderView 新增"新的朋友"入口行 + 徽章)
  SceneDelegate.swift 改动(导航接线 + Tab Bar 徽章订阅)
  AppEnvironment.swift 改动(connectIfPossible 里新增 syncFriendRequests() 调用)
```

## 协议层细节(`IMContacts`)

所有 proto 消息(`Im_AddFriendRequest`/`Im_HandleFriendRequest`/`Im_FriendRequest`/`Im_GetFriendRequestResult`/`Im_SearchUserRequest`/`Im_SearchUserResult`)和 `SubSignal`(`.us`=9, `.far`=10, `.frn`=12, `.frus`=13, `.frp`=14, `.fhr`=15)均已在 `IMProto`/`IMTransport` 中生成/定义好,无需改协议层代码生成产物。

- **搜索用户**:`ContactSyncService.searchUser(keyword:completion:)` 发送 `Im_SearchUserRequest{keyword, fuzzy:1, page:0}`(`Signal.publish, .us`)。`UserSearchTracker` 按 `sendFrame` 返回的 `messageId` 登记 completion(与 `MinioUploadURLTracker` 同款实现:5 秒超时、按 `messageId` 字典登记/移除)。`UserSearchHandler` 匹配 `PUB_ACK + .us`,解析"1 字节错误码 + `Im_SearchUserResult`"(全项目统一的 `PUB_ACK` 约定),把每个 `Im_User` 通过 `UserStore.upsertProfile(...)` 写入本地(不改 `isFriend`),再把匹配到的 `[uid]` 通过 tracker 回调出去。

- **发起好友请求**:`sendFriendRequest(targetUid:reason:completion:)` 发送 `Im_AddFriendRequest{targetUid, reason}`(`.far`)。`FriendRequestActionTracker` 登记 completion(同款 tracker 实现)。响应是"1 字节错误码"(无 payload),解析成功/失败回调给调用方。

- **接受好友请求**:`acceptFriendRequest(targetUid:completion:)` 发送 `Im_HandleFriendRequest{targetUid, status:1}`(`.fhr`;服务端实际忽略 `status` 值,但仍按协议字段语义填 1,保持协议字段本身正确,不因为"服务端不读"就乱填)。响应是"1 字节错误码",成功后**本地立即把对应行的 `status` 改成已同意**(`FriendRequestStore.markAccepted(fromUid:)`,不必等下一次增量拉取),再异步调一次 `syncFriendRequests()` 保持最终一致。

- **增量拉取好友请求列表**:`syncFriendRequests()` 读取 `SyncStateStore.get().friendRequestHead` 作为 `Im_Version.version`,发送(`.frp`)。`FriendRequestSyncHandler` 匹配 `PUB_ACK + .frp`,解析"1 字节错误码 + `Im_GetFriendRequestResult`",把每条 `entry` 按 `(fromUid, toUid)` 主键 upsert 进 `friendRequest` 表,并把 `friendRequestHead` 更新为本批结果里最大的 `updateDt`(没有结果则不更新 head)。

- **实时通知**:`FriendRequestSyncHandler` 同时匹配 `PUBLISH + .frn`(服务端主动推送,body 直接是 8 字节大端 `Int64`,**没有**"1 字节错误码"前缀——这是 `PUBLISH` 通知而非 `PUB_ACK` 响应,不走那条约定)。解析出的值按 Android 同款做法减 1 后写回 `syncState.friendRequestHead`(避免增量拉取因为严格大于比较漏掉刚好等于新 head 时间戳的那一条),然后立即调用一次 `syncFriendRequests()` 取到变化的实际内容。

- **标记已读**:`markFriendRequestsAsRead()` 发送 `Im_Version{version: 当前时间戳}`(`.frus`)。服务端把这之前的请求标记已读,并通过 `.frn` 推送新 head 回来——这条推送被上面同一个 `.frn` 分支处理,触发一次 `syncFriendRequests()`,流程闭环,不需要额外特殊处理。

## 数据层(`IMStorage`)

```swift
public struct StoredFriendRequest: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "friendRequest"

    public var fromUid: String
    public var toUid: String
    public var reason: String
    public var status: Int          // 0=待处理, 1=已同意(服务端唯一会落地的终态), 3=已拒绝(协议保留字段,目前永不会由服务端写入)
    public var updateDt: Int64
    public var fromReadStatus: Bool
    public var toReadStatus: Bool
}
```

迁移(追加在现有 `v2_addUserIsFriend` 之后):

```swift
migrator.registerMigration("v3_addFriendRequestTable") { db in
    try db.create(table: "friendRequest") { t in
        t.column("fromUid", .text).notNull()
        t.column("toUid", .text).notNull()
        t.column("reason", .text).notNull().defaults(to: "")
        t.column("status", .integer).notNull().defaults(to: 0)
        t.column("updateDt", .integer).notNull().defaults(to: 0)
        t.column("fromReadStatus", .boolean).notNull().defaults(to: false)
        t.column("toReadStatus", .boolean).notNull().defaults(to: false)
        t.primaryKey(["fromUid", "toUid"])
    }
}
```

`FriendRequestStore`(与 `UserStore`/`SyncStateStore` 同一种写法):

- `upsert(_ requests: [StoredFriendRequest]) throws` —— 按主键替换整行,供 `FriendRequestSyncHandler` 调用。
- `markAccepted(fromUid: String) throws` —— 接受请求成功后的本地即时更新(把对应行 `status` 置为 1),对应"不等下一次 FRP 就更新 UI"。
- `incomingRequestsPublisher() -> AnyPublisher<[StoredFriendRequest], Error>` —— `toUid == 本人 uid`,按 `updateDt` 降序(最新的在最前面)。
- `unreadIncomingCountPublisher() -> AnyPublisher<Int, Error>` —— 在上面过滤条件基础上再加 `status == 0 AND toReadStatus == false`,供 `ContactListViewModel` 订阅。

`SyncStateStore`/`syncState.friendRequestHead` 字段在 `v1_createSchema` 已经预留好,本计划直接复用,不需要再迁移。

## ViewModel 层(`IMKit`)

```swift
public protocol UserSearching: AnyObject {
    func searchUser(keyword: String, completion: @escaping (Result<[String], Error>) -> Void) // 返回匹配到的 uid 列表;对应 profile 已在 IMContacts 内部写入 UserStore
}
public protocol FriendRequestSending: AnyObject {
    func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void)
    func acceptFriendRequest(from uid: String, completion: @escaping (Result<Void, Error>) -> Void)
}
public protocol FriendRequestSyncing: AnyObject {
    func syncFriendRequests()
    func markFriendRequestsAsRead()
}
extension ContactSyncService: UserSearching, FriendRequestSending, FriendRequestSyncing {}
```

与 `MessageSending`/`ImageUploading`/`ContactInfoFetching` 同一种"窄接口解耦,`ConversationViewModel`/`ContactListViewModel` 不依赖具体类"写法。

```swift
public final class SearchUserViewModel {
    @Published public private(set) var results: [ContactRow] = []

    public init(userSearching: UserSearching?, friendRequestSending: FriendRequestSending?, storage: IMStorage)
    public func search(keyword: String)   // 空字符串直接清空 results,不发请求
    public func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void)
}
```

`search` 把 `searchUser` 返回的 uid 列表逐个读 `storage.users.user(uid:)`,映射成已有的 `ContactRow`(复用 Plan J 的展示行类型;`sectionLetter` 字段在这个场景不使用,固定传空字符串)。

```swift
public final class NewFriendsViewModel {
    public struct FriendRequestRow: Equatable, Hashable {
        public let fromUid: String
        public let displayName: String
        public let avatarURL: String?
        public let reason: String
        public let isAccepted: Bool   // 对应 status == 1;按钮"接受" vs 文案"已添加"
    }
    @Published public private(set) var rows: [FriendRequestRow] = []

    public init(friendRequestSyncing: FriendRequestSyncing?, friendRequestSending: FriendRequestSending?, storage: IMStorage)
    public func refresh()   // 进页面时调用:syncFriendRequests() + markFriendRequestsAsRead()
    public func accept(fromUid: String)
}
```

`rows` 订阅 `storage.friendRequests.incomingRequestsPublisher()`,再 join `storage.users.user(uid:)` 取 `displayName`/`avatarURL`(回退链与 `ContactRow` 一致:`displayName ?? name ?? uid`)。

`ContactListViewModel` 新增:

```swift
@Published public private(set) var unreadFriendRequestCount: Int = 0   // 新增,订阅 storage.friendRequests.unreadIncomingCountPublisher()
```

未读数只有这一个数据来源,被两处 UI 消费(见下节),不重复查库。

## UI 与导航(`App`)

- **`SearchUserViewController`**(新建):顶部 `UISearchBar`(文本变化触发 `viewModel.search(keyword:)`,做 300ms debounce),下方 `UITableViewDiffableDataSource<Int, ContactRow>`(单 section 扁平列表,照搬 `ConversationListViewController` 的写法),复用 `ContactListCell` 展示搜索结果行。点击一行弹出 `UIAlertController`(验证信息输入框 + "发送"/"取消"),点"发送"调 `viewModel.sendFriendRequest(to:reason:completion:)`,成功后提示并 dismiss。

- **`NewFriendsViewController`**(新建):导航栏标题"新的朋友",右上角"+"按钮 push `SearchUserViewController`。内容是 `UITableViewDiffableDataSource<Int, NewFriendsViewModel.FriendRequestRow>`(扁平列表),`FriendRequestCell` 展示头像 + 昵称 + 理由 + 右侧按钮("接受" / 灰色文案"已添加",取决于 `row.isAccepted`)。`viewWillAppear` 调用 `viewModel.refresh()`。

- **`ContactListViewController` 改动**:`tableView.tableHeaderView` 设为新增的静态视图(图标 + "新的朋友" + 圆角数字徽章 + 箭头),徽章绑定 `viewModel.$unreadFriendRequestCount`(count == 0 时隐藏)。新增 `var onNewFriendsEntryTapped: (() -> Void)?` 回调,与现有 `onContactSelected` 同写法。

- **`SceneDelegate.swift` 改动**:
  - `makeContactListNavigationController()` 接上 `onNewFriendsEntryTapped` → push `NewFriendsViewController(viewModel: NewFriendsViewModel(friendRequestSyncing:environment.contactSyncService, friendRequestSending:environment.contactSyncService, storage:environment.storage))`。
  - `makeMainTabBarController()` 新增 `private var cancellables = Set<AnyCancellable>()` 存储属性,订阅刚构造出来的 `contactListViewModel.$unreadFriendRequestCount`,写到 `contactListNav.tabBarItem.badgeValue`(`count > 0 ? String(count) : nil`)。这个订阅与 `ContactListViewController` 内部对同一个 `@Published` 属性的订阅是同一个数据源的两个独立 Combine 订阅者,不重复查库。

- **`AppEnvironment.swift` 改动**:`connectIfPossible()` 里 `connectAckHandler.onSyncState` 闭包新增一行 `contactSync?.syncFriendRequests()`,与已有的 `contactSync?.syncFriendList()` 并列。

## 测试策略

- `IMStorage`:`FriendRequestStoreTests` —— 真实 `IMStorage.openInMemory()`,覆盖 `upsert`、`markAccepted`、`incomingRequestsPublisher`/`unreadIncomingCountPublisher`(异步断言走 `XCTestExpectation`+`wait(for:timeout:)`,与 `UserStore`/`MessageStore` 的既定测试套路一致,因为同样基于 `ValueObservation.publisher(in:scheduling:.immediate)`)。
- `IMContacts`:`UserSearchHandlerTests`/`FriendRequestSyncHandlerTests`(覆盖 `.frp` 增量拉取和 `.frn` 实时通知两条路径)/`ContactSyncServiceTests`(发请求/接受请求的 tracker 超时与成功路径)—— 沿用 `FriendSyncHandlerTests`/`MinioUploadURLTracker` 既有测试套路:构造假的 frame 验证 storage 落地结果,用假 `Scheduler` 验证超时。
- `IMKit`:`SearchUserViewModelTests`/`NewFriendsViewModelTests` —— 用三个新协议的 fake 实现(同 `MessageSendingFake`/`ImageUploadingFake` 写法),验证搜索结果到 `ContactRow` 的映射、`isAccepted` 状态映射、`refresh()` 的调用时序;`ContactListViewModelTests` 补充 `unreadFriendRequestCount` 的测试用例。
- `App` UI 层(`SearchUserViewController`/`NewFriendsViewController`/`FriendRequestCell`/`ContactListViewController` 改动)只做编译期验证 + 模拟器手动检查(若环境允许),不写自动化 UI 测试 —— 与本项目目前所有 `*ViewController`/`*Cell` 的既定取向一致。

## 自查

- **无占位/待补全内容:** 以上每一节都给出了具体的类型签名、协议字段、文件路径,没有"TODO 稍后补充"。
- **内部一致性:** `FriendRequestRow`/`ContactRow` 的命名与回退链规则与 Plan I/J 已有的 `StoredMessageRow`/`ContactRow` 保持一致;`UserSearching`/`FriendRequestSending`/`FriendRequestSyncing` 与已有的 `MessageSending`/`ImageUploading`/`ContactInfoFetching` 同一种解耦写法,`ContactSyncService` 通过 extension 一并实现,不重复定义不同的依赖注入方式。
- **范围聚焦:** 仅覆盖"搜索加好友 + 好友请求展示与接受 + 未读徽章";删除好友、拒绝好友请求、好友备注三项经调研证实"不在当前系统的可行范围内"或"与本计划无依赖关系",全部明确排除,留给后续计划或服务端补齐后再做。
- **歧义点已收敛为明确选择:** "拒绝好友请求"按钮经服务端代码核实后明确去掉,不做误导用户的假功能;未读徽章范围(Tab Bar + 联系人列表入口行两处都显示,同一数据源)已由用户确认;`isDismissedLocally` 这个一度设计进数据层但没有任何调用方的字段,已在设计阶段自查移除,避免半成品字段。
