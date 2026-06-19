# Plan J: 联系人列表(拼音索引)— 设计文档

**状态:** 已与用户确认,待写实施计划。

## 目标

实现好友列表 + 拼音索引字母条,并把登录后的根导航结构从"单一会话列表"改为"Tab Bar(消息/联系人)"。点击某个联系人进入与该好友的单聊(复用 Plan I 已建好的 `ConversationViewController`/`ConversationViewModel`)。

**明确不在本计划范围内:**"新的朋友"(好友请求)入口、群组/频道入口、搜索框、好友增删——迁移设计文档 §7 本身也明确 Phase 1 是"列表+索引字母条,不支持增删"。

## 架构

不新增 SwiftPM target。新增代码集中在:
- `Sources/IMKit`:`PinyinIndexer`(纯函数拼音分组工具)、`ContactRow`(展示行模型)、`ContactListViewModel`(MVVM 核心)。
- `App`:`ContactListViewController`、`ContactListCell`、`SceneDelegate.swift` 的根导航结构改造(改用 `UITabBarController`)。

不改动 `IMContacts`/`IMStorage` 现有的好友同步逻辑——好友列表与用户资料的拉取在 Plan F 已经完成(`ContactSyncService.syncFriendList()`、`UserStore.friendsPublisher()`),这次只是把已经在本地数据库里的数据做成一个可视化、可索引的列表。

## 拼音分组与索引字母条

新增 `Sources/IMKit/PinyinIndexer.swift`:一个纯函数工具,`sectionLetter(for name: String) -> String`,用 iOS 原生 API `name.applyingTransform(.toLatin, reverse: false)` 把显示名转换为拼音(不引入任何第三方依赖,这是 Apple 平台标准的汉字转拼音方式,等价于 `CFStringTransform` + `kCFStringTransformToLatin`),取转换结果的首字母并大写;如果转换结果的首字符不是 A-Z(例如纯数字、emoji 或转换失败的名字),归到 `"#"` 分组——这与 Android 端 `PinyinUtils`/`category` 字段遇到非汉字、非拉丁字母开头时退化到 `"#"` 的处理思路一致。

**已知的可接受局限:** iOS 的 `applyingTransform(.toLatin:)` 对多音字(如"重"可读 chóng 或 zhòng)不保证与 Android 端 `pinyin4j` 选择同一个读音,可能导致极少数姓名在两端的索引字母不完全一致。这是 Phase 1 可接受的差异,不影响列表的可用性(任何确定性转换规则下,同一个名字在同一端总是落在同一个字母分组,用户体验依然一致可预测)。

`ContactListViewModel` 把好友按这个字母分组、字母升序排列(`#` 分组放最后,与 Android 端排序习惯一致),每组内按拼音字符串排序。这样数据结构天然就是"按 section 分组"的数组,不需要额外维护一个并行的索引数组。

**字母索引条直接复用 iOS `UITableView` 的原生能力**(`UITableViewDataSource.sectionIndexTitles(for:)` + `sectionForSectionIndexTitle:at:`),系统会自动在列表右侧渲染一条可滑动跳转的字母索引条——不需要像 Android 的 `QuickIndexBar` 那样自己实现一个自定义视图。

## ViewModel 与展示行模型

```swift
public struct ContactRow: Equatable, Hashable {
    public let uid: String
    public let displayName: String
    public let avatarURL: String?
    public let sectionLetter: String
}
```

`displayName` 取 `user.displayName ?? user.name ?? user.uid` 的回退链,与 `ConversationListViewModel` 中已有的回退逻辑完全一致(保持项目内一致的"如何显示一个用户"的规则)。

`ContactListViewModel`:

```swift
public final class ContactListViewModel {
    @Published public private(set) var sections: [(letter: String, rows: [ContactRow])] = []
    public init(storage: IMStorage) { /* 订阅 storage.users.friendsPublisher() */ }
}
```

不依赖 `ContactInfoFetching` 做懒加载资料拉取——好友列表的资料已经在 Plan F 的同步流程里随好友关系一起完整拉取(`FriendSyncHandler`/`UserInfoSyncHandler`),这里只是纯展示,不需要再次发起网络请求触发新的 `fetchUserInfo` 调用。

## UI 与导航

- **`App/ContactListViewController.swift`**(新建):`UITableViewDiffableDataSource<String, ContactRow>`,section identifier 用字母字符串;点击一行,用该好友的 `uid` 构造 `ConversationViewModel(storage:messageSending:imageUploading:target:conversationType:line:)`,push 到 `ConversationViewController(row:viewModel:)`——构造方式与 Plan I 中 `SceneDelegate.makeConversationListNavigationController()` 里"点击会话进入聊天页"的现有代码完全一致,只是这次的入口是"点击联系人"而不是"点击已有会话"。由于该好友可能还没有任何历史会话,`ConversationViewModel` 初始 `rows` 为空数组,这本身就是已支持的正常状态(发送第一条消息时,`MessagingService.sendText` 内部的 `recordIncomingMessage` 调用会自动建立会话记录)。
- **`App/ContactListCell.swift`**(新建):极简的头像+姓名单行 cell,直接复用已有的 `AvatarImageView`/`AvatarLoader`(`App/AvatarImageView.swift`),不重新实现头像加载逻辑。
- **Tab Bar 接线**:修改 `App/SceneDelegate.swift`——把现在"登录成功后直接展示会话列表导航控制器"的逻辑,改为"展示一个 `UITabBarController`,两个 tab 分别是会话列表导航控制器(沿用现有的 `makeConversationListNavigationController()`)和联系人列表导航控制器(新增 `makeContactListNavigationController()`)"。这是登录后根控制器结构的一次性改造,`makeLoginViewController()`/未登录态的处理逻辑不变。

## 测试策略

- `PinyinIndexer`:单元测试覆盖常见中文姓名、纯字母/数字开头的名字、空字符串、emoji 开头等边界情况,确认转换结果与 `"#"` 退化规则符合预期。
- `ContactListViewModel`:单元测试覆盖好友列表到分组数组的映射、字母排序、组内排序是否正确。沿用 `ConversationListViewModelTests` 已确立的测试套路——真实 `IMStorage.openInMemory()`,异步断言用 `XCTestExpectation`+`wait(for:timeout:)`(因为 `friendsPublisher()` 同样基于 `ValueObservation.publisher(in:scheduling:.immediate)`,只有第一次推送同步,后续是异步)。
- UI 层(`ContactListViewController`/`ContactListCell`/Tab Bar 接线)只做编译期验证 + 模拟器手动检查(若环境允许),不写自动化 UI 测试——与本项目目前所有 `*ViewController`/`*Cell` 的既定取向一致。

## 自查

- **无占位/待补全内容:** 以上每一节都给出了具体的类型签名、转换规则和文件路径,没有"TODO 稍后补充"。
- **内部一致性:** `ContactRow`/`ContactListViewModel` 的字段命名、回退链规则与已有的 `ConversationRow`/`ConversationListViewModel` 保持一致;导航到聊天页面的构造方式与 Plan I 中 `SceneDelegate` 的现有代码逐字对应,不重复定义不同的构造路径。
- **范围聚焦:** 仅覆盖好友列表+索引字母条+点击进入单聊;好友请求/群组/频道/搜索/增删全部明确排除,留给后续计划。
- **歧义点已收敛为明确选择:** 拼音转换方案(iOS 原生 API,不引入第三方依赖)、导航结构(新增 Tab Bar,而非在会话列表导航栏加按钮)均已由用户确认。
