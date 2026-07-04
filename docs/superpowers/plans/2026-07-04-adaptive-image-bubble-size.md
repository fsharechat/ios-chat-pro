# 图片/视频消息气泡按宽高比自适应尺寸 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 图片/视频消息气泡不再固定 160×160 正方形，改为按原图宽高比自适应，最大 200×200pt、最小 80×80pt。

**Architecture:** IMKit 新增纯几何函数 `ImageBubbleSizing.displaySize(forNaturalSize:)`（无 UIKit 依赖，可测）；`ImageMessageCell`/`VideoMessageCell` 把气泡的固定宽高约束改成可变常量，`configure` 时用缩略图 decode 出的 `UIImage.size` 调用该函数算出目标尺寸并写回约束。

**Tech Stack:** Swift 5.8 / UIKit / CoreGraphics(`CGSize`) / XCTest / XcodeGen。

**Spec:** `docs/superpowers/specs/2026-07-04-adaptive-image-bubble-size-design.md`

## Global Constraints

- 最大 200×200pt、最小 80×80pt（spec 已确认）。
- 无法得知原图尺寸（decode 失败）时回退 160×160，与改动前行为一致，不崩溃。
- IMKit 不得依赖 UIKit（`swift test` 要在 macOS 编过），几何函数只用 `CoreGraphics`/`Foundation`。
- 气泡尺寸只在 `configure` 时按缩略图算一次，Task 2 已实现的原图异步 crossfade 替换**不重新计算尺寸**——只换像素内容。
- App 编译验证命令：`xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`
- `.xcodeproj` 由 XcodeGen 生成，不手工编辑（本计划只改 App/ 现有文件与 IMKit 新文件；IMKit 是 SPM target，改动 IMKit 不需要重生成 xcodeproj，只有新增/删除 App/ 文件时才需要——本计划不新增/删除 App/ 文件）。
- 提交信息结尾加 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 项目惯例：直接在 main 分支开发提交。
- `LocationMessageCell`、`ImageGalleryViewController`/`ImageZoomPageViewController` 不在本次改动范围内。

---

### Task 1: `ImageBubbleSizing`（IMKit 纯几何计算 + 单测）

**Files:**
- Create: `Sources/IMKit/ImageBubbleSizing.swift`
- Test: `Tests/IMKitTests/ImageBubbleSizingTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces（Task 2/3 依赖，签名必须一字不差）:
  - `public enum ImageBubbleSizing { public static let maxWidth: CGFloat; public static let maxHeight: CGFloat; public static let minWidth: CGFloat; public static let minHeight: CGFloat; public static let fallbackSize: CGSize; public static func displaySize(forNaturalSize naturalSize: CGSize) -> CGSize }`

- [ ] **Step 1: 写失败测试**

创建 `Tests/IMKitTests/ImageBubbleSizingTests.swift`：

```swift
import XCTest
@testable import IMKit

