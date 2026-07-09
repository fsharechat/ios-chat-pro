# 文件消息微信风格改造设计

日期：2026-07-09

## 目标

消息列表中的文件消息参考微信设计重做 UI，并支持点击下载到本地、下载后应用内预览与分享。

## 现状

- `App/FileMessageCell.swift`：通用 `doc.fill` SF Symbol 图标 + 名称/大小，气泡按收发方着色（发送方为主题色底），数据靠按空格切分 `row.text` 获取，点击无响应。
- `StoredMessageRow`（`Sources/IMKit/ChatMessageRow.swift`）已有 `fileName`、`fileSize`、`imageRemoteURL`（复用为文件远程地址）。
- 语音消息下载在 `ConversationViewController` 内直接用 `URLSession`，无统一下载器。

## 设计决策（方案 A）

**「已下载」状态不入库，用确定性本地路径表达**：文件下载到
`Documents/Files/<消息标识>/<文件名>`，其中消息标识取 `messageUid`（未 ack 时回退
`localMessageId`，前缀区分避免碰撞）。文件存在即「已下载」。不改 IMStorage schema、
不动 IMKit 层。

被否方案：
- 持久化 `mediaLocalPath` 进 DB：需穿三层，且 iOS 沙盒容器 UUID 变化会使绝对路径失效。
- 每次点击临时下载：无法呈现「未下载/已下载」状态，大文件重复下载体验差。

## 组件

### 1. `App/FileDownloadManager.swift`（新增）

App 层轻量下载器，主队列回调（遵守项目无锁、主队列约定）：

- `localURL(for:)`：由消息行算出确定性本地路径。
- `state(for:)`：`.notDownloaded` / `.downloading(progress)` / `.downloaded(URL)`。
- `download(row:progress:completion:)`：`URLSession downloadTask` + KVO/delegate 进度，
  完成后原子移动到目标路径。同一消息去重（重复点击不重复起任务）。
- 下载目录：`Documents/Files/`，按消息标识分子目录，避免同名文件互相覆盖。

### 2. `App/FileMessageCell.swift`（重写布局与状态）

微信风格白色卡片（收发双方一致）：

- 卡片：白底（暗色模式 `secondarySystemBackground`）、圆角 16、细边框，最大宽度约 240。
- 左侧图标：44×44 圆角矩形色块，内嵌大写扩展名（≤4 字符）白色粗体文字，右上角折角细节。
  配色：PDF 红、DOC/DOCX 蓝、XLS/XLSX 绿、PPT/PPTX 橙、ZIP/RAR/7Z 灰紫、TXT/MD 青灰，
  其余默认灰。
- 右侧文字列：上行文件名（最多 2 行、`byTruncatingMiddle`），
  下行 `74.8 MB 未下载` / `下载中 43%` / `74.8 MB 已下载`（次级颜色小字）。
- 数据源改用 `row.fileName` / `row.fileSize`（`ByteCountFormatter` 格式化），
  删除按空格切 `row.text` 的写法。
- 暴露 `onTapped` 回调，整卡片可点；保留头像/左右对齐逻辑。

### 3. `App/ConversationViewController.swift`（接线）

- dequeue `FileMessageCell` 处设置 `cell.onTapped`：
  - `.notDownloaded` → 调 `FileDownloadManager.download`，进度回调刷新该 cell 状态行；
  - `.downloading` → 忽略（或允许无操作）；
  - `.downloaded(url)` → 弹 `QLPreviewController`（自带分享按钮，可存到「文件」或转发其他 App）。
- VC 持有一个 `FileDownloadManager` 实例；`QLPreviewControllerDataSource` 用小型包装对象提供
  本地 URL。

## 错误处理

- 下载失败：状态回到「未下载」，toast/alert 提示「下载失败」，可再次点击重试。
- 远程 URL 缺失（`imageRemoteURL == nil`）：点击无操作。
- QLPreview 无法预览的类型：QuickLook 自身显示「不支持预览」页，仍可通过分享按钮导出。

## 测试

- UI 与下载行为按项目惯例装机人工验证（发送/接收 PDF、大文件进度、断网失败重试、
  重进会话后仍显示「已下载」、预览与分享）。
- 纯逻辑（扩展名→颜色映射、路径推导）随 cell/manager 实现内聚在 App target，无 SPM 单测覆盖
  （App target 无测试基建，维持现状）。
