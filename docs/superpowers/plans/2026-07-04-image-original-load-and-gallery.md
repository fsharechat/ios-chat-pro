# 图片消息原图异步加载 + 画廊浏览 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 图片消息气泡先显示缩略图、显示时异步加载原图替换；点击进入全屏画廊，左右滑动浏览会话内所有图片，下拉手势关闭。

**Architecture:** IMKit 新增带内存+磁盘两级缓存的 `ImageLoader`（`Data` 接口，macOS 可测）；App 层 `ImageMessageCell` 配置时异步换原图；新建 `ImageGalleryViewController`（UIPageViewController）+ `ImageZoomPageViewController` 替换现有单图 `ImagePreviewViewController`。

**Tech Stack:** Swift 5.8 / UIKit / CryptoKit(SHA256) / XCTest + MockURLProtocol / XcodeGen。

**Spec:** `docs/superpowers/specs/2026-07-04-image-original-load-and-gallery-design.md`

## Global Constraints

- 全代码库线程约定：无内部锁，全部从主队列调用（见根 CLAUDE.md）。
- IMKit 不得依赖 UIKit（macOS 下 `swift test` 要能编译），图片接口返回 `Data`。
- 新增 `App/*.swift` 文件后必须运行 `bash Scripts/generate-xcodeproj.sh`（.xcodeproj 由 XcodeGen 生成，不得手工编辑）。
- App 编译验证命令：`xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`。
- `swift test` 本机环境坑：WebRTC macOS 切片需补头文件才能构建整个测试包；主干存在固有失败基线（`MessageContentCodecTests` 3 个旧断言、`MediaUploadServiceTests` URL 断言、`ConversationViewModelTests.test_recalledByOtherWithNoProfile_fallsBackToUid` flaky、`GroupInfoViewModelTests.test_members_excludesRemovedAndMarksOwner`、IMCallTests GRDB 崩溃）。只关注 `--filter ImageLoaderTests` 的结果，勿把基线失败误判为回归。
- 提交信息结尾加 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 删除 `App/ImagePreviewViewController.swift` 已在 spec 中获用户明确批准（2026-07-04）。

---

### Task 1: `ImageLoader`（IMKit，内存+磁盘缓存）

**Files:**
- Create: `Sources/IMKit/ImageLoader.swift`
- Test: `Tests/IMKitTests/ImageLoaderTests.swift`

**Interfaces:**
- Consumes: `Tests/IMKitTests/Support/MockURLProtocol.swift`（已存在，`MockURLProtocol.makeSession()` 返回打桩 URLSession，`requestHandler` 闭包按请求返回 `(HTTPURLResponse, Data)`）。
- Produces（后续 Task 2/3 依赖，签名必须一字不差）:
  - `public protocol ImageLoading { func loadImageData(from urlString: String) async -> Data? }`
  - `public final class ImageLoader: ImageLoading`，`public static let shared = ImageLoader()`，`public init(session: URLSession = .shared, diskDirectory: URL? = nil)`

- [ ] **Step 1: 写失败测试**

创建 `Tests/IMKitTests/ImageLoaderTests.swift`：

