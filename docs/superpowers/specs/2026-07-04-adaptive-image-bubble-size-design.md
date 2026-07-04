# 图片/视频消息气泡按宽高比自适应尺寸 设计

日期：2026-07-04
状态：已确认

## 背景与目标

当前 `ImageMessageCell`/`VideoMessageCell` 的气泡固定 160×160，所有图片/视频消息
无论原始比例都显示成正方形（`scaleAspectFill` 裁切）。对齐微信：气泡按原图宽高比
自适应显示，同时设置最大/最小宽高，避免极端长宽比把气泡撑得过大或挤得过小。

## 尺寸限制

- 最大 200×200pt，最小 80×80pt（已确认）。

## 宽高比来源：不改协议/存储

wire 协议（`Proto/WFCMessage.proto`）和 `StoredMessage`/`ChatMessageRow` 均无宽高
字段，本次不新增——这需要同步 Android 端协议，成本与本次需求不匹配。改为**从已有
缩略图 `Data` 本地 decode 出 `UIImage.size` 直接作为宽高比来源**：缩略图本身就是
按 `ConversationViewController.makeThumbnailData`（`App/ConversationViewController.swift:495-509`，
`maxDimension: 200`）从原图等比缩放生成的 JPEG，比例可信；decode 一张 ≤60KB 小图
的开销可忽略不计，且现有代码本来就要 decode 它来显示（`UIImage(data:)`）。

## 组件设计

### 1. `ImageBubbleSizing`（新增，`Sources/IMKit/ImageBubbleSizing.swift`）

纯几何计算，无 UIKit 依赖，可在 `swift test`（macOS）跑单测：

```swift
public enum ImageBubbleSizing {
    public static let maxWidth: CGFloat = 200
    public static let maxHeight: CGFloat = 200
    public static let minWidth: CGFloat = 80
    public static let minHeight: CGFloat = 80

    /// 无法得知原图尺寸（decode 失败）时的回退尺寸，与本次改动前的固定
    /// 气泡尺寸一致，避免行为断崖式变化。
    public static let fallbackSize = CGSize(width: 160, height: 160)

    /// 按原图宽高比算气泡展示尺寸：
    /// 1. 等比缩放，使其恰好落入 maxWidth×maxHeight 的框内（可放大也可缩小）；
    /// 2. 若结果任一边小于对应下限，等比放大补足下限；
    /// 3. 最后把两边分别夹到 [min, max] 区间内（步骤 2 的放大在极端长宽比下
    ///    可能使另一边超出上限，这里做最终安全夹紧——常规照片/截图的宽高比
    ///    不会触发这个边界，只有极端长图/窄图才会牺牲一点精确比例）。
    public static func displaySize(forNaturalSize naturalSize: CGSize) -> CGSize
}
```

### 2. `ImageMessageCell`（改 `App/ImageMessageCell.swift`）

- `layoutViews()` 里把 `bubbleImageView.widthAnchor.constraint(equalToConstant: 160)` /
  `heightAnchor` 两条常量约束存成 `private var bubbleWidthConstraint: NSLayoutConstraint!` /
  `bubbleHeightConstraint`，激活一次，初始常量随意（会在 `configure` 里覆盖）。
- `configure(with:)` 里 decode 出缩略图 `UIImage` 后：
  ```swift
  let naturalSize = thumbnailImage?.size ?? .zero
  let displaySize = naturalSize == .zero
      ? ImageBubbleSizing.fallbackSize
      : ImageBubbleSizing.displaySize(forNaturalSize: naturalSize)
  bubbleWidthConstraint.constant = displaySize.width
  bubbleHeightConstraint.constant = displaySize.height
  ```
- 气泡尺寸只在这里算一次；Task 2 已实现的原图异步 crossfade 替换只换像素内容，
  **不重新计算尺寸**——`scaleAspectFill` 会裁切吸收缩略图与原图之间的细微比例
  误差，避免消息阅读过程中气泡尺寸跳动。

### 3. `VideoMessageCell`（改 `App/VideoMessageCell.swift`）

- 同样把 `bubbleContainer` 的宽高约束（`App/VideoMessageCell.swift:124-125`）
  改成可变常量，`configure(with:)` 里用 `data.thumbnail` decode 出的 size 走
  同一个 `ImageBubbleSizing.displaySize`。
- `playCircle`（44×44 居中）、`durationLabel`（右下角贴边）都是相对
  `bubbleContainer` 定位，尺寸变化后无需调整约束。

### 4. 不受影响范围

- `LocationMessageCell`（地图截图气泡）——不在本次范围。
- `ImageGalleryViewController`/`ImageZoomPageViewController`——全屏画廊本来
  就是 `scaleAspectFit` 撑满屏幕，与气泡尺寸无关。
- `PendingImageUpload`/`PendingVideoUpload` 走同一个 `configure`/`configurePending`
  入口，自然复用同一套尺寸计算，无需单独处理。

## 数据流

`configure(with:)` → decode 缩略图 `Data` 得 `UIImage` → 取 `.size` →
`ImageBubbleSizing.displaySize(forNaturalSize:)` → 写回 cell 内的宽高约束
`.constant` → self-sizing 的 `UITableViewCell` 自动算出新行高（现有表格未设置
`rowHeight`/`estimatedRowHeight`，依赖约束驱动的 self-sizing，改约束即可让行高
自动跟着变，无需手动 `reloadRows`）。

## 错误处理

- 缩略图 `Data` 为 `nil` 或 decode 失败：`ImageBubbleSizing.fallbackSize`
  (160×160)，与改动前行为一致，不崩溃。
- 极端长宽比（如全景截图）导致下限放大后超过上限：最终夹紧到
  [min, max] 区间，宽高比不再精确但不会溢出气泡的最大边界。

## 测试

- SPM 单测（`Tests/IMKitTests/ImageBubbleSizingTests.swift`）：正方形、横图、
  竖图（对齐用户截图里的竖屏截图场景）、小于下限的小图放大、超过上限的
  大图缩小、极端长宽比的最终夹紧。
- UI 观感（气泡跟随图片实际比例、行高自动跟随）由用户在模拟器/真机验证。
