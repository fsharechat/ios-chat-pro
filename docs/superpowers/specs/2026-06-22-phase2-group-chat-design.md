# Phase 2 群聊功能设计

## 概述

本设计是 Phase 2 的第二个子计划(第一个是已完成的 Plan K 好友管理),覆盖群聊的完整闭环:建群、群消息收发(含 @提及)、成员管理(拉人/踢人)、群信息编辑(改名/改头像)、退群/解散群,以及对应的系统提示消息展示。一次性设计完整闭环,不再拆成更小的串行子计划。

复用现有协议(`chat-proto`)和服务端(`chat-server-pro`)不做任何修改;Swift 客户端在已有的 `IMTransport`/`IMProto`/`IMClient`/`IMStorage`/`IMKit`/`App` 五层架构上新增一个 `IMGroups` 模块,并扩展 `IMMessaging`/`IMKit`/`App`。

## 1. 范围与明确排除

**本轮覆盖:**

- 建群(指定初始成员,群名,无群头像上传——头像统一用占位图)
- 群消息收发,包含 @提及(@特定成员 / @所有人)的完整编解码与 UI 呈现
- 成员管理:拉人入群、踢人出群
- 群信息编辑:改群名、改群头像(仅指向占位图,不做真实上传)
- 退群、解散群
- 7 种群系统提示消息的解析与中文文案展示(建群/入群/退群/踢人/解散群/改名/改头像)

**明确排除(逐一核实服务端真实可达性后排除,均有协议字段但服务端/客户端从未真正接通,属于"半成品"协议路径):**

- **转让群主(TransferGroup)**:`TransferGroupRequest` 协议消息存在,但 `SubSignal.java`/`SubSignal.swift` 中均无对应的枚举值(无法构造可达的 wire dispatch 路径),服务端也没有对应 Handler。
- **群昵称/群名片(`GroupMember.alias`,对应 `ModifyGroupAliasTopic = "GMA"`)**:`IMTopic.java` 中定义了字符串常量,但同样没有 SubSignal 枚举值和 Handler,是死代码。
- **管理员/禁言成员角色(`GroupMemberType.Manager`/`Silent`)**:协议枚举里存在,但 Android 真实 UI(`GroupInfoActivity.java`)只检查 `Removed` 状态,完全没有 Manager/Silent 相关逻辑,确认是协议预留但从未在产品里使用的角色。
- **群公告**:整个项目(协议、服务端、Android 客户端)都未曾存在过这个功能,不是"半成品",是从未规划过。
- **群 Extra 字段(`ModifyGroupInfoType.Modify_Group_Extra`)**:协议存在,服务端有权限分支,但本轮 UI 不提供任何编辑入口,留作未来扩展点。

## 2. 协议层

`chat-proto`(`FSCMessage.proto`)中所有群相关消息均已存在,且已经在 `IMProto/Generated/*.swift` 中生成好对应的 Swift 类型,本设计**无需修改任何 proto 文件或重新生成代码**:

```proto
message Group { required GroupInfo group_info = 1; repeated GroupMember members = 2; }
message GroupInfo {
    optional string target_id = 1; required string name = 2; optional string portrait = 3;
    optional string owner = 4; required int32 type = 5; optional int32 member_count = 6;
    optional string extra = 7; optional int64 update_dt = 8; optional int64 member_update_dt = 9;
}
message GroupMember { required string memberId = 1; optional string alias = 2; required int32 type = 3; optional int64 update_dt = 4; }

message CreateGroupRequest { required Group group = 1; repeated int32 to_line = 2; optional MessageContent notify_content = 3; }
message AddGroupMemberRequest { required string group_id = 1; repeated GroupMember added_member = 2; repeated int32 to_line = 3; optional MessageContent notify_content = 4; }
message RemoveGroupMemberRequest { required string group_id = 1; repeated string removed_member = 2; repeated int32 to_line = 3; optional MessageContent notify_content = 4; }
message ModifyGroupInfoRequest { required string group_id = 1; required int32 type = 2; required string value = 3; repeated int32 to_line = 4; optional MessageContent notify_content = 5; }
message QuitGroupRequest { required string group_id = 1; repeated int32 to_line = 2; optional MessageContent notify_content = 3; }
message DismissGroupRequest { required string group_id = 1; repeated int32 to_line = 2; optional MessageContent notify_content = 3; }
message PullGroupMemberRequest { required string target = 1; required int64 head = 2; }
message PullGroupInfoResult { repeated GroupInfo info = 1; }
message PullGroupMemberResult { repeated GroupMember member = 1; }
```