```swift
import XCTest
@testable import IMKit

final class ImageLoaderTests: XCTestCase {
    private var loader: ImageLoader!
    private var requestCount: Int!
    private var diskDirectory: URL!

    override func setUp() {
        super.setUp()
        requestCount = 0
        diskDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageLoaderTests-\(UUID().uuidString)", isDirectory: true)
        loader = ImageLoader(session: MockURLProtocol.makeSession(), diskDirectory: diskDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: diskDirectory)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func respond(statusCode: Int, data: Data) {
        MockURLProtocol.requestHandler = { [weak self] request in
            self?.requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    func test_loadImageData_onSuccess_returnsTheBody() async {
        respond(statusCode: 200, data: Data([0x01, 0x02, 0x03]))

        let data = await loader.loadImageData(from: "https://example.com/a.jpg")

        XCTAssertEqual(data, Data([0x01, 0x02, 0x03]))
    }

    func test_loadImageData_onNon200Status_returnsNilAndDoesNotCache() async {
        respond(statusCode: 404, data: Data())

        let first = await loader.loadImageData(from: "https://example.com/missing.jpg")
        let second = await loader.loadImageData(from: "https://example.com/missing.jpg")

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(requestCount, 2) // 失败不落缓存，第二次仍走网络
    }

    func test_loadImageData_withInvalidURLString_returnsNilWithoutNetworkCall() async {
        let data = await loader.loadImageData(from: "")

        XCTAssertNil(data)
        XCTAssertEqual(requestCount, 0)
    }

    func test_loadImageData_calledTwiceForSameURL_onlyHitsTheNetworkOnce() async {
        respond(statusCode: 200, data: Data([0x01]))

        _ = await loader.loadImageData(from: "https://example.com/a.jpg")
        _ = await loader.loadImageData(from: "https://example.com/a.jpg")

        XCTAssertEqual(requestCount, 1)
    }

    func test_loadImageData_freshLoaderWithSameDiskDirectory_readsFromDiskWithoutNetwork() async {
        respond(statusCode: 200, data: Data([0x0A, 0x0B]))
        _ = await loader.loadImageData(from: "https://example.com/a.jpg")
        XCTAssertEqual(requestCount, 1)

        // 模拟下次启动：新实例、同磁盘目录、无网络应答也能命中
        MockURLProtocol.requestHandler = nil
        let freshLoader = ImageLoader(session: MockURLProtocol.makeSession(), diskDirectory: diskDirectory)

        let data = await freshLoader.loadImageData(from: "https://example.com/a.jpg")

        XCTAssertEqual(data, Data([0x0A, 0x0B]))
        XCTAssertEqual(requestCount, 1)
    }

    func test_cacheFileName_isStableHexAndDiffersPerURL() {
        let a1 = ImageLoader.cacheFileName(for: "https://example.com/a.jpg")
        let a2 = ImageLoader.cacheFileName(for: "https://example.com/a.jpg")
        let b = ImageLoader.cacheFileName(for: "https://example.com/b.jpg")

        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, b)
        XCTAssertEqual(a1.count, 64) // SHA256 hex
        XCTAssertTrue(a1.allSatisfy { $0.isHexDigit })
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ImageLoaderTests`
Expected: 编译失败，`cannot find 'ImageLoader' in scope`。
（若整个包因 WebRTC macOS 头文件问题无法构建，先按 Global Constraints 里的 quirk 补头文件再跑。）

- [ ] **Step 3: 最小实现**

创建 `Sources/IMKit/ImageLoader.swift`：

```swift
import Foundation
import CryptoKit

/// Fetches and caches full-size message images from a URL string. Returns
/// raw `Data`, not `UIImage` — `UIKit` isn't available when this target
/// builds for `swift test` on macOS; the `App` target decodes the bytes.
public protocol ImageLoading {
    func loadImageData(from urlString: String) async -> Data?
}

/// Two-level cache: `NSCache` in memory + files on disk under
/// `Caches/ImageCache/<SHA256(urlString)>`. Message rows store the fixed
/// post-upload `remoteMediaUrl`, so the URL string is a stable cache key.
///
/// **Threading contract:** like `AvatarLoader`, no internal locking — call
/// from the main queue. `NSCache` single operations are thread-safe and the
/// disk write is atomic, so the worst concurrent-miss outcome is a redundant
/// fetch of the same bytes, accepted for the same reasons documented on
/// `AvatarLoader`.
public final class ImageLoader: ImageLoading {
    public static let shared = ImageLoader()

    private let session: URLSession
    private let memoryCache = NSCache<NSString, NSData>()
    private let diskDirectory: URL

    public init(session: URLSession = .shared, diskDirectory: URL? = nil) {
        self.session = session
        self.diskDirectory = diskDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
    }

    public func loadImageData(from urlString: String) async -> Data? {
        let key = urlString as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached as Data
        }

        let fileURL = diskDirectory.appendingPathComponent(Self.cacheFileName(for: urlString))
        if let diskData = try? Data(contentsOf: fileURL) {
            memoryCache.setObject(diskData as NSData, forKey: key)
            return diskData
        }

        guard let url = URL(string: urlString) else { return nil }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(from: url)
        } catch {
            return nil
        }
        guard let httpResponse = result.1 as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        memoryCache.setObject(result.0 as NSData, forKey: key)
        try? result.0.write(to: fileURL, options: .atomic)
        return result.0
    }

    static func cacheFileName(for urlString: String) -> String {
        SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ImageLoaderTests`
Expected: 6 个测试全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/ImageLoader.swift Tests/IMKitTests/ImageLoaderTests.swift
git commit -m "feat(IMKit): ImageLoader 内存+磁盘两级缓存原图加载器

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: 气泡内异步加载并显示原图

**Files:**
- Modify: `App/ImageMessageCell.swift`
- Modify: `App/ConversationViewController.swift:206`（message 图片分支传 `remoteURL`；`:212` pending 分支不变，走默认 nil）

