# 会话列表 + 菜单（发起聊天/添加朋友/扫一扫）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 会话列表右上角 + 按钮从"直接进建群"改为弹出微信样式菜单，三项功能完整落地：发起聊天（1 人单聊 / 多人建群）、添加朋友（复用搜索加好友）、扫一扫（相机 + 相册识码，支持用户码与群码）。

**Architecture:** App 层新增自绘弹层 `PlusMenuView` 与扫码页 `ScanQRCodeViewController`；IMKit 的 `QRCodeContent` 扩展为生成 + 解析双向门面（纯逻辑可单测）；`UserInfoViewController` / `GroupInfoViewController` 改造为双态（好友/陌生人、成员/非成员），入群复用 `GroupSyncService.addMembers`，加好友复用 `ContactSyncService.sendFriendRequest`，陌生资料用 `fetchUserInfo(uids:forceRefresh:)` / `refreshGroup(targetId:)` 远程拉取。所有导航接线在 `SceneDelegate`。

**Tech Stack:** Swift 5.8 / UIKit / AVFoundation(`AVCaptureMetadataOutput`) / PhotosUI(`PHPickerViewController`) / CoreImage(`CIDetector`) / GRDB ValueObservation / XCTest / XcodeGen。

## 已确认决策（grilling 结论）

1. 弹层：**自绘微信样式**（右上角圆角卡片、图标+文字三行、遮罩点击消失、缩放淡入动画、接入现有 `Theme`），不用系统 UIMenu。
2. 发起聊天：**对齐 Android** `CreateConversationActivity` —— 勾选 1 人直接进单聊；≥2 人 `createGroup` 后进群聊。
3. 扫码范围：**user + group**；`pcsession` / `channel` 本期不做；未知码弹框展示原始文本。
4. 群码格式：生成侧改标准前缀 `wildfirechat://group/<groupId>`（收进 `QRCodeContent`）；解析侧**兼容旧 `group:<groupId>` 格式**。
5. 扫码页支持**相册选图识码**（PHPicker + CIDetector）。
6. 扫群码落地：**双态群资料页**（非成员隐藏管理能力、底部"加入群聊"→ `addMembers(自己)`；成员显示"进入群聊"）。
7. 扫用户码落地：**双态用户资料页**（非好友隐藏发消息/视频聊天，显示"添加到通讯录"）。
8. + 菜单**仅放会话列表页**（对齐微信，通讯录已有自己的加好友入口）。

## Global Constraints

- 全部主队列调用，无内部锁（项目线程模型约定）。
- IMKit 不得依赖 UIKit（`swift test` 需在 macOS 编过）；`QRCodeContent` 解析逻辑只用 Foundation。
- 存储只走 `IMStorage` 六个 store 门面；好友判断用 `StoredUser.isFriend`，群成员判断用 `GroupStore.members(groupId:)` 是否含自己 uid。
- 新增/删除 `App/` 文件后必须重跑 `bash Scripts/generate-xcodeproj.sh`（`.xcodeproj` 不手工编辑）。
- App 编译验证：`xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`
- SPM 测试基线有固有失败（见 memory），只看新增测试与既有通过项是否回归。
- 部署目标 iOS 15：扫码用 `AVCaptureMetadataOutput`，不用 VisionKit（iOS 16+）。
- `Info.plist` 已有 `NSCameraUsageDescription`，相册用 PHPicker 无需权限描述。
- 提交信息结尾加 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`；直接在 main 分支开发提交。
- UI 验证由用户自行进行，不驱动模拟器。

---

### Task 1: `QRCodeContent` 双向门面（IMKit 纯逻辑 + 单测）

**Files:**
- Modify: `Sources/IMKit/QRCodeContent.swift`
- Create: `Tests/IMKitTests/QRCodeContentTests.swift`
- Modify: `App/GroupQRCodeViewController.swift`（生成改走门面）

**Interfaces（后续 Task 依赖，签名不可变）:**
- `QRCodeContent.userQRCodeString(uid:) -> String`（已有，保持 `wildfirechat://user/<uid>`）
- 新增 `QRCodeContent.groupQRCodeString(groupId:) -> String` → `wildfirechat://group/<groupId>`
- 新增 `QRCodeContent.parse(_ raw: String) -> ParsedQRCode?`，`public enum ParsedQRCode: Equatable { case user(uid: String), group(groupId: String) }`；识别标准前缀 + 旧 `group:<id>` 格式；其余返回 `nil`（调用方按未知码处理）。

