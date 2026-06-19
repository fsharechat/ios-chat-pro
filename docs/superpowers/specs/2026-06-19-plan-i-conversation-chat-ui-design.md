# Plan I: 单聊(1:1)聊天界面 — 设计文档

**状态:** 已与用户确认,待写实施计划。

## 目标

实现单聊(1:1)的聊天界面:文字+图片消息的收发与展示、下拉加载更多历史消息、发送失败后点击重试、图片消息点击全屏预览。这是 `ConversationListViewController`(Plan G)点击某个会话后跳转到的真正聊天页面,替换掉目前的占位实现(`App/ConversationViewController.swift` 当前只显示一行提示文字)。

复用已有的:
- `MessagingService`(Plan D/F)——`sendText`/`sendImage(thumbnail:remoteURL:)`,内部已处理本地回显行插入 + ack 状态更新。
- `MediaUploadService`(Plan H)——`uploadImage(_:completion:)`,生成 MinIO 预签名 URL 并 PUT 图片字节,返回最终 `remoteURL`。
- `AvatarImageView`/`AvatarLoading`(已有)——消息列表头像、全屏预览原图加载都复用同一套网络加载逻辑。
- `Theme`(已有)——深色/浅色双主题色值、气泡圆角等。

**明确不在本计划范围内:** 群聊(多人会话/`line` 扩展)、@提醖、消息撤回、语音/视频消息、已读/在线状态、表情贴纸——这些都是后续计划(或更晚的 Phase)的范围。

## 架构

不新增 SwiftPM target——这一层是 UIKit 相关的展示代码,和 `ConversationListViewController` 一样直接放在 `App/` 目录下,通过 `AppEnvironment` 已经构造好的 `messagingService`/`mediaUploadService`/`storage` 访问业务层。`Sources/IMStorage/MessageStore.swift` 需要新增两个查询方法(见下)。

## 数据层:`MessageStore` 新增能力

当前 `MessageStore.messages(conversationType:target:line:limit:)` 只能取最新 N 条,没有"加载更多"的游标,也没有 Combine publisher(`ConversationStore`/`UserStore` 都有 `xxxPublisher()`,`MessageStore` 没有——这是 Plan H 阶段就发现、登记为已知缺口的部分)。

新增两个方法:

1. **`messagesPublisher(conversationType:target:line:limit:) -> AnyPublisher<[StoredMessage], Error>`** —— 基于 `ValueObservation.tracking { ... }.publisher(in: dbQueue, scheduling: .immediate)` 的响应式查询(与 `ConversationStore.conversationsPublisher()`/`UserStore` 现有的 publisher 同一种实现方式),返回"最新 `limit` 条"消息(按 `timestamp` 降序取 `limit` 条后,在 Swift 侧或 SQL 侧转回升序输出,保证调用方拿到的是时间升序数组)。任何插入(新发的/收到的消息)或更新(ack 状态变化)都会自动重新推送整个结果集。用于聊天界面的实时主视图。

2. **`olderMessages(conversationType:target:line:before: StoredMessage, limit:) throws -> [StoredMessage]`** —— 一次性(非响应式)查询,取严格早于锚点消息的更早历史,按 `(timestamp, id)` 复合排序/比较作为分页游标(单纯按 `timestamp` 分页在同一毫秒有多条消息时会丢数据或重复;`id` 是 GRDB 自增主键,同一毫秒内天然保序)。返回同样按时间升序排列的数组。用于聊天界面下拉到顶部时的"加载更多"。

**为什么拆成两个方法而不是让 `messagesPublisher` 的 `limit` 动态增长:** 旧历史消息基本不会再变(已经是 `.sent`/收到状态,不会再被更新),只有最近这一段需要保持响应式;让一个 `ValueObservation` 的查询参数随用户滚动动态变化,需要不断重建 observation,徒增复杂度且没有实际收益。响应式"尾部" + 一次性"翻页历史"的拆分是更简单、更符合实际访问模式的方案。

ViewModel 内部维护一个内存数组,把 `messagesPublisher` 推送的最新一页和 `olderMessages` 加载进来的历史页合并、去重(按 `id`)后渲染,按 `timestamp`/`id` 排序。

## 发送流程

**文字消息:** 直接调用 `MessagingService.sendText(to:conversationType:line:text:)`——它内部已经会先插入一条 `.sending` 状态的本地回显 `StoredMessage` 行,发送后通过 ack 更新为 `.sent`/`.sendFailure`。ViewModel 不需要自己做任何"乐观更新"逻辑,UI 完全靠 `messagesPublisher` 的自动推送来反映这条新行及其后续状态变化。

**图片消息(用户已确认:立即显示气泡,后台上传):**
1. 用户通过 `PHPickerViewController` 选完图片后,ViewModel 生成本地缩略图(等比缩放到较小尺寸的 JPEG Data),创建一个**纯内存态**的 `PendingImageUpload`(本地缩略图 `Data` + 状态:`.uploading`/`.failed`),追加到 ViewModel 自己维护的渲染数组里——UI 立刻显示这条气泡。这条记录**不写入 `IMStorage`**:这时还没有 `remoteURL`,写进数据库会出现"消息已经在本地数据库但其实还没真正发出/还不知道最终远程地址"的歧义状态,且与 `MediaUploadService` 不依赖 `IMStorage` 的既定架构边界(Plan H)冲突。
2. ViewModel 调用 `MediaUploadService.uploadImage(fullImageData) { result in ... }`(完整原图,不是缩略图——缩略图只用于本地气泡展示和最终存入 `StoredMessage.mediaThumbnail`)。
3. **成功:** 拿到 `remoteURL` 后,调用 `MessagingService.sendImage(to:conversationType:line:thumbnail:remoteURL:)`(它会真正插入 `StoredMessage` 并走正常的发送 + ack 流程),然后把第 1 步那条内存态占位行从渲染数组里移除——`messagesPublisher` 这时会自动推送出真正的那一行,在 UI 上无缝替换掉占位气泡(由于上传通常需要几秒,用户几乎不会察觉到这次替换的瞬间)。
4. **失败**(上传失败,或者真实消息发出后 ack 返回失败导致 `.sendFailure`):气泡上显示"重试"图标。点击占位气泡的重试:重新走一遍第 2 步的上传。点击真实消息(已经在 `IMStorage` 里、状态为 `.sendFailure`)的重试:目前 `MessagingService` 没有现成的"重发已存在的行"方法,需要在 `MessagingService` 或 ViewModel 层新增一个轻量的重发入口(直接复用该行已有的 `content`,重新走一次 `sendFrame`+`tracker.track`,更新同一行的状态,而不是插入新行)。