**Interfaces:**
- Consumes: Task 1 的 `ImageLoader.shared`（`func loadImageData(from urlString: String) async -> Data?`）。
- Produces: `ImageBubbleData` 新增 `let remoteURL: String?`，init 参数 `remoteURL: String? = nil`（紧跟 `thumbnail` 之后）。

- [ ] **Step 1: `ImageBubbleData` 增加 `remoteURL`**

`App/ImageMessageCell.swift` 中 struct 改为：

```swift
struct ImageBubbleData: Equatable {
    let thumbnail: Data?
    let remoteURL: String?
    let isOutgoing: Bool
    let isUploading: Bool
    let isFailed: Bool
    let senderDisplayName: String?
    let senderAvatarURL: String?

    init(thumbnail: Data?, remoteURL: String? = nil, isOutgoing: Bool, isUploading: Bool, isFailed: Bool, senderDisplayName: String? = nil, senderAvatarURL: String? = nil) {
        self.thumbnail = thumbnail
        self.remoteURL = remoteURL
        self.isOutgoing = isOutgoing
        self.isUploading = isUploading
        self.isFailed = isFailed
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
    }
}
```

- [ ] **Step 2: cell 配置时异步加载原图（带复用竞态防护）**

`ImageMessageCell` 增加属性（放在 `onTapped` 声明旁）：

```swift
    /// 复用竞态防护：异步原图回来时若 cell 已被复用绑定到别的 URL，丢弃结果。
    private var currentRemoteURL: String?
```

`prepareForReuse()` 里 `bubbleImageView.image = nil` 后追加一行：

```swift
        currentRemoteURL = nil
```

`configure(with:)` 中，把现有的

```swift
        bubbleImageView.image = data.thumbnail.flatMap { UIImage(data: $0) }
```

替换为：

```swift
        bubbleImageView.image = data.thumbnail.flatMap { UIImage(data: $0) }
        currentRemoteURL = data.remoteURL
        if let remoteURL = data.remoteURL {
            Task { [weak self] in
                guard let original = await ImageLoader.shared.loadImageData(from: remoteURL),
                      let image = UIImage(data: original) else { return }
                guard let self, self.currentRemoteURL == remoteURL else { return }
                UIView.transition(with: self.bubbleImageView, duration: 0.2, options: .transitionCrossDissolve) {
                    self.bubbleImageView.image = image
                }
            }
        }
```

（cell 在主线程配置，`Task` 继承 MainActor 上下文，符合"全主队列"约定；缓存命中时几乎同步完成，crossfade 不闪烁。）

- [ ] **Step 3: `ConversationViewController` message 图片分支传入 remoteURL**

`App/ConversationViewController.swift:206` 的 `configure` 调用改为（仅新增 `remoteURL:` 实参）：

```swift
                cell.configure(with: ImageBubbleData(thumbnail: message.imageThumbnail, remoteURL: message.imageRemoteURL, isOutgoing: message.isOutgoing, isUploading: message.status == .sending, isFailed: message.status == .sendFailure, senderDisplayName: message.senderDisplayName, senderAvatarURL: message.senderAvatarURL))
```

`:212` 的 pendingImage 分支不改（本地待上传图无 remoteURL，缩略图即本地数据）。

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add App/ImageMessageCell.swift App/ConversationViewController.swift
git commit -m "feat(App): 图片气泡显示时异步加载原图并淡入替换缩略图

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: 画廊页面（缩放单页 + 翻页容器 + 下拉关闭）

**Files:**
- Create: `App/ImageZoomPageViewController.swift`
- Create: `App/ImageGalleryViewController.swift`

**Interfaces:**
- Consumes: Task 1 的 `ImageLoading` / `ImageLoader.shared`。
- Produces（Task 4 依赖）:
  - `struct GalleryItem { let thumbnail: Data?; let remoteURL: String? }`
  - `final class ImageGalleryViewController: UIViewController`，
    `init(items: [GalleryItem], startIndex: Int, loader: ImageLoading = ImageLoader.shared)`，全屏 present。

- [ ] **Step 1: 创建 `App/ImageZoomPageViewController.swift`**

