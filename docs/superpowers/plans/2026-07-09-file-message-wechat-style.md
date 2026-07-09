# 文件消息微信风格改造实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 文件消息气泡改为微信风格白色卡片（扩展名色块图标 + 文件名 + 大小/下载状态），点击可下载到本地并用 QLPreviewController 预览分享。

**Architecture:** 「已下载」状态不入库——文件下载到 `Documents/Files/<消息标识>/<文件名>` 确定性路径，文件存在即已下载。新增 App 层 `FileDownloadManager`（URLSession downloadTask + 进度回调，主队列使用），`FileMessageCell` 重写为白卡片布局，`ConversationViewController` 负责点击分发与 QuickLook 预览。不改 IMStorage/IMKit。

**Tech Stack:** UIKit、URLSession、QuickLook（QLPreviewController）、XcodeGen

**Spec:** `docs/superpowers/specs/2026-07-09-file-message-wechat-style-design.md`

## Global Constraints

- 全项目无内部锁约定：所有回调必须落到主队列，`FileDownloadManager` 只从主队列调用。
- 不使用单例：`FileDownloadManager` 实例由 `ConversationViewController` 持有。
- 新增源文件后必须运行 `bash Scripts/generate-xcodeproj.sh` 重新生成工程（`.xcodeproj` 不可手编）。
- 构建验证命令：`xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`，期望 `BUILD SUCCEEDED`。
- **提交时机（用户偏好，覆盖「频繁提交」默认）：所有代码任务只做构建验证、不 commit；装机由用户真机验证通过后，在最终任务一次性 commit。**
- UI 文案一律中文；状态文案精确为：`未下载` / `下载中 N%` / `已下载`。
- App target 无单测基建（维持现状），每个任务的验证 = 编译通过；行为验证在最终任务由用户真机完成。

---

### Task 1: FileDownloadManager（App 层下载器）

**Files:**
- Create: `App/FileDownloadManager.swift`
- Modify: 无（新文件需重新生成 xcodeproj）

**Interfaces:**
- Consumes: `IMKit.StoredMessageRow`（`fileName` / `messageUid` / `localMessageId` / `imageRemoteURL` 字段）
- Produces（Task 2/3 依赖）:
  - `enum FileDownloadState { case notDownloaded; case downloading(progress: Double); case downloaded(URL) }`
  - `final class FileDownloadManager: NSObject`
    - `static func localURL(for row: StoredMessageRow) -> URL?`
    - `func state(for row: StoredMessageRow) -> FileDownloadState`
    - `func download(row: StoredMessageRow, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void)`

- [ ] **Step 1: 创建 `App/FileDownloadManager.swift`，写入完整实现**