- [ ] Step 1: 写失败测试：标准 user/group 码、旧 `group:` 码、空 uid/groupId 视为无效、未知前缀返回 nil。
- [ ] Step 2: 实现 `groupQRCodeString` 与 `parse`，`swift test --filter IMKitTests` 通过。
- [ ] Step 3: `GroupQRCodeViewController` 生成内容改为 `QRCodeContent.groupQRCodeString(groupId:)`。
- [ ] Step 4: 编译 App target 验证，提交。

### Task 2: `PlusMenuView` 自绘弹层 + 接线

**Files:**
- Create: `App/PlusMenuView.swift`
- Modify: `App/ConversationListViewController.swift`（+ 按钮弹菜单，三个回调闭包 `onStartChatTapped` / `onAddFriendTapped` / `onScanTapped`，原 `onCreateGroupTapped` 由发起聊天流程取代）
- Modify: `App/SceneDelegate.swift`（接线：添加朋友 push 现有 `SearchUserViewController`；发起聊天/扫一扫接 Task 3/4 的入口）
- 重跑 `generate-xcodeproj.sh`

**样式（对齐微信/Android 截图）:** 全屏透明遮罩 + 右上角圆角卡片（约 160pt 宽，锚在导航栏 + 按钮下方），三行图标+文字（SF Symbols 近似：`ellipsis.message` 发起聊天、`person.badge.plus` 添加朋友、`qrcode.viewfinder` 扫一扫），行间分隔线；从右上角锚点缩放+淡入弹出，点遮罩或选项后收起；颜色走 `Theme`（深色模式自动适配）。

- [ ] Step 1: 实现 `PlusMenuView`（show(in:anchor:items:) / dismiss，动画）。
- [ ] Step 2: `ConversationListViewController` 替换 + 按钮行为；"添加朋友"接 `SearchUserViewController`（复用 SceneDelegate 462 行既有构造逻辑，抽成私有工厂方法避免重复）。
- [ ] Step 3: 重跑 XcodeGen、编译验证，提交（此时发起聊天/扫一扫两项可先弹占位或留空闭包，下两个 Task 补上）。

### Task 3: 发起聊天（1 人单聊 / 多人建群）

**Files:**
- Modify: `Sources/IMKit/CreateGroupViewModel.swift`（或视现状加分流逻辑）
- Modify: `App/CreateGroupViewController.swift`（标题按入口变化："发起聊天"；选 1 人不再建群）
- Modify: `App/SceneDelegate.swift`（新回调：单人 → 构造单聊 `ConversationViewController` 并 push；多人建群成功 → push 群聊会话，行为对齐 Android `CreateConversationActivity`）

- [ ] Step 1: ViewModel 增加"完成选择"出口：`selectedUids.count == 1` 时不调 `createGroup`，回调单聊；≥2 走既有建群（若 IMKit 有可测逻辑则补单测）。
- [ ] Step 2: VC/SceneDelegate 接线：单聊直接打开与该 uid 的 Single 会话；建群成功打开群会话（复用现有会话打开路径）。
- [ ] Step 3: 原有其他入口（如仍有直接"创建群聊"入口）行为不回归；编译验证，提交。

### Task 4: `ScanQRCodeViewController` 扫一扫页

**Files:**
- Create: `App/ScanQRCodeViewController.swift`
- Modify: `App/SceneDelegate.swift`（扫码结果分发）
- 重跑 `generate-xcodeproj.sh`