`MessageContent` 已含 `mentioned_type`(字段 10)/`mentioned_target`(字段 11,`repeated string`),@提及无需任何协议改动。

**SubSignal 对应关系**(`SubSignal.swift` 与 Java 端逐值核对完全一致):`GC`=建群,`GPGI`=拉取群信息(复用 `PullUserRequest{request:[UserRequest{uid:groupId}]}` → `PullGroupInfoResult`),`GPGM`=拉取群成员(`PullGroupMemberRequest` → `PullGroupMemberResult`),`GAM`=拉人,`GKM`=踢人,`GQ`=退群,`GMI`=改群信息,`GD`=解散群。`GTG`(转让群主)、`GMA`(群昵称)在枚举中不存在,确认无法使用。

**服务端自动生成系统提示的关键简化**:`CreateGroupHandler`/`AddGroupMember`/`KickoffGroupMember`/`ModifyGroupInfoHandler`/`QuitGroupHandler`/`DismissGroupHandler` 在客户端省略 `notify_content` 时,均会用 `GroupNotificationBinaryContent` 自动生成系统提示消息并写入会话。**因此 iOS 客户端发起群操作请求时永远不传 `notify_content`,只需要解码服务端回填广播过来的系统提示消息**,不需要自己构造通知内容——这比最初设想的范围更小。

**系统提示消息 Wire 格式**(对照 Android `*NotificationContent.java` 的 `encode()`/`formatNotification()` 与服务端 `GroupNotificationBinaryContent` 逐一核实):

| 场景 | ContentType | 载体字段 | JSON 字段 | 中文文案模板 |
|---|---|---|---|---|
| 建群 | 104 | `data`(bytes,JSON) | `g`(groupId) `o`(operator) `n`(name) `ms`(初始成员uid列表) | "{操作人}创建了群组" |
| 入群 | 105 | `data` | `g` `o` `ms`(被拉入成员uid列表) | "{操作人}邀请{成员1}、{成员2}加入了群组" |
| 踢人 | 106 | `data` | `g` `o` `ms`(被踢成员uid列表) | "{操作人}将{成员1}移出了群组" |
| 退群 | 107 | `content`(字符串) | 服务端 `m=""`(因 Java 构造器重载解析问题,操作人需从消息 `from` 字段取,不要依赖 `m`) | "{操作人}退出了群组" |
| 解散群 | 108 | `data` | `g` `o` | "{操作人}解散了群组" |
| 改群名 | 110 | `data` | `g` `o` `n`(新群名) | "{操作人}修改群名为「{新群名}」" |
| 改群头像 | 112 | `data` | `g` `o` | "{操作人}修改了群头像" |

> 退群场景的 `m` 字段是已知风险点(Java 重载解析导致传空字符串),实现阶段需要用真实服务端返回的字节逐一核对,不能仅凭这里的推断编码。

## 3. 数据层(`IMStorage`)

**新增 `StoredGroup` 表**(独立于 `StoredConversation`,因为群有自己的元数据生命周期):