```swift
import Foundation
import IMKit

/// 文件消息的本地下载状态。「已下载」不入库，由确定性本地路径上
/// 文件是否存在推导（见 FileDownloadManager.localURL(for:)）。
enum FileDownloadState {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded(URL)
}

/// App 层文件消息下载器：URLSession downloadTask + 进度回调。
/// 遵守项目无锁约定——所有方法只能从主队列调用，回调也落回主队列。
/// 同一消息重复调用 download 只更新回调，不重复起任务。
final class FileDownloadManager: NSObject {
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    private var currentProgress: [String: Double] = [:]
    private var progressHandlers: [String: (Double) -> Void] = [:]
    private var completionHandlers: [String: (Result<URL, Error>) -> Void] = [:]

    /// Documents/Files/<消息标识>/<文件名>。消息标识用服务端 uid（未 ack
    /// 回退本地 id），前缀 u/l 区分两个 id 空间避免碰撞。
    static func localURL(for row: StoredMessageRow) -> URL? {
        guard let name = row.fileName, !name.isEmpty else { return nil }
        let key = row.messageUid != 0 ? "u\(row.messageUid)" : "l\(row.localMessageId)"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Files/\(key)/\(name)")
    }

    func state(for row: StoredMessageRow) -> FileDownloadState {
        guard let localURL = Self.localURL(for: row) else { return .notDownloaded }
        if FileManager.default.fileExists(atPath: localURL.path) { return .downloaded(localURL) }
        if tasks[localURL.path] != nil {
            return .downloading(progress: currentProgress[localURL.path] ?? 0)
        }
        return .notDownloaded
    }

    func download(
        row: StoredMessageRow,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let localURL = Self.localURL(for: row),
              let urlString = row.imageRemoteURL,
              let remoteURL = URL(string: urlString) else { return }
        let key = localURL.path
        progressHandlers[key] = progress
        completionHandlers[key] = completion
        guard tasks[key] == nil else { return }  // 已在下载，仅更新回调

        let task = URLSession.shared.downloadTask(with: remoteURL) { [weak self] tempURL, _, error in
            // 临时文件在本回调返回后即被系统删除，必须同步移动到目标路径。
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let tempURL {
                do {
                    try FileManager.default.createDirectory(
                        at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: localURL.path) {
                        try FileManager.default.removeItem(at: localURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: localURL)
                    result = .success(localURL)
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(URLError(.unknown))
            }
            DispatchQueue.main.async { self?.finish(key: key, result: result) }
        }
        observations[key] = task.progress.observe(\.fractionCompleted) { [weak self] prog, _ in
            DispatchQueue.main.async {
                guard let self, self.tasks[key] != nil else { return }
                self.currentProgress[key] = prog.fractionCompleted
                self.progressHandlers[key]?(prog.fractionCompleted)
            }
        }
        tasks[key] = task
        currentProgress[key] = 0
        task.resume()
    }

    private func finish(key: String, result: Result<URL, Error>) {
        observations[key]?.invalidate()
        observations[key] = nil
        tasks[key] = nil
        currentProgress[key] = nil
        let completion = completionHandlers[key]
        completionHandlers[key] = nil
        progressHandlers[key] = nil
        completion?(result)
    }
}
```

- [ ] **Step 2: 重新生成 Xcode 工程（新增了源文件）**

Run: `bash Scripts/generate-xcodeproj.sh`
Expected: 正常退出，输出生成成功。

- [ ] **Step 3: 构建验证**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `BUILD SUCCEEDED`

（按全局约束：本任务不 commit。）

---

### Task 2: FileMessageCell 微信风格重写

**Files:**
- Modify: `App/FileMessageCell.swift`（整文件替换）

**Interfaces:**
- Consumes: Task 1 的 `FileDownloadState`；`IMKit.StoredMessageRow`；既有 `AvatarImageView` / `AvatarLoader.shared`
- Produces（Task 3 依赖）:
  - `var onTapped: (() -> Void)?`
  - `func configure(with row: StoredMessageRow, state: FileDownloadState)`
  - `func update(state: FileDownloadState)`（仅刷新状态行，供下载进度回调使用）

- [ ] **Step 1: 用以下完整实现替换 `App/FileMessageCell.swift`**

