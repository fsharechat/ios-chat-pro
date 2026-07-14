# 退群/解散群/被踢后清理本地会话

日期：2026-07-14
状态：已确认

## 需求

1. 在群组详情页点击「退出群组」或「解散群组」成功后：
   - 导航栈直接连退两级（群详情页 + 聊天页），回到会话列表（或从群列表进入时回到群列表），不再停留在已经没有意义的聊天页。
   - 本地删除该群的会话（会话行 + 历史消息），不再残留在会话列表里。
2. 收到「群解散」通知消息后，无论是否自己发起，本地删除该群会话。
3. 收到「退群」通知消息且退群人是自己时（对应服务器把自己主动退群的动作回显回来），本地删除该群会话；别人退群不影响自己的会话。
4. 收到「被移出群」通知消息且被移除成员包含自己时，本地删除该群会话。

行为基准参照了 Android 兄弟项目（`android-chat-pro`）`ConversationListViewModel.onReceiveMessage`：其对「群解散」「自己退群回显」两种通知已有对应的 `removeConversation` 处理（`fromSelf` 标记即 `消息发送者 == 当前用户`）。「被踢出群」Android 端未处理（只显示通知文案，会话仍保留），第 4 点是本次专门为 iOS 加的行为，不是对齐 Android。

## 设计

### IMStorage 改动

- `MessageStore.clearMessages(conversationType:target:line:)` 新增 `db: Database` 重载，语义与现有非 `db:` 版本一致，仅是在调用方已持有的事务里执行，不再自己开 `dbQueue.write`。
- `ConversationStore.deleteConversation(conversationType:target:line:)` 同样新增 `db:` 重载。
- 两个重载都是现有方法体的直接搬运（把 `dbQueue.write { db in ... }` 换成直接用传入的 `db`），沿用 `IMStorage.write`/`MessageStore.insert(_:db:)` 等已有的"表操作提供 db: 重载供事务内复用"约定。

### IMMessaging 改动

- `ReceiveMessageHandler.persist(_:db:...)`：在 `recordIncomingMessage` 之后、原有 `groupNotificationTargets`/`callEvents` 记录逻辑同级的位置，追加判断：
  - `content` 为 `.groupNotification(type: .dismissGroup, ...)` → 对该 `target`（群 id）调用 `storage.messages.clearMessages(db:)` + `storage.conversations.deleteConversation(db:)`。
  - `content` 为 `.groupNotification(type: .quitGroup, ...)` 且 `direction == .send`（即 `wireMessage.fromUser == myUserId()`，退群的是自己）→ 同样清理。
  - `content` 为 `.groupNotification(type: .kickoffGroupMember, memberUids: ..., ...)` 且 `memberUids` 包含 `myUserId()` → 同样清理。
  - 三种判断共用同一个私有 helper（如 `deleteGroupConversation(target:db:)`），避免重复两行调用。
  - 这段逻辑仍在原有的批量写事务内执行（用 `db:` 重载即可，不需要事务后再派发），因为它只是普通的表操作，不会像 `onGroupNotificationMessage`/`onCallStartMessage` 那样触发外部同步写。
- 不需要处理"先插入消息、又立即删除会话"导致的竞态——`recordIncomingMessage` 和删除会话在同一事务里顺序执行，最终态就是"会话已删除"，UI 侧只会看到一次 Combine 更新。

### IMKit 改动

- `GroupInfoViewModel.quitGroup(completion:)` / `dismissGroup(completion:)`：网络调用成功后，在回调里追加本地立即删除（`storage.messages.clearMessages` + `storage.conversations.deleteConversation`，用现有的非 `db:` 版本），再调用外部 `completion`。这是乐观更新，不等服务器把通知回显回来——避免用户点击后到会话列表里那条会话还短暂存在的观感延迟。
- 与 `ReceiveMessageHandler` 那条路径不冲突：即使服务器之后把 `.dismissGroup`/`.quitGroup(自己)` 通知回显回来，`clearMessages`/`deleteConversation` 对已经不存在的会话/消息是安全的空操作。

### App 改动

- `GroupInfoViewController`：退出/解散成功的分支里，把现有的 `navigationController?.popViewController(animated: true)` 换成"连退两级"：取 `navigationController?.viewControllers`，定位到 `self` 在栈中的 index，`popToViewController` 到 `index - 2` 那一级（找不到就退化为 `popToRootViewController`，兜底非常规入栈路径）。
  不新增 SceneDelegate 回调 —— 这段逻辑只依赖 `self.navigationController`，不需要知道上一级具体是 `ConversationViewController` 还是别的类型。

## 不做的事

- 不改变"别人退群"（`.quitGroup` 且非自己）的行为——仍只落一条通知消息，不清理会话，与 Android 一致。
- 不处理"群列表"（`FavGroupListViewController` 的 `isFav` 收藏标记）——退群/解散/被踢后该群不再是会话，但 `isFav` 是独立的本地收藏状态，是否一并清除不在本次范围内。
- 不引入新的 Combine 回调或通知机制——删除会话后，`ConversationListViewModel` 已经在监听 `conversationsPublisher()`，会自动刷新。

## 测试

- `IMStorageTests`：新增对 `MessageStore.clearMessages(db:)` / `ConversationStore.deleteConversation(db:)` 的用例，验证与非 `db:` 版本行为一致。
- `IMMessagingTests`（`ReceiveMessageHandlerTests`）：三个用例覆盖表格里的三种场景（dismissGroup 任意方向、quitGroup 自己发起、kickoffGroupMember 自己在列表里），各自断言会话与消息被清空；另加一个反例（别人退群不清理）。
- `IMKitTests`（`GroupInfoViewModelTests`）：`quitGroup`/`dismissGroup` 成功后断言会话与消息已被本地清除。
- 导航连退两级是 UIKit 逻辑，无 UI 测试基础设施，装机手测。

## 验证清单（装机手测）

1. 群主解散群组 → 群详情页和聊天页一起消失，回到列表，会话消失。
2. 普通成员退出群组 → 同上。
3. 另一台设备上，群主解散群组后，本机（普通成员）打开 App → 会话自动消失。
4. 另一台设备上，群主把自己移出群组 → 本机打开 App → 会话自动消失。
5. 另一台设备上，别的成员退群/被踢（不是自己）→ 本机会话保留，仅出现一条通知消息。