**行为:**
- `AVCaptureSession` + `AVCaptureMetadataOutput`（限 `.qr`），预览层全屏，中间取景框（四角描边 + 周边半透明遮罩），导航栏标题"扫一扫"。
- 相机权限：未授权先 `requestAccess`；拒绝时页面居中提示 + "去设置"按钮（`UIApplication.openSettings`）。
- 右下角"相册"按钮 → `PHPickerViewController` 选图 → `CIDetector(ofType: CIDetectorTypeQRCode)` 识别；识别失败 toast/alert "未发现二维码"。
- 识别成功震动一下、停止 session，回调 `onScanned(String)`；由 SceneDelegate 用 `QRCodeContent.parse` 分发：
  - `.user(uid)` → 先 `fetchUserInfo(uids:[uid], forceRefresh: true)`，push 双态用户资料页（Task 5）。
  - `.group(groupId)` → push 双态群资料页（Task 6）。
  - `nil`（未知码）→ Alert 展示原始文本，确认后恢复扫描。

- [ ] Step 1: 实现扫码页（相机 + 取景框 + 权限态 + 相册识码）。
- [ ] Step 2: SceneDelegate 分发接线（Task 5/6 未完成前可先以 Alert 占位显示解析结果）。
- [ ] Step 3: 重跑 XcodeGen、编译验证，提交。

### Task 5: 双态 `UserInfoViewController`（非好友态）

**Files:**
- Modify: `App/UserInfoViewController.swift`
- Modify: `App/SceneDelegate.swift`（所有既有 push 该页的入口不回归）

**行为:**
- 用 `storage.userStore.user(uid:)` 的 `isFriend` 判定；观察数据库变化（fetchUserInfo 回来后自动刷新）。
- 好友（或自己）：现状不变（发消息/视频聊天）。
- 非好友：隐藏两按钮，显示"添加到通讯录"→ 弹输入申请理由的 Alert（对齐 `SearchUserViewController` 既有交互）→ `sendFriendRequest` → 成功提示"申请已发送"。

- [ ] Step 1: 双态 UI + isFriend 驱动刷新。
- [ ] Step 2: 接线扫码入口；既有好友入口回归检查；编译验证，提交。

### Task 6: 双态 `GroupInfoViewController`（非成员态 + 加入群聊）

**Files:**
- Modify: `Sources/IMKit/GroupInfoViewModel.swift`（新增 `isMember` 状态：members 是否含 myUid；非成员时触发 `refreshGroup` + `refreshMembers` 远程拉取）
- Modify: `App/GroupInfoViewController.swift`（非成员态：隐藏成员网格加減号、群公告编辑、退群等管理项，底部主按钮双态"加入群聊/进入群聊"）
- Modify: `App/SceneDelegate.swift`（扫码入口接线；加入成功 → 打开群会话）

**行为（对齐 Android `GroupInfoActivity`）:**
- 已是成员：按钮"进入群聊"→ 直接打开群会话。
- 非成员："加入群聊"→ `GroupSyncService.addMembers(groupId:, memberIds:[myUid])` → 成功后打开群会话；失败 Alert。
- 非成员本地无群数据：进入即远程拉取，ValueObservation 驱动渲染；拉不到（群不存在）显示错误态。

- [ ] Step 1: ViewModel 增加 isMember 与非成员拉取逻辑（可测部分补单测）。
- [ ] Step 2: VC 双态 UI + 加入流程；既有成员入口回归检查。
- [ ] Step 3: 编译验证，提交。

### Task 7: 收尾验证

- [ ] `swift test`（新增 IMKitTests 全过，基线外无新失败）。
- [ ] `xcodebuild` App scheme 编译通过。
- [ ] 自查清单给用户人工验证：+ 菜单弹出样式/深色模式、1 人单聊、多人建群、搜索加好友、扫 Android 生成的用户码与群码、iOS 新群码 Android 可扫、旧 `group:` 码兼容、相册识码、相机拒权提示。
