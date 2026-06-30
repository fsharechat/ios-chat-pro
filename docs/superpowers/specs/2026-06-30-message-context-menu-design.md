# 消息长按菜单设计文档

**日期**：2026-06-30  
**功能**：聊天详情页消息长按上下文菜单（复制、转发、撤回、删除、保存图片/视频）

---

## 一、菜单触发与展示

### 触发方式

在 `ConversationViewController` 实现 `UITableViewDelegate.tableView(_:contextMenuConfigurationForRowAt:point:)`：

- `previewProvider` 返回 `nil`：无气泡预览、无全屏模糊，效果与 iOS 系统短信长按一致（菜单在消息附近弹出）
- `menuProvider` 根据 row 类型动态构建 `UIMenu`

**不响应长按**的 row 类型：`.pendingImage`、`.pendingVideo`、`.systemTip`、`.timeHeader`

### 菜单项与出现条件

| 操作 | 出现条件 |
|------|----------|
| 复制 | `message.text != nil`（文本消息） |
| 转发 | 所有 `.message` 类型 |
| 撤回 | 见撤回规则 |
| 删除 | 所有 `.message` 类型 |
| 保存图片 | `message.imageThumbnail != nil && message.videoDuration == nil` |
| 保存视频 | `message.videoDuration != nil` |

菜单项顺序固定：复制 → 转发 → 撤回 → 删除 → 保存图片 → 保存视频（不满足条件的项不加入）。

### 撤回规则

- **单聊**：`message.isOutgoing == true`
- **群聊**：`message.isOutgoing == true` 或当前用户在该群的 `memberType` 为 `.manager` / `.owner`

逻辑封装在 `ConversationViewModel.canRecall(row: StoredMessageRow) -> Bool`，内部调 `storage.groups.members(groupId:)` 查当前用户角色。

---

## 二、撤回实现

### 协议（对齐 Android `recallMessage`）

```
Client → Server:  PUBLISH / MR  body = Im_INT64Buf { id: messageUid }
Server → Client:  PUB_ACK / MR  body = 1 byte errorCode（0 = 成功）
```

等服务端确认后再更新本地，不做乐观更新。

### 新增类与方法

| 位置 | 新增 |
|------|------|
| `IMMessaging/RecallAckHandler` | 处理 `PUB_ACK/MR`，读 1 字节 errorCode，按 wireMessageId 找回调并 fire |
| `MessagingService` | 内部维护 `[UInt16: (Bool)->Void]` 待确认表；注册 `RecallAckHandler` |
| `MessagingService` | `func recall(messageUid: Int64, storageId: Int64, completion: @escaping (Bool)->Void)` |
| `MessageSending` 协议 | `func recall(messageUid: Int64, storageId: Int64, completion: @escaping (Bool)->Void)` |
| `ConversationViewModel` | `func recallMessage(row: StoredMessageRow, completion: @escaping (Bool)->Void)` |

### 成功回调逻辑

```swift
// MessagingService.recall 成功回调内：
storage.messages.updateContent(id: storageId, content: .recalled(operatorId: currentUserId))
storage.conversations.touchConversation(conversationType:, target:, line:)
```

失败时 `ConversationViewController` 弹 `UIAlertController` 提示「撤回失败」。

---

## 三、删除实现（本地删除）

### 新增

| 位置 | 新增 |
|------|------|
| `MessageStore` | `func deleteMessage(id: Int64) throws` — 删除单行 + `touchConversation` |
| `ConversationViewModel` | `func deleteMessage(row: StoredMessageRow)` |

删除前在 `ConversationViewController` 弹 `UIAlertController` 二次确认（「删除后无法恢复，确认删除？」）。

---

## 四、转发实现

### 流程

```
点「转发」
  → push ForwardPickerViewController
    → 用户选中会话
      → present ForwardPreviewViewController（sheet）
        → 点「发送」
          → sendForwardedMessage() + 可选 sendText(note)
          → dismiss + pop
```

### ForwardPickerViewController

- 复用 `ConversationListViewModel` + `ConversationListCell`
- 顶部 `UISearchBar`，过滤 `rows.displayName`
- 回调：`onPicked: (ConversationRow) -> Void`

### ForwardPreviewViewController

自定义 VC，`modalPresentationStyle = .pageSheet`（iOS 15+ 半屏）：

- **顶部**：「发送给：[头像] [会话名]」
- **中部**：消息内容缩略预览
  - 文本：截断前 50 字
  - 图片/视频：显示缩略图（`imageThumbnail`）
  - 语音/文件/位置：类型 icon + 简短文字描述
- **底部**：`UITextField`（placeholder「给朋友留言」）+ 取消 / 发送按钮

### 发送逻辑

在 `ConversationViewController` 注入 `MessageSending` 直接发送，无需新建 `ConversationViewModel`：

| 消息类型 | 转发调用 |
|----------|----------|
| 文本 | `sendText(to:text:)` |
| 图片 | `sendImage(to:thumbnail:remoteURL:)` |
| 视频 | `sendVideo(to:thumbnail:remoteURL:duration:)` |
| 语音 | `sendVoice(to:remoteURL:duration:)`（需 `voiceDuration` 字段） |
| 文件 | `sendFile(to:name:size:remoteURL:)` |
| 位置 | `sendLocation(to:lat:lng:title:thumbnail:)` |

若留言非空，额外调一次 `sendText(to: target, text: note)`。

### StoredMessageRow 新增字段

`voiceDuration: Int?`（语音时长，`ConversationViewModel.makeRow` 的 `.voice` case 中赋值）。  
文件转发还需 `fileSize: Int?` 和 `fileName: String?` 字段（从 `[文件]` 前缀文本解析不可靠，应直接存储）。

---

## 五、保存图片 / 保存视频

均在 `ConversationViewController` 中处理，需 `PHPhotoLibrary` 权限（`NSPhotoLibraryAddUsageDescription`）：

- **保存图片**：下载 `imageRemoteURL` → `PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: uiImage) }`
- **保存视频**：下载 `imageRemoteURL` 到临时文件 → `PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL:)`

下载期间展示 `UIActivityIndicatorView`，成功/失败后 Toast 提示。

---

## 六、不涉及的变更

- 不新增网络层（转发复用已有 `sendImage/sendVideo/sendText` 等）
- 不修改 `ConversationStore` schema
- `MessageStore.deleteMessage` 仅删本地行，不向服务端发送任何请求

---

## 七、文件变更清单

| 文件 | 变更类型 |
|------|----------|
| `Sources/IMStorage/MessageStore.swift` | 新增 `deleteMessage(id:)` |
| `Sources/IMKit/ChatMessageRow.swift` | `StoredMessageRow` 新增 `voiceDuration`、`fileSize`、`fileName` |
| `Sources/IMKit/MessageSending.swift` | 协议新增 `recall(messageUid:storageId:completion:)` |
| `Sources/IMKit/ConversationViewModel.swift` | 新增 `canRecall`、`recallMessage`、`deleteMessage` |
| `Sources/IMMessaging/MessagingService.swift` | 实现 `recall`；注册 `RecallAckHandler` |
| `Sources/IMMessaging/RecallAckHandler.swift` | 新建：处理 `PUB_ACK/MR` |
| `App/ConversationViewController.swift` | 实现 `contextMenuConfigurationForRowAt`；接入保存图片/视频 |
| `App/ForwardPickerViewController.swift` | 新建：会话选择列表 |
| `App/ForwardPreviewViewController.swift` | 新建：转发预览 + 留言 |