```swift
import UIKit
import IMKit

/// 微信风格文件消息卡片：白色卡片（收发双方一致），左侧 44×44 扩展名
/// 色块图标（带右上折角），右侧文件名两行中间截断 + 「大小 下载状态」。
final class FileMessageCell: UITableViewCell {
    static let reuseIdentifier = "FileMessageCell"

    var onTapped: (() -> Void)?

    private let bubbleView = UIView()
    private let badgeView = UIView()
    private let badgeLabel = UILabel()
    private let foldLayer = CAShapeLayer()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let avatarView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    private var sizeText = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func layoutViews() {
        bubbleView.layer.cornerRadius = 16
        bubbleView.layer.borderWidth = 0.5
        bubbleView.layer.borderColor = UIColor.separator.cgColor
        bubbleView.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .white
        }
        bubbleView.isUserInteractionEnabled = true
        bubbleView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bubbleTapped)))

        badgeView.layer.cornerRadius = 8
        badgeView.layer.masksToBounds = true
        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.adjustsFontSizeToFitWidth = true
        badgeLabel.minimumScaleFactor = 0.7
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(badgeLabel)

        let fold = UIBezierPath()
        fold.move(to: CGPoint(x: 30, y: 0))
        fold.addLine(to: CGPoint(x: 44, y: 14))
        fold.addLine(to: CGPoint(x: 44, y: 0))
        fold.close()
        foldLayer.path = fold.cgPath
        foldLayer.fillColor = UIColor(white: 1, alpha: 0.35).cgColor
        badgeView.layer.addSublayer(foldLayer)

        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textColor = .label

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [nameLabel, statusLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading

        let hStack = UIStackView(arrangedSubviews: [badgeView, textStack])
        hStack.axis = .horizontal
        hStack.spacing = 10
        hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(hStack)

        NSLayoutConstraint.activate([
            badgeView.widthAnchor.constraint(equalToConstant: 44),
            badgeView.heightAnchor.constraint(equalToConstant: 44),
            badgeLabel.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            badgeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 40),
            hStack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 12),
            hStack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -12),
            hStack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 14),
            hStack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -14),
            bubbleView.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])

        bubbleColumn.axis = .vertical
        bubbleColumn.addArrangedSubview(bubbleView)

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        rowStack.addArrangedSubview(bubbleColumn)

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    @objc private func bubbleTapped() { onTapped?() }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        bubbleView.layer.borderColor = UIColor.separator.cgColor
    }

    func configure(with row: StoredMessageRow, state: FileDownloadState) {
        let name = row.fileName ?? ""
        nameLabel.text = name
        let ext = (name as NSString).pathExtension.lowercased()
        badgeLabel.text = ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4))
        badgeView.backgroundColor = Self.badgeColor(forExtension: ext)
        sizeText = ByteCountFormatter.string(fromByteCount: Int64(row.fileSize ?? 0), countStyle: .file)
        update(state: state)

        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        avatarView.removeFromSuperview()

        if row.isOutgoing {
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(avatarView)
            avatarView.setAvatar(urlString: row.senderAvatarURL, displayName: "我")
        } else {
            rowStack.addArrangedSubview(avatarView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            avatarView.setAvatar(urlString: row.senderAvatarURL, displayName: row.senderDisplayName ?? "")
        }
    }

    func update(state: FileDownloadState) {
        switch state {
        case .notDownloaded:
            statusLabel.text = "\(sizeText) 未下载"
        case .downloading(let progress):
            statusLabel.text = "下载中 \(Int(progress * 100))%"
        case .downloaded:
            statusLabel.text = "\(sizeText) 已下载"
        }
    }

    private static func badgeColor(forExtension ext: String) -> UIColor {
        switch ext {
        case "pdf": return UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 1)
        case "doc", "docx": return UIColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1)
        case "xls", "xlsx", "csv": return UIColor(red: 0.13, green: 0.66, blue: 0.42, alpha: 1)
        case "ppt", "pptx": return UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        case "zip", "rar", "7z": return UIColor(red: 0.55, green: 0.50, blue: 0.75, alpha: 1)
        case "txt", "md": return UIColor(red: 0.45, green: 0.55, blue: 0.62, alpha: 1)
        default: return UIColor(red: 0.60, green: 0.63, blue: 0.68, alpha: 1)
        }
    }
}
```

- [ ] **Step 2: 构建验证（此时 `ConversationViewController` 里旧调用 `cell.configure(with: message)` 会编译失败——预期，本步先确认失败点只有这一处）**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | grep -A 2 "error:"`
Expected: 仅 `ConversationViewController.swift` 中 FileMessageCell 的 `configure` 调用报参数缺失错误（Task 3 修复）。若出现其他错误，先在本任务内修掉。

---

### Task 3: ConversationViewController 接线（点击下载 / 进度刷新 / QuickLook 预览）

**Files:**
- Modify: `App/ConversationViewController.swift`
  - 顶部 import 区
  - 属性区（`dataSource` 声明附近，约 line 15）
  - `configureDataSource()` 内文件消息分支（约 line 172-182）
  - 文件末尾新增扩展

**Interfaces:**
- Consumes: Task 1 `FileDownloadManager`（`state(for:)` / `download(row:progress:completion:)`）；Task 2 `FileMessageCell`（`configure(with:state:)` / `update(state:)` / `onTapped`）
- Produces: 无（终端消费者）

- [ ] **Step 1: 顶部增加 import**

在 `import UIKit` 附近加：

```swift
import QuickLook
```

- [ ] **Step 2: 属性区新增下载器与预览 URL**

在 `private var dataSource: UITableViewDiffableDataSource<Int, ChatMessageRow>!` 下方加：

```swift
    private let fileDownloadManager = FileDownloadManager()
    private var previewURL: URL?