```swift
public struct StoredGroup: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "group_info"
    public var groupId: String
    public var name: String
    public var portrait: String?
    public var owner: String?
    public var groupType: GroupType        // .free / .normal / .restricted
    public var memberCount: Int
    public var updateDt: Int64
    public var memberUpdateDt: Int64
}

public struct StoredGroupMember: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "group_member"
    public var groupId: String
    public var memberId: String
    public var memberType: GroupMemberType  // .normal / .owner / .removed(其余值本轮不使用)
    public var updateDt: Int64
}
```

`GroupType`/`GroupMemberType` 新增到 `MessageEnums.swift`,数值与协议对齐(`GroupType`: Normal=0/Free=1/Restricted=2,核实自 `ProtoConstants.java`;`GroupMemberType`: Normal=0/Owner=2/Removed=4)。

**`StoredMessage` 扩展**:`MessageContent` 新增一个 case:

```swift
public enum MessageContent: Equatable {
    case text(String)
    case image(thumbnail: Data?, remoteURL: String?, localPath: String?)
    case groupNotification(kind: GroupNotificationKind, operatorUid: String, memberUids: [String], value: String?)
}
```

`StoredMessage` 新增列:`mentionedType: Int`(0=无,1=指定成员,2=所有人)、`mentionedTargets: [String]`(以 JSON 数组存为 `Data`/`String`,沿用 GRDB 的简单编码方式)、`groupNotificationOperator: String?`、`groupNotificationMembers: [String]?`、`groupNotificationValue: String?`。`contentType` 新增 7 个值(104/105/106/107/108/110/112),`content` 计算属性新增对应分支组装 `.groupNotification(...)`。

**`StoredConversation` 扩展**:新增 `unreadMentionCount: Int`(单独于 `unreadCount` 统计,驱动会话列表"[有人@我]"提示)。

GRDB migration 用 `registerMigration` 新增一个迁移版本,创建 `group_info`/`group_member` 两张表,并对 `message`/`conversation` 表执行 `ALTER TABLE ADD COLUMN`,均为新增列,不破坏现有数据。

## 4. 网络/同步层(新增 `IMGroups` 模块)

新建 Swift Package 模块 `IMGroups`,与 `IMContacts` 平级,依赖 `IMTransport`/`IMProto`/`IMStorage`,不依赖 `IMKit`/`App`。

```swift
public protocol GroupActing {
    func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void)
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void)
    func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void)
    func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void)
    func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void)
    func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void)
}

public protocol GroupSyncing {
    func refreshGroup(targetId: String)       // .gpgi + .gpgm 各发一次
    func refreshMembers(targetId: String)     // 仅 .gpgm,带 head 增量
}

public final class GroupSyncService: GroupActing, GroupSyncing {
    public init(connection: IMConnection, storage: IMStorage)
}
```

请求-响应关联沿用 Plan K 的 `Tracker` 模式,新增 `GroupActionTracker`(按 `messageId` 关联请求与 ack/响应,带超时)。

**群发现机制**:协议里没有"拉取我的群列表"接口,群的存在完全通过消息同步管道被动发现——任何群系统提示消息或群普通消息到达时,若本地 `group_info` 无记录或 `updateDt` 落后,触发 `GroupSyncService.refreshGroup(targetId:)` 补齐元数据和成员列表。建群成功后用服务端返回的 `group_id` 主动调一次 `refreshGroup` 完成首次落库。`ReceiveMessageHandler` 新增 `onGroupNotificationMessage: ((String) -> Void)?` 闭包,在收到任何群系统提示类型消息时触发,由 `App` 层接到 `GroupSyncService.refreshGroup`。

**权限矩阵**(核实服务端 Handler 及 `MemoryMessagesStore.java` 真实权限判断代码后的结果,用于驱动 `IMKit` 层的按钮可见性,不是猜测):

| 操作 | Free | Normal | Restricted |
|---|---|---|---|
| 拉人入群 | 任何成员 | 任何成员 | 仅群主 |
| 踢人出群 | 无人可踢(群主也不能) | 仅群主 | 仅群主 |
| 改群名/头像 | 任何成员 | 任何成员 | 仅群主 |
| 解散群 | 无人可解散 | 仅群主 | 仅群主 |
| 退群 | 任何成员 | 任何成员 | 任何成员 |