```swift
// App/ImageZoomPageViewController.swift
import UIKit
import IMKit

/// 画廊中的单页：可缩放（双击切换、捏合 1–4x）的一张图。先显示缩略图，
/// 异步经 ImageLoader 加载原图后替换。背景透明，由画廊容器统一铺黑，
/// 下拉关闭时容器才能整体调节背景 alpha。
final class ImageZoomPageViewController: UIViewController {
    let index: Int
    let scrollView = UIScrollView()

    private let item: GalleryItem
    private let loader: ImageLoading
    private let imageView = UIImageView()

    init(item: GalleryItem, index: Int, loader: ImageLoading) {
        self.item = item
        self.index = index
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        layoutViews()
        if let thumbnail = item.thumbnail, let image = UIImage(data: thumbnail) {
            imageView.image = image
        }
        if let remoteURL = item.remoteURL {
            Task { [weak self] in
                guard let self else { return }
                guard let data = await self.loader.loadImageData(from: remoteURL),
                      let image = UIImage(data: data) else { return }
                self.imageView.image = image
            }
        }
    }

    private func layoutViews() {
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            imageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    @objc private func handleDoubleTap() {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            scrollView.setZoomScale(scrollView.maximumZoomScale, animated: true)
        }
    }
}

extension ImageZoomPageViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}
```

- [ ] **Step 2: 创建 `App/ImageGalleryViewController.swift`**

```swift
// App/ImageGalleryViewController.swift
import UIKit
import IMKit

/// 画廊的一项：气泡里携带的缩略图 + 原图远端 URL（pending 图为本地
/// 原数据 + nil URL）。
struct GalleryItem {
    let thumbnail: Data?
    let remoteURL: String?
}

/// 全屏图片画廊：UIPageViewController 横向翻页浏览会话内全部图片，
/// 顶部页码，右上角关闭；当前页未缩放时向下拖动可跟手缩小并关闭。
final class ImageGalleryViewController: UIViewController {
    private let items: [GalleryItem]
    private let loader: ImageLoading
    private var currentIndex: Int

    private let pageViewController = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: [.interPageSpacing: 16]
    )
    private let pageLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    init(items: [GalleryItem], startIndex: Int, loader: ImageLoading = ImageLoader.shared) {
        self.items = items
        self.currentIndex = min(max(0, startIndex), items.count - 1)
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutViews()
        pageViewController.setViewControllers([makePage(at: currentIndex)], direction: .forward, animated: false)
        updatePageLabel()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    private func layoutViews() {
        addChild(pageViewController)
        pageViewController.dataSource = self
        pageViewController.delegate = self
        pageViewController.view.frame = view.bounds
        pageViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageViewController.view.backgroundColor = .clear
        view.addSubview(pageViewController.view)
        pageViewController.didMove(toParent: self)

        pageLabel.textColor = .white
        pageLabel.font = .systemFont(ofSize: 15)
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageLabel)

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            pageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func makePage(at index: Int) -> ImageZoomPageViewController {
        ImageZoomPageViewController(item: items[index], index: index, loader: loader)
    }

    private var currentPage: ImageZoomPageViewController? {
        pageViewController.viewControllers?.first as? ImageZoomPageViewController
    }

    private func updatePageLabel() {
        pageLabel.text = "\(currentIndex + 1) / \(items.count)"
        pageLabel.isHidden = items.count <= 1
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    // MARK: - 下拉关闭

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        let progress = max(0, translation.y) / max(1, view.bounds.height)

        switch pan.state {
        case .changed:
            let scale = max(0.5, 1 - progress * 0.5)
            pageViewController.view.transform = CGAffineTransform(translationX: translation.x, y: max(0, translation.y))
                .scaledBy(x: scale, y: scale)
            view.backgroundColor = UIColor.black.withAlphaComponent(max(0, 1 - progress * 1.5))
            pageLabel.alpha = max(0, 1 - progress * 3)
            closeButton.alpha = max(0, 1 - progress * 3)
        case .ended, .cancelled:
            if translation.y > 100 || pan.velocity(in: view).y > 800 {
                // 顺着拖动方向滑出再无动画 dismiss，比系统下滑转场更跟手。
                UIView.animate(withDuration: 0.2, animations: {
                    self.pageViewController.view.transform = CGAffineTransform(
                        translationX: translation.x,
                        y: self.view.bounds.height
                    ).scaledBy(x: 0.5, y: 0.5)
                    self.view.backgroundColor = .clear
                }, completion: { _ in
                    self.dismiss(animated: false)
                })
            } else {
                UIView.animate(withDuration: 0.25) {
                    self.pageViewController.view.transform = .identity
                    self.view.backgroundColor = .black
                    self.pageLabel.alpha = 1
                    self.closeButton.alpha = 1
                }
            }
        default:
            break
        }
    }
}

extension ImageGalleryViewController: UIPageViewControllerDataSource {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ImageZoomPageViewController, page.index > 0 else { return nil }
        return makePage(at: page.index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ImageZoomPageViewController, page.index < items.count - 1 else { return nil }
        return makePage(at: page.index + 1)
    }
}

extension ImageGalleryViewController: UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = currentPage else { return }
        currentIndex = page.index
        updatePageLabel()
    }
}

extension ImageGalleryViewController: UIGestureRecognizerDelegate {
    /// 只在当前页未放大、且手势明显向下时启动下拉关闭；
    /// 与翻页/缩放的内部手势并存，互不阻塞。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard let page = currentPage, page.scrollView.zoomScale <= page.scrollView.minimumZoomScale else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.y > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
```

