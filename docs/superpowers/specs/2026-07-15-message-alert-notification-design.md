# 消息提醒方案：会话列表震动+响铃 / 聊天内仅震动

日期：2026-07-15
状态：已确认

## 背景

现状：应用对收到的新消息**没有任何**震动/铃声/本地通知提醒——唯一的音频/震动反馈是通话铃声（`App/CallRingtonePlayer.swift`），走完全独立的代码路径。应用也没有接入 APNs，服务端是自建 TCP（`IMClient`），消息只能在连接存活时被感知，锁屏或被杀后台后收不到新消息事件。

参考微信的提醒设计：停留在消息主界面（或任何非聊天详情页）时，新消息震动+响铃；进入某个聊天详情页时，新消息只震动。本设计仅覆盖**前台场景**（连接存活期间），不涉及 APNs/远程推送。

## 需求

1. 用户不在任何聊天详情页时（会话列表、联系人、我的、群详情、个人资料页等），收到新消息 → 震动 + 系统提示音。
2. 用户正处于某个聊天详情页时：
   - 若新消息属于**当前打开的这个会话** → 仅震动。
   - 若新消息属于**其他会话** → 仍按第 1 条处理（震动+响铃），因为用户可能根本没看到。
3. 已设置"消息免打扰"（`StoredConversation.isMuted`）的会话，新消息完全静默（不震动不响铃）。
4. 提示音遵循 iPhone 侧边静音拨片（拨片静音时不出声，仍可震动）；震动本身不受拨片影响，与系统"静音时振动"开关行为一致，应用层不做特殊处理。
5. 短时间内连续收到多条消息（如活跃群聊刷屏）需要简单限流，避免连续震动/响铃造成打扰。
6. 群通知消息（成员变动等 `.groupNotification`）和撤回消息（`.recalled`）不算"新消息"：
   - 群通知：仅震动（不响铃），仍遵循免打扰/当前会话规则（免打扰静默；命中当前会话时和非命中一样只是震动，没有更低一档）。
   - 撤回：完全静默，不触发任何提醒。
7. 首次登录/长时间离线重连的历史消息补拉（`suppressUnreadIncrement == true` 期间）不触发任何提醒，与现有"不增未读数"逻辑共用同一开关。
8. 自己在其他设备发出、回显到本机的消息（`direction == .send`）不触发提醒——沿用现有分支，无需额外处理。

## 决策表

| content 类型 | isMuted | isActiveConversation（命中当前打开的会话） | 提醒行为 |
|---|---|---|---|
| `.recalled` | — | — | 不触发（完全排除，不进入候选） |
| `.groupNotification` | true | — | 静默 |
| `.groupNotification` | false | 任意 | 仅震动 |
| 普通消息 | true | — | 静默 |
| 普通消息 | false | true | 仅震动 |
| 普通消息 | false | false | 震动 + 系统提示音 |

`isActiveConversation` 沿用 `ReceiveMessageHandler` 现有的 `activeConversation` 字段（`ConversationViewModel.markActive/markInactive` 在 `viewWillAppear/viewWillDisappear` 里维护），是"消息命中的会话是否等于用户当前正打开的那个会话"的精确匹配，与用户停留在哪个 tab 无关——因此**不需要**新增"当前是否在消息主界面"这类 tab 级别的状态追踪。

通话记录消息（`.callRecord`，通话气泡）不做特殊排除，按"普通消息"行处理——来电本身已有 `CallRingtonePlayer` 的强提醒，通话记录气泡落库时按普通消息规则再震动/响铃一次即可，不加特判。

## 设计

### 架构

```
IMStorage.ConversationStore.recordIncomingMessage(..., db:)
    现有实现已 fetchOne 出 StoredConversation 再 save —— 改为返回 isMuted（或整个更新后的 conversation），不加额外查询。

IMMessaging.ReceiveMessageHandler.persist(...)
    对 direction == .receive && !suppressUnread 且 content 不是 .recalled 的消息，
    收集 (isMuted, isActiveConversation, isGroupNotification) 到批次数组（仿现有 groupNotificationTargets/callEvents 模式）。
    handle(frame:) 事务结束后逐条触发新回调：
        public var onIncomingMessageAlert: ((_ isMuted: Bool, _ isActiveConversation: Bool, _ isGroupNotification: Bool) -> Void)?
    （事务后触发的原因与 onGroupNotificationMessage/onCallStartMessage 相同：GRDB 串行队列不可重入。）

IMMessaging.MessagingService
    透传 onIncomingMessageAlert（仿 onCallStartMessage 的转发方式）。

AppCore.AppEnvironment
    持有/转发该回调给 App 层。

App.MessageAlertPlayer（新增，镜像 CallRingtonePlayer 的写法）
    接收回调 → 按决策表 + 限流判断 → 播放系统提示音 / 纯震动。
    由 SceneDelegate 持有并订阅（类似现有 ringtonePlayer）。
```