## 5. `IMMessaging` 扩展(收发管道)

- `MessagingService.sendText`/`sendImage` 新增 `mentionedType: Int = 0`、`mentionedTargets: [String] = []` 参数,写入 `Im_MessageContent.mentionedType`/`mentionedTarget`。
- `ReceiveMessageHandler` 改动两处:
  1. 不论 `contentType` 是什么,都把 `wireMessage.content.mentionedType`/`mentionedTarget` 落到 `message` 表新增列。
  2. 新增 7 个 `contentType`(104/105/106/107/108/110/112)分支,解析对应 JSON(退群是 `content` 字符串字段,其余是 `data` 字节字段)落到 `groupNotificationOperator`/`Members`/`Value` 列,组装成 `MessageContent.groupNotification(...)`,并触发 `onGroupNotificationMessage?(groupId)` 闭包。
- 写会话行时:若 `direction == .receive && conversationType == .group && (mentionedType == 2 || (mentionedType == 1 && mentionedTargets.contains(myUid)))`,`unreadCount`/`unreadMentionCount` 一起 +1。

## 6. `IMKit` ViewModel 层

`GroupInfoViewModel` 把第 4 节的权限矩阵实现成 4 个 `@Published` 布尔值(`canAddMembers`/`canKickMembers`/`canModifyInfo`/`canDismiss`),按 `(group.groupType, isOwner)` 计算,UI 层只读这 4 个值决定按钮显示,不在 ViewController 散落 if/else。

```swift
public final class CreateGroupViewModel {
    @Published public private(set) var selectedMembers: [ContactRow] = []
    public init(contactListing: ContactListing?, groupActing: GroupActing?, storage: IMStorage)
    public func toggleSelection(_ row: ContactRow)
    public func createGroup(name: String, completion: @escaping (Result<String, Error>) -> Void)
}

public final class GroupInfoViewModel {
    public struct MemberRow: Equatable, Hashable { public let uid, displayName: String; public let avatarURL: String?; public let isOwner: Bool }
    @Published public private(set) var group: StoredGroup?
    @Published public private(set) var members: [MemberRow] = []
    @Published public private(set) var canAddMembers, canKickMembers, canModifyInfo, canDismiss: Bool

    public init(groupId: String, groupActing: GroupActing?, groupSyncing: GroupSyncing?, storage: IMStorage, currentUserId: String)
    public func refresh()
    public func addMembers(_ uids: [String], completion: @escaping (Result<Void, Error>) -> Void)
    public func kickMember(_ uid: String, completion: @escaping (Result<Void, Error>) -> Void)
    public func renameGroup(_ name: String, completion: @escaping (Result<Void, Error>) -> Void)
    public func updatePortrait(url: String, completion: @escaping (Result<Void, Error>) -> Void)
    public func quitGroup(completion: @escaping (Result<Void, Error>) -> Void)
    public func dismissGroup(completion: @escaping (Result<Void, Error>) -> Void)
}
```

`ConversationListViewModel`:`conversationType == .group` 分支查新的 `GroupStore` 而非 `UserStore` 取 displayName/avatar(群头像用统一占位图,不复刻 Android 的服务端九宫格拼图);预览文案改成 `"{发消息成员当前昵称}: {摘要}"`(单聊保持原样);`unreadMentionCount > 0` 驱动 "[有人@我]" 提示。

`ConversationViewModel`(聊天页):消息行新增 `senderDisplayName`/`senderAvatarURL`(仅群聊+接收消息时非空);`groupNotification` 类型消息映射成"系统提示"行(纯文字居中,不分左右气泡),文案按第 2 节模板,`operatorUid`/`memberUids` 实时查群成员当前昵称、`from == 我的 uid` 时替换成"您";composer 新增 @ 触发(检测输入框中的 "@" 字符,弹出群成员选择,选中后插入 "@昵称 " 字面文本并记录该 uid,发送时汇总成 `mentionedType`/`mentionedTargets` 传给 `sendText`)。

