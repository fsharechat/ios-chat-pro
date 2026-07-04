# 图片消息：气泡原图异步加载 + 画廊浏览 设计

日期：2026-07-04
状态：已确认

## 背景与目标

当前图片消息气泡始终只显示 wire 里携带的缩略图（`imageThumbnail`），从不加载
`imageRemoteURL` 指向的原图；点击后的 `ImagePreviewViewController` 是单图预览，
不能左右滑动浏览会话内其他图片，也没有下拉关闭手势。对齐 Android 端行为：

1. 气泡先显示缩略图，消息显示到屏幕时异步加载原图，成功后替换显示。
2. 点击图片进入全屏画廊，左右滑动浏览该会话内所有图片消息。
3. 手指向下拖动关闭画廊。

画廊范围：**仅图片消息**（不含视频，用户已确认）。

## 组件设计

### 1. `ImageLoader`（新增，`Sources/IMKit/ImageLoader.swift`）

- 接口与 `AvatarLoading` 同风格：
  `protocol ImageLoading { func loadImageData(from urlString: String) async -> Data? }`
  返回 `Data` 而非 `UIImage`，保持 IMKit 可在 macOS 下 `swift test`。
- 两级缓存：内存 `NSCache<NSString, NSData>` + 磁盘
  `Caches/ImageCache/<SHA256(urlString)>`。消息中存储的 `remoteMediaUrl`
  是上传后固定不变的 URL，可安全作为缓存 key。
- 读取顺序：内存 → 磁盘（命中则回填内存）→ 网络（200 才落盘 + 回填内存）。
- 与代码库线程约定一致：不加内部锁，从主队列调用；NSCache 单次操作自身线程
  安全，磁盘写入用 `Data.write(to:options:.atomic)`。并发重复下载与
  `AvatarLoader` 一样接受为已知权衡。
- 不采用 URLCache 方案：MinIO 响应头缓存策略不可控，自管磁盘缓存更可靠。

### 2. 气泡内异步原图（改 `App/ImageMessageCell.swift` + `ConversationViewController`）

- `ImageBubbleData` 增加 `remoteURL: String?`。
- cell `configure` 时先显示缩略图；`remoteURL` 非空则通过注入的 `ImageLoading`
  异步加载，成功后 0.2s crossfade 换成原图。
- 复用竞态防护：cell 记录当前绑定 URL，回调时不匹配则丢弃。
- 气泡尺寸维持 160×160 aspectFill 不变，只替换内容。

### 3. `ImageGalleryViewController`（新增，替换 `ImagePreviewViewController`）

- 结构：`UIPageViewController`（`.scroll`、横向、页间距 16pt）+ 每页一个
  `ImageZoomPageViewController`。
- 每页：沿用现有缩放逻辑（双击切换 1x/放大、捏合 1–4x），先显示缩略图，
  异步经 `ImageLoader` 加载原图后替换。
- 数据：`struct GalleryItem { thumbnail: Data?; remoteURL: String? }`。
  `ConversationViewController` 点击图片时从当前 rows 过滤出全部图片消息
  （含发送中的 pending 图片，其 remoteURL 为 nil），组装数组 + 起始下标，
  全屏 present。
- 下拉关闭：根视图 `UIPanGestureRecognizer`，仅当前页 `zoomScale == 1` 时
  响应；拖动时图片跟手位移并按比例缩小、黑色背景 alpha 随位移渐变；
  松手位移超约 100pt 或向下速度较大则 dismiss，否则动画弹回。
- 顶部居中 “n / m” 页码标签；保留右上角关闭按钮。
- 旧 `ImagePreviewViewController` 删除，调用点改为新画廊。

## 数据流

点击气泡 → VC 过滤 rows 得 `[GalleryItem]` + index → present 画廊
→ 翻页时各页独立走 ImageLoader（内存/磁盘命中即秒开）。

## 错误处理

- 原图加载失败：气泡与画廊页均保持缩略图显示，不弹错误（与 Android 一致，
  下次显示时自然重试）。
- URL 无效 / 非 200：`ImageLoader` 返回 nil，不落缓存。

## 测试

- SPM 单测（`Tests/IMKitTests`）：ImageLoader 磁盘缓存写读、内存回填、
  非 200 不缓存、缓存 key 稳定性。
- UI 行为（气泡替换、翻页、下拉关闭）由用户在模拟器/真机验证。