职责划分：`IMMessaging` 只判定"这条消息该不该提醒、提醒到哪一档"，不引入 UIKit/AudioToolbox 依赖，保持现有分层（IMMessaging 不依赖 App）。`App.MessageAlertPlayer` 只负责"怎么响/怎么震"和限流，输入只是几个 Bool。

### 限流策略

`MessageAlertPlayer` 内部维护一个全局冷却窗口（leading-edge 节流，非按会话分别计时）：

- 维护 `lastFiredAt: Date?`，窗口 2 秒。
- 收到回调后，若判定结果是"静默"，直接忽略，不影响冷却状态。
- 否则：若距 `lastFiredAt` 不足 2 秒 → 丢弃（不播放，也不更新 `lastFiredAt`，避免连续消息期间被不断续杯导致长时间静默）；否则按决策表播放，并把 `lastFiredAt` 更新为当前时间。
- 已知取舍：窗口期内第一条消息决定这次提醒档位，若窗口内紧接着来了一条更高优先级的消息（如先命中当前会话触发"仅震动"，1 秒内又来了另一会话的消息本该"震动+响铃"），会被这一版简单策略吞掉。按你的要求保持简单实现，不做分会话独立计时。

### 提示音/震动实现

- 震动：`UINotificationFeedbackGenerator(.success)`。**2026-07-15 装机实测后调整**：最初方案用 `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)`（id 4095），实测只有单次统一节奏的"嗡"一下，和微信"动动-动"的双击节奏不一致；`.success` 触感反馈在 Taptic Engine 设备上天然是两下节奏，改用它。"仅震动"和"震动+提示音"两档都用这个触发震动。
- 震动+提示音：在上面的触感反馈基础上，额外 `AudioServicesPlaySystemSound(1007)`（系统 "SMS 收到 1" 三音效），遵循静音拨片。
- 不使用 `AVAudioPlayer`，不设置/强制切换 `AVAudioSession` 类别（`CallRingtonePlayer` 为了循环播放+无视静音拨片才这么做，消息提示音刻意保持系统默认行为以遵循拨片）。

## 不做的事

- 不涉及 APNs/远程推送、不涉及锁屏/后台通知——仅前台（TCP 连接存活期间）。
- 不新增"当前是否在消息主界面/哪个 tab"的状态追踪——已有的 `isActiveConversation` 精确匹配已经足够。
- 不做按会话分别计时的复杂限流，用简单的全局 2 秒窗口。
- 不新增应用内通知设置界面（全局开关/自定义提示音等），沿用现有的会话级"消息免打扰"作为唯一开关。
- 不改变通话铃声（`CallRingtonePlayer`）现有行为。

## 测试

1. `IMMessagingTests`：验证 `ReceiveMessageHandler` 在各输入组合下 `onIncomingMessageAlert` 是否按决策表正确触发/不触发：
   - 普通消息命中当前会话 → 仅震动
   - 普通消息非当前会话且非静音 → 震动+响铃
   - 静音会话消息（命中/不命中当前会话都要静默）
   - `suppressUnreadIncrement == true` 批量拉取期间不触发
   - `.groupNotification` → 仅震动（且遵循静音）
   - `.recalled` → 不触发
   - `direction == .send` 回显 → 不触发
2. `MessageAlertPlayer` 限流逻辑抽成不依赖 UIKit/AudioToolbox 的纯逻辑单元（注入"当前时间"和"播放动作"闭包）单测：验证 2 秒窗口内第二次调用被丢弃、超窗口后恢复触发。
3. 真机人工验证（不通过模拟器）：静音拨片下响铃是否正确静音、实际震动手感、多会话连续消息时的观感、免打扰会话是否完全静默。

## 验证清单（装机手测）

1. 停留在会话列表/联系人/我的 tab 时收到消息 → 震动+响铃。
2. 进入某会话详情页，该会话收到新消息 → 仅震动。
3. 进入会话 A 详情页，会话 B 收到新消息 → 震动+响铃（与不在任何聊天页时一致）。
4. 免打扰会话收到消息 → 完全无反应。
5. 打开静音拨片，非免打扰会话收到消息 → 只震动不响铃。
6. 活跃群聊短时间连续多条消息 → 不连续震动/响铃（2 秒内合并）。
7. 群成员变动通知 → 仅震动，无响铃。
8. 撤回一条消息 → 无任何提醒。
9. 冷启动登录后拉取历史消息 → 无提醒；断线重连补拉消息 → 正常按规则提醒。