## UI 组件与交互细节

- **消息列表:** `UITableView`(与 `ConversationListViewController` 同一套技术栈:UIKit + MVVM + Combine),消息按时间正序排列(旧→新),新消息插入到底部并 `scrollToBottom(animated:)`;`scrollViewDidScroll`检测接近顶部时触发"加载更多历史"(调用 `olderMessages`),加载完成后保持当前可视内容的相对滚动位置不跳动(常见做法:记录加载前 `contentSize.height`,插入数据后用差值调整 `contentOffset`)。
- **两种 cell:**
  - `TextMessageCell`:气泡样式,自己发的消息气泡用 `Theme.accent`、靠右对齐,对方发的用 `Theme.incomingBubble`、靠左对齐(对齐方向由 `StoredMessage.direction` 决定)。
  - `ImageMessageCell`:展示 `mediaThumbnail`(或上传中占位图的本地缩略图),上传中显示进度态遮罩,失败显示重试按钮覆盖层。
- **图片选择:** 用 `PHPickerViewController`(iOS 14+ 系统相册选择器,不需要完整相册读取权限弹窗,比旧的 `UIImagePickerController` 更现代,符合本项目"优先用现代系统 API"的一贯取向)。
- **图片全屏预览:** 点击图片气泡,`present` 一个极简的全屏页面(`UIImageView` + 双击/手势缩放 + 下滑或点击关闭),用气泡里已有的 `remoteURL`(若图片还在上传中、`remoteURL` 还不存在,则直接展示本地缩略图,不触发网络加载)异步加载原图,复用 `AvatarLoading` 同款的网络加载逻辑(不新增下载组件)。
- **输入栏:** 底部固定的输入条——自增高文字输入框(单行到多行)、图片按钮、发送按钮,随键盘升降调整位置。严格复刻 `Theme`/`ConversationListViewController` 已有的深色/浅色双主题样式约定。
- **头像:** 消息列表里每条消息旁的头像复用已有的 `AvatarImageView`/`AvatarLoading`,不重新实现。

## 测试策略

- `MessageStore` 新增的两个查询方法:单元测试用 GRDB 内存库,覆盖响应式推送(插入新消息后 publisher 重新推送)、分页游标的边界情况(同一毫秒多条消息、`limit` 边界、空历史)。
- `ConversationViewModel`(新建,MVVM 核心):单元测试覆盖发送文字/图片成功与失败路径、`PendingImageUpload` 占位行到真实行的替换逻辑、加载更多历史的合并去重逻辑。沿用本项目已确立的测试组装方式——真实 `IMClient` + 本地测试专用 `FakeTransportConnection`(每个测试 target 各自一份拷贝的既定惯例)+ 真实 `MessagingService`/`MediaUploadService`/`IMStorage`,异步断言用 `XCTestExpectation`+`wait(for:timeout:)`(与本项目所有 Combine ViewModel 测试一致,因为 `ValueObservation.publisher(in:scheduling:.immediate)` 只保证第一次同步,后续推送是异步的)。
- UI 层(`UIViewController`/`UITableViewCell`/输入栏组件)只做编译期验证 + 模拟器手动验证(若环境允许 `simctl install`),不强行写 snapshot/UI 自动化测试——与本项目目前所有 `*ViewController` 的既定取向一致。

## 文件结构(预计新增/修改)

- 修改:`Sources/IMStorage/MessageStore.swift`(新增 `messagesPublisher`/`olderMessages`)+ 对应测试文件
- 替换:`App/ConversationViewController.swift`(去掉占位实现,接入真正的聊天界面)
- 新建:`App/ConversationViewModel.swift` + 测试
- 新建:`App/TextMessageCell.swift`
- 新建:`App/ImageMessageCell.swift`
- 新建:`App/ImagePreviewViewController.swift`
- 新建:`App/MessageInputBar.swift`

## 自查

- **无占位/待补全内容:** 以上每一节都给出了具体的方法签名、状态机和文件路径,没有"TODO 稍后补充"。
- **内部一致性:** 发送流程一节与数据层一节的接口名称(`messagesPublisher`/`olderMessages`)、`MessagingService`/`MediaUploadService` 的既有方法签名(已在 Plan D/F/H 中确认过,这里直接引用,不重复定义)互相一致。
- **范围聚焦:** 仅覆盖单聊场景;群聊/语音视频/已读状态等明确排除,留给后续计划。
- **歧义点已收敛为明确选择:** 图片发送的"立即显示气泡 vs 上传完成后才显示"已由用户选定为前者;三个可选功能(分页加载历史、失败重试、图片全屏预览)均已确认包含在本次范围。
