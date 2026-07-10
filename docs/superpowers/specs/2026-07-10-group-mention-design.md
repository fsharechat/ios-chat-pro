# 群聊 @ 提及增强：点头像插入 @ + 选人页 Android 化

日期：2026-07-10
状态：已确认

## 需求

1. 群聊中长按**对方成员**的消息头像，在输入框中插入 `@昵称 `（走现有 mention 状态机，发送时带 `mentionedType=1` / `mentionedTargets`）。长按自己发出消息的头像无任何动作。（2026-07-10 用户调整：由「点击」改为「长按」，为整行长按弹菜单让路——头像手势 0.4s 抢先识别，气泡区长按仍走菜单。）对齐 Android 端行为。
2. 输入框中敲 `@` 弹出的选择群成员页面改为 Android 样式（参考截图）：
   - 成员按昵称拼音首字母分组（A–Z，其余归 `#`），灰色字母 section header；
   - 每行显示成员头像（40pt）+ 昵称，样式与联系人列表一致；
   - 右侧字母索引条，与联系人列表相同的交互；
   - 顶部固定「所有人」入口（独立 section、无字母头、蓝色群组图标），点击即 @所有人（`mentionedType=2`）；
   - 保持现有模态弹出方式 + 导航栏取消按钮，标题「选择群成员」。
3. 列表包含自己（与 Android 一致）。
4. 顺带修复：从 `@` 触发选人后插入结果为 `@@昵称` 的 bug（用户已敲的触发 `@` 未被删除）。

## 设计

### IMKit 改动

- `StoredMessageRow` 新增 `senderUid: String?`：`ConversationViewModel.buildStoredMessageRow` 中，接收方向填 `message.from`，发送方向为 `nil`。
- `ConversationViewModel.groupMemberCandidatesForMention()` 返回值由 `[(uid, displayName)]` 扩为带头像的结构体数组 `[MentionCandidate]`（`uid` / `displayName` / `avatarURL`），头像取 `UserStore` 的 `portrait`。

### App 改动

- **消息 cell（Text/Image/Video/Voice/File/Location 共 6 个）**：给 `senderAvatarImageView` 加 `UITapGestureRecognizer`，暴露 `onAvatarTapped: (() -> Void)?` 回调。
- **ConversationViewController**：dataSource 配置 cell 时绑定 `onAvatarTapped` —— 仅当 `conversationType == .group` 且 `!isOutgoing` 且 `senderUid != nil` 时调用 `inputBar.insertMention(uid:displayName:)`；昵称用行内 `senderDisplayName`，为空时（用户关闭了群昵称显示）按 uid 从 mention 候选里解析。
- **MentionPickerViewController 重写**：
  - 用 `PinyinIndexer.firstLetter(of:)` / `sortKey(for:)` 分组排序，复用联系人页的 diffable dataSource 子类模式（`titleForHeaderInSection` + `sectionIndexTitles` + `sectionForSectionIndexTitle`）；
  - 「所有人」放在第一个 section（标识符为空字符串，不显示 header、不进索引条）；
  - 行 UI 参照 `ContactListCell`：40pt `AvatarImageView` + 16pt 昵称；「所有人」行用 `person.3.fill` 蓝色图标；
  - 回调签名不变（`onPicked(uid?, displayName)`、`onCancelled`）。
- **presentMentionPicker**：`onPicked` 里先 `inputBar.removeTrailingMentionTrigger()` 再 `insertMention`，消除 `@@` bug。头像点击路径不经过触发 `@`，无需删除。

## 不做的事

- 不抽通用「成员选择」组件（转发/建群选人页不动）。
- 不改存储 schema、不改线上协议。
- 不排除自己、不做群主/管理员才可 @所有人 的权限控制（Android 端亦无）。

## 测试

- `swift test --filter IMKitTests`：`groupMemberCandidatesForMention` 返回结构与头像字段、`StoredMessageRow.senderUid` 方向性（收/发）。
- 分组逻辑若在 VC 内则靠手工验证；UI 效果由用户装机验证（模拟器验证按惯例跳过）。

## 验证清单（装机手测）

1. 群聊长按对方头像 → 输入框出现 `@昵称 `，发送后 Android 端收到高亮提醒。
2. 长按自己消息头像 → 无反应；长按气泡 → 仍弹长按菜单。
3. 输入 `@` → 弹出选人页：字母分组、头像、右侧索引、顶部「所有人」。
4. 选人后输入框只有一个 `@`。
5. 单聊长按头像 → 无反应。