```

- [ ] **Step 3: dataSource 外层闭包改为弱捕获**

把：

```swift
        dataSource = UITableViewDiffableDataSource<Int, ChatMessageRow>(tableView: tableView) { tableView, indexPath, row in
```

改为：

```swift
        dataSource = UITableViewDiffableDataSource<Int, ChatMessageRow>(tableView: tableView) { [weak self] tableView, indexPath, row in
```

（外层闭包体内现无裸 `self` 引用，内层子闭包均已 `[weak self]`，此改动不影响其余分支。）

- [ ] **Step 4: 替换文件消息分支**

把：

```swift
            case .message(let message) where message.text?.hasPrefix("[文件]") == true:
                let cell = tableView.dequeueReusableCell(withIdentifier: FileMessageCell.reuseIdentifier, for: indexPath) as! FileMessageCell
                cell.configure(with: message)
                return cell
```

改为（分发条件改用 `fileName != nil`，比切字符串前缀可靠；该分支在 `text != nil` 分支之前，顺序不变）：

```swift
            case .message(let message) where message.fileName != nil:
                let cell = tableView.dequeueReusableCell(withIdentifier: FileMessageCell.reuseIdentifier, for: indexPath) as! FileMessageCell
                cell.configure(with: message, state: self?.fileDownloadManager.state(for: message) ?? .notDownloaded)
                cell.onTapped = { [weak self] in self?.handleFileTap(message: message) }
                return cell
```

- [ ] **Step 5: 文件末尾新增点击处理与 QuickLook 扩展**

```swift
// MARK: - 文件消息下载与预览

extension ConversationViewController: QLPreviewControllerDataSource {
    /// 未下载 → 起下载并实时刷新进度；下载中 → 忽略；已下载 → QuickLook
    /// 预览（自带分享按钮，可存到「文件」或转发其他 App）。
    private func handleFileTap(message: StoredMessageRow) {
        switch fileDownloadManager.state(for: message) {
        case .downloading:
            return
        case .downloaded(let url):
            presentFilePreview(url: url)
        case .notDownloaded:
            fileDownloadManager.download(row: message) { [weak self] _ in
                self?.refreshFileCell(for: message)
            } completion: { [weak self] result in
                self?.refreshFileCell(for: message)
                if case .failure = result {
                    let alert = UIAlertController(title: "下载失败", message: "文件下载失败，请稍后重试", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default))
                    self?.present(alert, animated: true)
                }
            }
            refreshFileCell(for: message)
        }
    }

    /// 下载状态不参与 diffable 快照身份，直接刷新可见 cell 的状态行。
    private func refreshFileCell(for message: StoredMessageRow) {
        guard let indexPath = dataSource.indexPath(for: .message(message)),
              let cell = tableView.cellForRow(at: indexPath) as? FileMessageCell else { return }
        cell.update(state: fileDownloadManager.state(for: message))
    }

    private func presentFilePreview(url: URL) {
        previewURL = url
        let preview = QLPreviewController()
        preview.dataSource = self
        present(preview, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "")) as NSURL
    }
}
```

- [ ] **Step 6: 构建验证**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `BUILD SUCCEEDED`（Task 2 遗留的 configure 编译错误在此消除）

---

### Task 4: 真机验证与提交

**Files:**
- 无代码改动

- [ ] **Step 1: 构建并安装到真机，交用户验证**

按项目惯例装机（Xcode 正常时直接 build & install；异常时用 devicectl 兜底）。请用户验证清单：

1. 收/发 PDF 等文件消息 → 白卡片、扩展名色块图标、文件名、`大小 未下载`
2. 点击卡片 → `下载中 N%` 实时刷新 → 完成后变 `已下载` 并可再点开 QuickLook 预览
3. 预览页分享按钮可存到「文件」App
4. 大文件下载中断网 → 弹「下载失败」，状态回 `未下载`，可重试
5. 退出会话重进 → 已下载文件仍显示 `已下载`
6. 深色模式下卡片与图标显示正常

- [ ] **Step 2: 用户验证通过后统一提交**

```bash
git add App/FileDownloadManager.swift App/FileMessageCell.swift App/ConversationViewController.swift
git commit -m "feat(App): 文件消息微信风格卡片，支持点击下载与 QuickLook 预览

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

（`.xcodeproj` 是否入库遵循仓库现状：若 `git status` 显示其变更且历史上有提交先例，则一并 add。）
