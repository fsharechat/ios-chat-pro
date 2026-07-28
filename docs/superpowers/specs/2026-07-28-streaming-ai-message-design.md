# 官方客服流式消息(SAI)接收展示设计

日期:2026-07-28
状态:已确认
参考:android-chat-pro 的 `StreamingAiHandler` / `ChatManager` 流式状态 / `ConversationActivity` 占位气泡设计

## 背景与范围

服务端对官方客服(AI)会话推送流式增量事件:`PUBLISH` 信令 + `SAI`(=40)子信令,
payload 为明文 JSON:`{"i":"streamId","d":"delta","f":done,"t":"客服userId"}`。
Android 端已实现接收展示;iOS 端 `SubSignal.sai` 已在枚举中但无任何处理。

**本次范围:仅做接收展示。** 发送侧不变(给客服发消息就是普通文本消息);
不新增客服入口 UI。流式内容不落库——完整消息由服务端在流结束后走正常
`MN` 通知 → 拉取 → 入库通道下发,占位气泡被真实消息"原位替换"。

## 架构(方案 A:沿现有分层 + 内存态 pending 行模式)

```
IMTransport   SubSignal.sai(已存在,无改动)
IMMessaging   StreamingAiHandler(新)→ MessagingService.activeStream + onSaiToken
IMKit         ConversationViewModel 内存态占位行,publishRows() 拼接
App           TextMessageCell 渲染 ▌ 光标,VC 自动跟底
```

### 1. IMMessaging

**`StreamingAiHandler`(新文件)**
- `canHandle(signal:subSignal:)` = `signal == .publish && subSignal == .sai`
- `handle(frame:)`:`frame.body` 按 UTF-8 解析 JSON,取 `i`/`d`/`f`/`t` 四字段,
  经 `onSaiToken` 闭包上抛;任一字段缺失或非 JSON 时静默丢弃(对齐 Android)

**`MessagingService` 扩展**(对齐 Android `ChatManager` 的流式状态角色)
- `public struct StreamingState { streamId, target, accumulatedText, done }`
- `public private(set) var activeStream: StreamingState?`,状态机与 Android 逐条对齐:
  - `!done && delta.isEmpty && activeStream == nil` → 新建(accumulatedText = "")
  - `!done && !delta.isEmpty && streamId 匹配` → 累积追加
  - `done && streamId 匹配` → 标记 done(保留状态,供会话页替换时清除)
  - 其余(串台 streamId 等)→ 忽略
- `public var onSaiToken: ((_ streamId: String, _ delta: String, _ done: Bool, _ target: String) -> Void)?`
  单监听者,同 Android `setOnSaiTokenListener`
- `public func clearActiveStream()`
- init 中注册 handler,与 `NotifyMessageHandler` 等同列

### 2. IMKit

**`StreamingAiObserving` 协议(新)**:暴露 `onSaiToken` 可写、`activeStream` 可读、
`clearActiveStream()`;`MessagingService` 遵循。

**`ConversationViewModel`**
- 新增可选注入参数 `streaming: StreamingAiObserving?`(同 `remoteHistory` 模式)
- 新增 `ChatMessageRow` case `.streaming(StreamingRow)`,字段:streamId、累积文本、
  done、timestamp;`publishRows()` 末尾拼接(复用 pendingImages 内存态行模式)
- 生命周期(对齐 Android `ConversationActivity`):
  - 仅 `conversationType == .single && token.target == self.target` 时响应
  - 首个空 delta 且无占位行 → 创建占位行
  - delta 非空且 streamId 匹配 → 追加文本、重发布
  - done → 标记完成,**不移除**占位行
  - `handleMessagesUpdate` 检测到 target 发来的新入库消息 → 移除占位行 +
    `clearActiveStream()`(原位替换)
  - init 时若 `streaming.activeStream` 匹配本会话且未完成 → 用累积文本恢复占位行

### 3. App

- `ConversationViewController` 数据源处理 `.streaming` case,复用 `TextMessageCell`:
  - 流式中:文本尾部拼 `▌` 光标,Markdown 每次重渲、不进缓存
  - done 后:去掉光标,走现有 Markdown 缓存渲染路径
  (对齐 Android `TextMessageContentViewHolder`)
- 自动跟底:delta 到达时若用户未主动上滑则滚动到底;用户拖动列表即停止跟底
  (对齐 Android `moveToBottom`)

## 边界情况

| 场景 | 行为 |
|---|---|
| 断线流中断 | 占位行停在最后文本;完整消息经离线拉取到达后照常替换 |
| App 被杀 | 流式态纯内存,无残留 |
| 非当前会话的流 | `MessagingService` 照常累积;进入对应会话时恢复展示 |
| 串台 streamId | 状态机忽略,不影响当前流 |
| 群聊收到 SAI | ViewModel 侧按会话类型过滤,不展示 |

## 测试计划(SPM 单测)

- `StreamingAiHandler`:正常 payload / 缺字段 / 非 JSON / 非 SAI 帧不匹配
- `MessagingService` 状态机:新建 / 累积 / 完成 / 串台忽略 / clear
- `ConversationViewModel`:占位行创建 / 追加 / done 保留 / 真实消息到达替换 /
  init 恢复 / 非本会话不响应

## 修订记录(2026-07-28 装机验证反馈)

1. **占位行头像**:`StreamingRow` 增加 `senderAvatarURL`,创建/恢复时从 `UserStore` 按 target 解析(与真实消息同源),避免占位气泡灰圈。
2. **等待期光标**:`TextMessageCell.setWaitingCursorBlink` 在尚无文本时给 `▌` 加呼吸闪烁;文本开始增长后关闭。
3. **头像对齐**:全部消息 cell 的头像统一与气泡顶部对齐(Text/Location 原 .bottom、Voice/File 原 .center → .top)。
4. **长文交互(替代原"流式中 Markdown 不缓存/正常折叠"设定)**:流式输出全程不折叠、**始终跟底**(去掉近底判定);输出完毕气泡保持全文展开并显示"收起",展开态跨占位行→真实消息替换存续(`expandedMessageIds`);点"收起"后回到缩略+查看全文(旧逻辑)。