final class ImageBubbleSizingTests: XCTestCase {
    func test_displaySize_squareWithinBounds_keepsNaturalSize() {
        // 100x100 正方形,已经落在 [80,200] 区间内,不放大也不缩小,原样使用
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 100, height: 100))

        XCTAssertEqual(result, CGSize(width: 100, height: 100))
    }

    func test_displaySize_wideImage_scalesDownPreservingAspectRatio() {
        // 800x400,横向 2:1,缩到 200 宽后高 100,均在 [80,200] 区间内,直接采用
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 800, height: 400))

        XCTAssertEqual(result, CGSize(width: 200, height: 100))
    }

    func test_displaySize_tallScreenshot_scalesDownPreservingAspectRatio() {
        // 竖屏截图 900x1600(9:16),缩到高 200 后宽 112.5,均在 [80,200] 区间内
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 900, height: 1600))

        XCTAssertEqual(result.height, 200, accuracy: 0.01)
        XCTAssertEqual(result.width, 112.5, accuracy: 0.01)
    }

    func test_displaySize_tinyImage_growsUpToMinFloor() {
        // 40x40 正方形,小于下限 80,等比放大到 80x80
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 40, height: 40))

        XCTAssertEqual(result, CGSize(width: 80, height: 80))
    }

    func test_displaySize_largeSquare_scalesDownToMaxBox() {
        // 2000x2000,缩到 200x200
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 2000, height: 2000))

        XCTAssertEqual(result, CGSize(width: 200, height: 200))
    }

    func test_displaySize_extremeAspectRatio_isClampedToMaxOnBothAxes() {
        // 极端长图 2000x100(20:1),先等比缩到宽 200 时高只有 10,远小于下限 80;
        // 放大补足下限会让宽超过 200,最终两边都夹到上限 200x200(牺牲精确比例)
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 2000, height: 100))

        XCTAssertLessThanOrEqual(result.width, 200)
        XCTAssertLessThanOrEqual(result.height, 200)
        XCTAssertGreaterThanOrEqual(result.width, 80)
        XCTAssertGreaterThanOrEqual(result.height, 80)
    }

    func test_fallbackSize_is160x160() {
        XCTAssertEqual(ImageBubbleSizing.fallbackSize, CGSize(width: 160, height: 160))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ImageBubbleSizingTests`
Expected: 编译失败，`cannot find 'ImageBubbleSizing' in scope`。

- [ ] **Step 3: 最小实现**

创建 `Sources/IMKit/ImageBubbleSizing.swift`：

```swift
import CoreGraphics

/// 图片/视频消息气泡按原图宽高比算展示尺寸——对齐微信风格：不再固定
/// 正方形,而是在 [min, max] 区间内保持原图比例。缩略图 Data decode 出的
/// UIImage.size 即为"原图宽高比"来源(缩略图本身就是原图等比缩放生成的
/// JPEG,比例可信),App 层负责 decode,这里只做纯几何计算,不依赖 UIKit
/// 以便在 macOS 上 `swift test`。
public enum ImageBubbleSizing {
    public static let maxWidth: CGFloat = 200
    public static let maxHeight: CGFloat = 200
    public static let minWidth: CGFloat = 80
    public static let minHeight: CGFloat = 80

    /// 无法得知原图尺寸(decode 失败)时的回退尺寸,与本次改动前的固定气泡
    /// 尺寸一致,避免行为断崖式变化。
    public static let fallbackSize = CGSize(width: 160, height: 160)

    /// 1. 若原图超出 maxWidth×maxHeight 的框,等比缩小到刚好落入框内;在框内的
    ///    图片不做处理(不会为了"填满气泡"而人为放大,避免模糊);
    /// 2. 若结果任一边小于对应下限,等比放大补足下限;
    /// 3. 最后把两边分别夹到 [min, max] 区间内 —— 步骤 2 的放大在极端长宽比
    ///    下可能使另一边超出上限,这里做最终安全夹紧(常规照片/截图的宽高比
    ///    不会触发这个边界,只有极端长图/窄图才会牺牲一点精确比例)。
    public static func displaySize(forNaturalSize naturalSize: CGSize) -> CGSize {
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            return fallbackSize
        }

        // `, 1` 封顶:只允许缩小,不允许这一步把小图强行放大去填满 max 框。
        let fitScale = min(maxWidth / naturalSize.width, maxHeight / naturalSize.height, 1)
        var width = naturalSize.width * fitScale
        var height = naturalSize.height * fitScale

        let growScale = max(minWidth / width, minHeight / height, 1)
        width *= growScale
        height *= growScale

        width = min(max(width, minWidth), maxWidth)
        height = min(max(height, minHeight), maxHeight)

        return CGSize(width: width, height: height)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ImageBubbleSizingTests`
Expected: 7 个测试全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/ImageBubbleSizing.swift Tests/IMKitTests/ImageBubbleSizingTests.swift
git commit -m "feat(IMKit): ImageBubbleSizing 按原图宽高比算气泡展示尺寸

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `ImageMessageCell` 气泡按宽高比自适应

**Files:**
- Modify: `App/ImageMessageCell.swift`

**Interfaces:**
- Consumes: Task 1 的 `ImageBubbleSizing.displaySize(forNaturalSize:) -> CGSize` 与 `ImageBubbleSizing.fallbackSize: CGSize`。
- Produces: 无（叶子改动，`ConversationViewController` 调用点不变）。

- [ ] **Step 1: 把气泡的固定宽高约束改成可变常量**

`App/ImageMessageCell.swift:28-40` 的属性区块，在 `currentRemoteURL` 声明后加两个约束属性：

```swift
    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?
    /// 复用竞态防护：异步原图回来时若 cell 已被复用绑定到别的 URL，丢弃结果。
    private var currentRemoteURL: String?
    /// 气泡宽高按原图比例算出后写回这两个约束的 constant（layoutViews 里
    /// 激活一次，之后每次 configure 只改 constant，不重新创建约束）。
    private var bubbleWidthConstraint: NSLayoutConstraint!
    private var bubbleHeightConstraint: NSLayoutConstraint!
```

`App/ImageMessageCell.swift:104-105` 原来的：

```swift
            bubbleImageView.widthAnchor.constraint(equalToConstant: 160),
            bubbleImageView.heightAnchor.constraint(equalToConstant: 160),
```

改为先赋值到属性、再纳入 `NSLayoutConstraint.activate`。整个 `layoutViews()` 里的 `NSLayoutConstraint.activate([...])` 调用（`App/ImageMessageCell.swift:95-109`）改为：

```swift
        bubbleWidthConstraint = bubbleImageView.widthAnchor.constraint(equalToConstant: ImageBubbleSizing.fallbackSize.width)
        bubbleHeightConstraint = bubbleImageView.heightAnchor.constraint(equalToConstant: ImageBubbleSizing.fallbackSize.height)

        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),

            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            bubbleWidthConstraint,
            bubbleHeightConstraint,

            activityIndicator.centerXAnchor.constraint(equalTo: bubbleImageView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: bubbleImageView.centerYAnchor),
        ])