- [ ] **Step 3: 重新生成工程并编译验证**

```bash
bash Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`（新文件此时尚无调用方，仅验证可编译）。

- [ ] **Step 4: Commit**

```bash
git add App/ImageZoomPageViewController.swift App/ImageGalleryViewController.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): 全屏图片画廊,翻页浏览+双击缩放+下拉关闭

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: 会话页接线画廊，删除旧单图预览

**Files:**
- Modify: `App/ConversationViewController.swift`（`:208`、`:214` 的 `onTapped`；`:511-513` 的 `presentImagePreview`）
- Delete: `App/ImagePreviewViewController.swift`（spec 已获批）

**Interfaces:**
- Consumes: Task 3 的 `ImageGalleryViewController(items:startIndex:)` 与 `GalleryItem`；已有的 `viewModel.rows: [ChatMessageRow]`、`Self.rowIdentity(_:)`（`ConversationViewController.swift:378`）。
- Produces: 无（终端接线）。

- [ ] **Step 1: 替换 present 方法**

删除 `App/ConversationViewController.swift:511-513` 的：

```swift
    private func presentImagePreview(thumbnail: Data?, remoteURL: String?) {
        present(ImagePreviewViewController(localThumbnail: thumbnail, remoteURL: remoteURL), animated: true)
    }
```

原位替换为：

```swift
    /// 从当前 rows 收集全部图片消息组成画廊（含发送中的 pending 图），
    /// 用 rowIdentity 定位被点击的那张作为起始页。图片行的判定与
    /// configureDataSource 的 cell 分派规则一致：.message 且非语音/文件
    /// （text == nil 已排除）、非位置、非视频。
    private func presentImageGallery(from tappedRow: ChatMessageRow) {
        var items: [GalleryItem] = []
        var startIndex: Int?
        for row in viewModel.rows {
            let item: GalleryItem
            switch row {
            case .message(let message) where message.text == nil && message.videoDuration == nil && message.locationLat == nil:
                item = GalleryItem(thumbnail: message.imageThumbnail, remoteURL: message.imageRemoteURL)
            case .pendingImage(let pending):
                item = GalleryItem(thumbnail: pending.fullImageData, remoteURL: nil)
            default:
                continue
            }
            if Self.rowIdentity(row) == Self.rowIdentity(tappedRow) { startIndex = items.count }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        present(ImageGalleryViewController(items: items, startIndex: startIndex ?? 0), animated: true)
    }
```

- [ ] **Step 2: 两处 `onTapped` 改走画廊**

`:208`（message 图片分支）改为：

```swift
                cell.onTapped = { [weak self] in self?.presentImageGallery(from: row) }
```

`:214`（pendingImage 分支）改为：

```swift
                cell.onTapped = { [weak self] in self?.presentImageGallery(from: row) }
```

- [ ] **Step 3: 删除旧预览并重新生成工程**

```bash
git rm App/ImagePreviewViewController.swift
bash Scripts/generate-xcodeproj.sh
```

- [ ] **Step 4: 全量验证**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
swift test --filter ImageLoaderTests
```

Expected: `** BUILD SUCCEEDED **`；ImageLoaderTests 全 PASS。
再确认无残留引用：`grep -rn "ImagePreviewViewController" App Sources` 应无输出。

- [ ] **Step 5: Commit**

```bash
git add App/ConversationViewController.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): 点击图片进入画廊浏览,替换单图预览

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## 验收清单（用户在模拟器/真机验证）

1. 图片消息气泡先显示缩略图，稍后自动变清晰（原图）；滚动列表无错图串位。
2. 断网时气泡保持缩略图，不报错。
3. 点击任意图片全屏打开，起始页即被点的那张；顶部显示 "n / m"。
4. 左右滑动可浏览会话内所有图片（不含视频/位置图）；翻页后页码更新。
5. 双击放大/还原，捏合缩放 1–4x；放大状态下拖动是平移图片，不触发关闭。
6. 未放大时向下拖动，图片跟手缩小、背景渐透明；拖过约 100pt 松手关闭，未过则弹回。
7. 再次打开同一张图秒开（磁盘缓存生效，杀进程重启后依然）。