## 7. `App` 层(UI / 导航接线)

**会话列表入口**:`ConversationListViewController` 新增 `navigationItem.rightBarButtonItem`("+" 图标)与 `onCreateGroupTapped: (() -> Void)?` 闭包,在 `SceneDelegate.makeConversationListNavigationController()` 中赋值,push `CreateGroupViewController`。

```swift
final class CreateGroupViewController: UIViewController {
    init(viewModel: CreateGroupViewModel)
    var onGroupCreated: ((_ groupId: String, _ name: String) -> Void)?
    // tableView 复用 ContactListCell,行右侧加 checkbox;
    // 导航栏右上角"创建"按钮在 selectedMembers.isEmpty 时禁用
}
```

`onGroupCreated` 在 `SceneDelegate` 中接成:pop 回会话列表 → 用返回的 `groupId` 构造 `ConversationRow(conversationType: .group, target: groupId, ...)` → push 新建的 `ConversationViewController`,与现有"选中联系人发消息"接线方式一致。

**群信息页**:

```swift
final class GroupInfoViewController: UIViewController {
    init(viewModel: GroupInfoViewModel)
    var onMemberTapped: ((_ uid: String) -> Void)?
}
```

布局:顶部群名+头像(`canModifyInfo` 控制是否可点击编辑)→ 成员列表(复用 `AvatarImageView`,群主显示皇冠角标)→ `canAddMembers` 时列表末尾一个"+"格子 → 底部按 `isOwner` 二选一显示"解散该群"/"退出该群"(均需对应权限位为真才显示,`Free` 类型群两者都不显示)。

`ConversationViewController` 改动:群聊时 nav bar title 可点击 push `GroupInfoViewController`;消息 cell 新增可选的 sender 头像+昵称行(仅 `conversationType == .group && !isOutgoing` 时显示);新增 `SystemTipMessageCell`(纯文字居中)渲染 `groupNotification` 行。composer 的 "@" 触发用一个轻量浮层(复用群成员列表样式)。

`SceneDelegate` 新增 `environment.groupSyncService`,`receiveMessageHandler.onGroupNotificationMessage` 闭包在此接上:触发时若本地无该 group 记录则调用 `groupSyncService.refreshGroup(targetId:)`。

## 8. 测试策略

沿用既有约定(GRDB in-memory DB + mock 协议层),新增/扩展:

- `GroupStoreTests.swift`:群/成员 CRUD、`ValueObservation` 触发。
- `GroupSyncServiceTests.swift`:`.gpgi`/`.gpgm` 请求-响应映射、`GroupActionTracker` 超时路径。
- `MessagingServiceTests.swift`(扩展):@提及字段编码断言。
- `ReceiveMessageHandlerTests.swift`(扩展):7 种 group-notification `contentType` 解析断言(尤其退群 `content` 字符串字段 vs 其余 `data` 字节字段两种取值路径)、`unreadMentionCount` 增量断言。
- `GroupInfoViewModelTests.swift`(新):把第 4 节权限矩阵逐项做成测试用例,直接断言 4 个权限 `@Published` 布尔值——这是本设计最易被未来改坏的逻辑,用矩阵驱动测试钉死。
- `CreateGroupViewModelTests.swift`(新):多选状态机 + 创建成功/失败回调。
- UI 层不写 snapshot/UI test,沿用项目现状。

## 已知风险与待实现阶段核实事项

1. 退群系统提示的 `m` 字段(Java 构造器重载解析问题导致服务端可能传空字符串)需要用真实抓包/服务端返回数据核实编码细节,操作人信息应优先从消息 `from` 字段取,不依赖该字段。