```

- [ ] **Step 2: `configure(with:)` 里按缩略图尺寸算气泡展示尺寸**

`App/ImageMessageCell.swift:112-118` 现状：

```swift
    func configure(with data: ImageBubbleData) {
        let showsSender = !data.isOutgoing && data.senderDisplayName != nil

        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? data.senderDisplayName : nil

        bubbleImageView.image = data.thumbnail.flatMap { UIImage(data: $0) }
        currentRemoteURL = data.remoteURL
```

改为（`thumbnailImage` 复用一次 decode 结果，既用于显示又用于取尺寸；尺寸计算和写回约束紧跟其后）：

```swift
    func configure(with data: ImageBubbleData) {
        let showsSender = !data.isOutgoing && data.senderDisplayName != nil

        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? data.senderDisplayName : nil

        let thumbnailImage = data.thumbnail.flatMap { UIImage(data: $0) }
        bubbleImageView.image = thumbnailImage
        currentRemoteURL = data.remoteURL

        let displaySize = thumbnailImage.map { ImageBubbleSizing.displaySize(forNaturalSize: $0.size) }
            ?? ImageBubbleSizing.fallbackSize
        bubbleWidthConstraint.constant = displaySize.width
        bubbleHeightConstraint.constant = displaySize.height
```

其余 `configure(with:)` 内容（`remoteURL` 异步加载原图、`activityIndicator`、`rowStack` 重排等，`App/ImageMessageCell.swift:119-156`）不变——原图 crossfade 只换 `bubbleImageView.image`，不触碰约束，气泡尺寸保持缩略图算出的值不变。

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App/ImageMessageCell.swift
git commit -m "feat(App): 图片消息气泡按原图宽高比自适应尺寸

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `VideoMessageCell` 气泡按宽高比自适应

**Files:**
- Modify: `App/VideoMessageCell.swift`

**Interfaces:**
- Consumes: Task 1 的 `ImageBubbleSizing.displaySize(forNaturalSize:) -> CGSize` 与 `ImageBubbleSizing.fallbackSize: CGSize`。
- Produces: 无。

- [ ] **Step 1: 把 `bubbleContainer` 的固定宽高约束改成可变常量**

`App/VideoMessageCell.swift:18-29` 属性区块，在 `spacer` 声明后加两个约束属性：

```swift
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    /// 气泡宽高按原图比例算出后写回这两个约束的 constant（layoutViews 里
    /// 激活一次，之后每次 configure 只改 constant，不重新创建约束）。
    private var bubbleWidthConstraint: NSLayoutConstraint!
    private var bubbleHeightConstraint: NSLayoutConstraint!
```

`App/VideoMessageCell.swift:124-125` 原来的：

```swift
            bubbleContainer.widthAnchor.constraint(equalToConstant: 160),
            bubbleContainer.heightAnchor.constraint(equalToConstant: 160),
```

整个 `layoutViews()` 里的 `NSLayoutConstraint.activate([...])` 调用（`App/VideoMessageCell.swift:115-149`）改为：

```swift
        bubbleWidthConstraint = bubbleContainer.widthAnchor.constraint(equalToConstant: ImageBubbleSizing.fallbackSize.width)
        bubbleHeightConstraint = bubbleContainer.heightAnchor.constraint(equalToConstant: ImageBubbleSizing.fallbackSize.height)

        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),

            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            bubbleWidthConstraint,
            bubbleHeightConstraint,

            thumbnailView.topAnchor.constraint(equalTo: bubbleContainer.topAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor),

            playCircle.centerXAnchor.constraint(equalTo: bubbleContainer.centerXAnchor),
            playCircle.centerYAnchor.constraint(equalTo: bubbleContainer.centerYAnchor),
            playCircle.widthAnchor.constraint(equalToConstant: 44),
            playCircle.heightAnchor.constraint(equalToConstant: 44),

            playIcon.centerXAnchor.constraint(equalTo: playCircle.centerXAnchor, constant: 2),
            playIcon.centerYAnchor.constraint(equalTo: playCircle.centerYAnchor),
            playIcon.widthAnchor.constraint(equalToConstant: 20),
            playIcon.heightAnchor.constraint(equalToConstant: 20),

            durationLabel.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -6),
            durationLabel.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -6),
            durationLabel.heightAnchor.constraint(equalToConstant: 20),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            activityIndicator.centerXAnchor.constraint(equalTo: bubbleContainer.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: bubbleContainer.centerYAnchor),
        ])
```

- [ ] **Step 2: `configure(with:)` 里按缩略图尺寸算气泡展示尺寸**

`App/VideoMessageCell.swift:152-158` 现状：

```swift
    func configure(with data: VideoBubbleData) {
        thumbnailView.image = data.thumbnail.flatMap { UIImage(data: $0) }
        durationLabel.text = " \(formatDuration(data.duration)) "
        playCircle.isHidden = data.isUploading
        durationLabel.isHidden = data.isUploading
        activityIndicator.isHidden = !data.isUploading
        if data.isUploading { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
```

改为：

```swift
    func configure(with data: VideoBubbleData) {
        let thumbnailImage = data.thumbnail.flatMap { UIImage(data: $0) }
        thumbnailView.image = thumbnailImage

        let displaySize = thumbnailImage.map { ImageBubbleSizing.displaySize(forNaturalSize: $0.size) }
            ?? ImageBubbleSizing.fallbackSize
        bubbleWidthConstraint.constant = displaySize.width
        bubbleHeightConstraint.constant = displaySize.height

        durationLabel.text = " \(formatDuration(data.duration)) "
        playCircle.isHidden = data.isUploading
        durationLabel.isHidden = data.isUploading
        activityIndicator.isHidden = !data.isUploading
        if data.isUploading { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
```

其余内容（`App/VideoMessageCell.swift:160-178`：`senderNameLabel`、`applyLayout`、`configurePending`）不变。

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App/VideoMessageCell.swift
git commit -m "feat(App): 视频消息气泡按原图宽高比自适应尺寸

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## 验收清单（用户在模拟器/真机验证）

1. 竖屏截图（如用户提供的班级通知截图）显示为竖直长方形气泡，不再被裁成正方形。
2. 横向照片显示为横向长方形气泡。
3. 接近正方形的照片仍接近正方形，且不小于 80×80、不大于 200×200。
4. 很小的图（如表情包分享的缩略图）气泡不会小到难以点击（下限生效）。
5. 视频消息气泡同样按比例显示，播放圆圈仍居中、时长角标仍贴右下角，不因尺寸变化而错位。
6. 图片气泡显示后原图异步加载替换时，气泡尺寸不跳动（只换内容）。
7. 列表滚动、cell 复用时尺寸/行高正确随消息切换，无残留旧尺寸。
