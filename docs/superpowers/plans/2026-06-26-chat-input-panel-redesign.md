# Chat Input Panel Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重写 iOS 聊天输入面板，对齐 Android chat-pro 设计，并新增语音消息和文件消息的完整收发能力。

**Architecture:** 从底层存储到 UI 分层实现：先扩展 IMStorage/IMMessaging/IMMedia 支持 voice(type=2) 和 file(type=5) 消息类型，再重写 App 层输入栏 UI（含 emoji 面板、更多面板、语音录制），最后在 ConversationViewController 串联所有回调。表结构无需变更，复用 `textContent` 存储 voice duration 和 file size。

**Tech Stack:** Swift, UIKit, AVFoundation (AVAudioRecorder/AVAudioPlayer), PHPickerViewController, UIDocumentPickerViewController, MinIO presigned upload

## Global Constraints

- 不新增任何数据库表列，复用 `StoredMessage` 现有字段
- 上传均使用 `Im_GetMinioUploadUrlRequest`，mediaType: image=1, voice=2, file=4
- Wire type 对齐 Android: text=1, image=3, voice=2, file=5
- 语音录制格式：`.m4a`（AVAudioRecorder 默认）
- emoji 面板使用 Android emoji.xml 中的 130 个标准 Unicode 码点，直接渲染为 Swift Character，无需图片资源
- 输入栏布局：`[🎤] [textView] [😊] [➕|发送]`，有文字时 ➕ 换成发送

---

## 修改范围总览

### 新建文件（9 个）

| 文件 | 层 | 职责 |
|------|----|------|
| `Sources/IMKit/VoiceUploading.swift` | IMKit | 语音上传协议 |
| `Sources/IMKit/FileUploading.swift` | IMKit | 文件上传协议 |
| `App/EmojiPanelView.swift` | App | Emoji 选择面板（分页 CollectionView，130 个表情 + 退格键）|
| `App/ExtPanelView.swift` | App | 更多功能面板（相册/拍摄/文件，3 个按钮网格）|
| `App/VoiceMessageCell.swift` | App | 语音消息气泡（显示时长，点击播放）|
| `App/FileMessageCell.swift` | App | 文件消息气泡（显示文件名+大小）|

### 修改文件（8 个）

| 文件 | 层 | 修改内容 |
|------|----|---------|
| `Sources/IMStorage/MessageEnums.swift` | IMStorage | 新增 `voice = 2`，`file = 5` |
| `Sources/IMStorage/StoredMessage.swift` | IMStorage | 新增 `.voice`/`.file` case 的 `setContent`/`content` 处理 |
| `Sources/IMMessaging/MessageContentCodec.swift` | IMMessaging | 新增 type 2（voice）和 type 5（file）的 encode/decode |
| `Sources/IMMedia/MediaUploadService.swift` | IMMedia | 重构：提取通用 `upload(data:mediaType:fileName:)` 方法，新增 `uploadVoice`/`uploadFile` |
| `Sources/IMKit/MessageSending.swift` | IMKit | 协议新增 `sendVoice`/`sendFile` 方法 |
| `Sources/IMMessaging/MessagingService.swift` | IMMessaging | 实现 `sendVoice`/`sendFile`，确认协议符合 |
| `Sources/IMKit/ConversationViewModel.swift` | IMKit | 新增 `sendVoice(audioData:duration:)`/`sendFile(data:name:)` |
| `App/MessageInputBar.swift` | App | 完整重写，新布局 + emoji/ext/voice 三态面板管理 |
| `App/ConversationViewController.swift` | App | 注册新 Cell，接入 inputBar 新回调，适配相册/拍摄/文件/语音发送 |

---

## Task 1：IMStorage — 新增 voice 和 file 消息类型

**Files:**
- Modify: `Sources/IMStorage/MessageEnums.swift`
- Modify: `Sources/IMStorage/StoredMessage.swift`
- Test: `Tests/IMStorageTests/StoredMessageTests.swift`

**Interfaces:**
- Produces:
  - `MessageContentType.voice = 2`
  - `MessageContentType.file = 5`
  - `MessageContent.voice(remoteURL: String?, localPath: String?, duration: Int)`
  - `MessageContent.file(name: String, size: Int, remoteURL: String?, localPath: String?)`

**存储列复用策略（无 migration）：**

```
voice: textContent="\(duration)", searchableContent="[语音]", mediaRemoteURL=url, mediaLocalPath=path
file:  textContent="\(size)",     searchableContent=filename,  mediaRemoteURL=url, mediaLocalPath=path
```

- [ ] **Step 1: 在 `MessageEnums.swift` 的 `MessageContentType` 中新增两个 case**

```swift
case voice = 2
case file = 5
```

同时在 `MessageContent` 中新增：

```swift
case voice(remoteURL: String?, localPath: String?, duration: Int)
case file(name: String, size: Int, remoteURL: String?, localPath: String?)
```

- [ ] **Step 2: 在 `StoredMessage.content` 的 switch 中新增两个 case**

```swift
case .voice:
    return .voice(remoteURL: mediaRemoteURL, localPath: mediaLocalPath, duration: Int(textContent ?? "0") ?? 0)
case .file:
    return .file(name: searchableContent ?? "", size: Int(textContent ?? "0") ?? 0, remoteURL: mediaRemoteURL, localPath: mediaLocalPath)
```

- [ ] **Step 3: 在 `StoredMessage.setContent(_:)` 中新增两个 case**

```swift
case .voice(let remoteURL, let localPath, let duration):
    contentType = .voice
    textContent = "\(duration)"
    searchableContent = "[语音]"
    mediaRemoteURL = remoteURL
    mediaLocalPath = localPath
    mediaThumbnail = nil
    groupNotificationOperator = nil
    groupNotificationMembersRaw = nil
    groupNotificationValue = nil
    callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0

case .file(let name, let size, let remoteURL, let localPath):
    contentType = .file
    textContent = "\(size)"
    searchableContent = name
    mediaRemoteURL = remoteURL
    mediaLocalPath = localPath
    mediaThumbnail = nil
    groupNotificationOperator = nil
    groupNotificationMembersRaw = nil
    groupNotificationValue = nil
    callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0
```

- [ ] **Step 4: 修复 `StoredMessage.swift` 中 `renderSystemTipText` 的 exhaustive switch（在 `.text, .image, .callStart` 那行加上 `.voice, .file`）**

- [ ] **Step 5: 在 `ConversationViewModel.swift` 的 `makeRow` 中新增两个 case**

```swift
case .voice(_, _, let duration):
    return .message(buildStoredMessageRow(message, text: "[语音] \(duration)秒", imageThumbnail: nil, imageRemoteURL: nil))
case .file(let name, let size, _, _):
    let sizeStr = size > 1024*1024 ? String(format: "%.1fMB", Double(size)/1024/1024) : "\(size/1024)KB"
    return .message(buildStoredMessageRow(message, text: "[文件] \(name) \(sizeStr)", imageThumbnail: nil, imageRemoteURL: nil))
```

- [ ] **Step 6: 写单元测试**

```swift
// Tests/IMStorageTests/StoredMessageTests.swift
func test_voiceRoundtrip() {
    var msg = StoredMessage(localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
                            content: .voice(remoteURL: "https://cdn/a.m4a", localPath: nil, duration: 12),
                            timestamp: 0, status: .sent, direction: .send)
    XCTAssertEqual(msg.contentType, .voice)
    XCTAssertEqual(msg.textContent, "12")
    XCTAssertEqual(msg.searchableContent, "[语音]")
    XCTAssertEqual(msg.mediaRemoteURL, "https://cdn/a.m4a")
    if case .voice(let url, _, let d) = msg.content {
        XCTAssertEqual(url, "https://cdn/a.m4a")
        XCTAssertEqual(d, 12)
    } else { XCTFail() }
}

func test_fileRoundtrip() {
    var msg = StoredMessage(localMessageId: 2, conversationType: .single, target: "u2", from: "u1",
                            content: .file(name: "report.pdf", size: 204800, remoteURL: "https://cdn/f.pdf", localPath: nil),
                            timestamp: 0, status: .sent, direction: .send)
    XCTAssertEqual(msg.contentType, .file)
    XCTAssertEqual(msg.textContent, "204800")
    XCTAssertEqual(msg.searchableContent, "report.pdf")
    if case .file(let name, let size, let url, _) = msg.content {
        XCTAssertEqual(name, "report.pdf")
        XCTAssertEqual(size, 204800)
        XCTAssertEqual(url, "https://cdn/f.pdf")
    } else { XCTFail() }
}
```

- [ ] **Step 7: 运行测试，确认通过**

```bash
cd /Users/liaojinlong/Share/GitWorkplace/github/fshare/ios-chat-pro
swift test --filter IMStorageTests
```

- [ ] **Step 8: Commit**

```bash
git add Sources/IMStorage/MessageEnums.swift Sources/IMStorage/StoredMessage.swift Sources/IMKit/ConversationViewModel.swift Tests/IMStorageTests/StoredMessageTests.swift
git commit -m "feat(IMStorage): add voice(type=2) and file(type=5) message types, reuse existing columns"
```

---

## Task 2：IMMessaging — Codec 支持 voice 和 file

**Files:**
- Modify: `Sources/IMMessaging/MessageContentCodec.swift`
- Test: `Tests/IMMessagingTests/MessageContentCodecTests.swift`

**Interfaces:**
- Consumes: `MessageContent.voice`, `MessageContent.file` from Task 1
- Wire format voice: `type=2, searchableContent="[语音]", content={"duration":N}, remoteMediaURL=url`
- Wire format file: `type=5, searchableContent=filename, content="\(size)", remoteMediaURL=url`

- [ ] **Step 1: 在 `MessageContentCodec` 中新增 voice 的私有 wire struct**

```swift
private struct VoiceWireContent: Codable {
    let duration: Int
}
```

- [ ] **Step 2: 在 `encode(_:)` 的 switch 中新增 voice 和 file case**

```swift
case .voice(let remoteURL, _, let duration):
    wire.type = 2
    wire.searchableContent = "[语音]"
    if let data = try? JSONEncoder().encode(VoiceWireContent(duration: duration)) {
        wire.data = data
    }
    if let remoteURL { wire.remoteMediaURL = remoteURL }

case .file(let name, let size, let remoteURL, _):
    wire.type = 5
    wire.searchableContent = name
    wire.content = "\(size)"
    if let remoteURL { wire.remoteMediaURL = remoteURL }
```

- [ ] **Step 3: 在 `decode(_:)` 的 switch 中新增 case 2 和 case 5**

```swift
case 2:
    let duration = wire.hasData
        ? ((try? JSONDecoder().decode(VoiceWireContent.self, from: wire.data))?.duration ?? 0)
        : 0
    return .voice(remoteURL: wire.hasRemoteMediaURL ? wire.remoteMediaURL : nil, localPath: nil, duration: duration)

case 5:
    let name = wire.hasSearchableContent ? wire.searchableContent : ""
    let size = Int(wire.hasContent ? wire.content : "0") ?? 0
    return .file(name: name, size: size, remoteURL: wire.hasRemoteMediaURL ? wire.remoteMediaURL : nil, localPath: nil)
```

- [ ] **Step 4: 检查 `wire.content` 字段名是否在 `Im_MessageContent` proto 中存在（如字段名不同需调整）**

```bash
grep -r "content\|searchableContent\|remoteMediaURL" /Users/liaojinlong/Share/GitWorkplace/github/fshare/ios-chat-pro/Sources/IMProto/ | head -20
```

- [ ] **Step 5: 写单元测试**

```swift
// Tests/IMMessagingTests/MessageContentCodecTests.swift
func test_encodeDecodeVoice() throws {
    let original = MessageContent.voice(remoteURL: "https://cdn/a.m4a", localPath: nil, duration: 12)
    let wire = MessageContentCodec.encode(original)
    XCTAssertEqual(wire.type, 2)
    XCTAssertEqual(wire.searchableContent, "[语音]")
    let decoded = try MessageContentCodec.decode(wire)
    if case .voice(let url, _, let d) = decoded {
        XCTAssertEqual(url, "https://cdn/a.m4a")
        XCTAssertEqual(d, 12)
    } else { XCTFail() }
}

func test_encodeDecodeFile() throws {
    let original = MessageContent.file(name: "report.pdf", size: 204800, remoteURL: "https://cdn/f.pdf", localPath: nil)
    let wire = MessageContentCodec.encode(original)
    XCTAssertEqual(wire.type, 5)
    XCTAssertEqual(wire.searchableContent, "report.pdf")
    let decoded = try MessageContentCodec.decode(wire)
    if case .file(let name, let size, let url, _) = decoded {
        XCTAssertEqual(name, "report.pdf")
        XCTAssertEqual(size, 204800)
        XCTAssertEqual(url, "https://cdn/f.pdf")
    } else { XCTFail() }
}
```

- [ ] **Step 6: 运行测试**

```bash
swift test --filter IMMessagingTests
```

- [ ] **Step 7: Commit**

```bash
git add Sources/IMMessaging/MessageContentCodec.swift Tests/IMMessagingTests/MessageContentCodecTests.swift
git commit -m "feat(IMMessaging): codec support for voice(type=2) and file(type=5) messages"
```

---

## Task 3：IMMedia — 重构 MediaUploadService，支持 voice 和 file 上传

**Files:**
- Modify: `Sources/IMMedia/MediaUploadService.swift`
- Create: `Sources/IMKit/VoiceUploading.swift`
- Create: `Sources/IMKit/FileUploading.swift`

**Interfaces:**
- Produces:
  - `protocol VoiceUploading { func uploadVoice(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void) }`
  - `protocol FileUploading { func uploadFile(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void) }`
  - `MediaUploadService: ImageUploading & VoiceUploading & FileUploading`

**MinIO mediaType 对照（Android `MessageContentMediaType`）：**
- IMAGE = 1（已有）
- VOICE = 2（新增）
- FILE = 4（新增，注意：消息 wire type=5，但上传 mediaType=4）

- [ ] **Step 1: 在 `MediaUploadService` 中提取私有通用上传方法**

```swift
private func upload(
    _ data: Data,
    mediaType: Int32,
    fileName: String,
    completion: @escaping (Result<String, MediaUploadError>) -> Void
) {
    let key = "\(mediaType)-\(imClient.userId)-\(nowMillis())-\(fileName)"
    var wireRequest = Im_GetMinioUploadUrlRequest()
    wireRequest.type = mediaType
    wireRequest.key = key
    guard let body = try? wireRequest.serializedData() else {
        completion(.failure(.requestEncodingFailed))
        return
    }
    let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gmurl, body: body)
    tracker.track(wireMessageId: wireMessageId) { [weak self] result in
        guard let self else { return }
        switch result {
        case .failure(let error): completion(.failure(.wireError(error)))
        case .success(let uploadResult):
            Task { await self.performUpload(data: data, uploadResult: uploadResult, key: key, completion: completion) }
        }
    }
}
```

- [ ] **Step 2: 把现有 `uploadImage` 改为调用通用方法**

```swift
public func uploadImage(_ data: Data, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
    upload(data, mediaType: 1, fileName: "\(nowMillis()).png", completion: completion)
}
```

- [ ] **Step 3: 新增 `uploadVoice` 和 `uploadFile`**

```swift
public func uploadVoice(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
    upload(data, mediaType: 2, fileName: fileName, completion: completion)
}

public func uploadFile(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
    upload(data, mediaType: 4, fileName: fileName, completion: completion)
}
```

- [ ] **Step 4: 创建 `VoiceUploading.swift`**

```swift
import Foundation
import IMMedia

public protocol VoiceUploading: AnyObject {
    func uploadVoice(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void)
}

extension MediaUploadService: VoiceUploading {}
```

- [ ] **Step 5: 创建 `FileUploading.swift`**

```swift
import Foundation
import IMMedia

public protocol FileUploading: AnyObject {
    func uploadFile(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void)
}

extension MediaUploadService: FileUploading {}
```

- [ ] **Step 6: 确认编译通过**

```bash
swift build 2>&1 | grep -E "error:|warning:" | head -20
```

- [ ] **Step 7: Commit**

```bash
git add Sources/IMMedia/MediaUploadService.swift Sources/IMKit/VoiceUploading.swift Sources/IMKit/FileUploading.swift
git commit -m "feat(IMMedia): refactor MediaUploadService with unified upload, add voice/file upload support"
```

---

## Task 4：IMKit + IMMessaging — sendVoice/sendFile 协议与实现

**Files:**
- Modify: `Sources/IMKit/MessageSending.swift`
- Modify: `Sources/IMMessaging/MessagingService.swift`
- Modify: `Sources/IMKit/ConversationViewModel.swift`

**Interfaces:**
- Consumes: `VoiceUploading`, `FileUploading` from Task 3; `MessageContent.voice/.file` from Task 1
- Produces:
  - `MessageSending.sendVoice(to:conversationType:line:remoteURL:duration:) throws`
  - `MessageSending.sendFile(to:conversationType:line:name:size:remoteURL:) throws`
  - `ConversationViewModel.sendVoice(audioData:duration:fileName:)`
  - `ConversationViewModel.sendFile(fileData:fileName:)`

- [ ] **Step 1: 在 `MessageSending.swift` 协议中新增两个方法**

```swift
func sendVoice(to target: String, conversationType: ConversationType, line: Int, remoteURL: String, duration: Int) throws
func sendFile(to target: String, conversationType: ConversationType, line: Int, name: String, size: Int, remoteURL: String) throws
```

- [ ] **Step 2: 在 `MessagingService.swift` 中实现两个方法**

```swift
public func sendVoice(to target: String, conversationType: ConversationType = .single, line: Int = 0, remoteURL: String, duration: Int) throws {
    try send(to: target, conversationType: conversationType, line: line,
             content: .voice(remoteURL: remoteURL, localPath: nil, duration: duration),
             mentionedType: 0, mentionedTargets: [])
}

public func sendFile(to target: String, conversationType: ConversationType = .single, line: Int = 0, name: String, size: Int, remoteURL: String) throws {
    try send(to: target, conversationType: conversationType, line: line,
             content: .file(name: name, size: size, remoteURL: remoteURL, localPath: nil),
             mentionedType: 0, mentionedTargets: [])
}
```

- [ ] **Step 3: 在 `ConversationViewModel.swift` 中新增 voiceUploading 和 fileUploading 依赖**

```swift
private let voiceUploading: VoiceUploading?
private let fileUploading: FileUploading?
```

在 `init` 参数中新增：
```swift
voiceUploading: VoiceUploading? = nil,
fileUploading: FileUploading? = nil,
```
并在 init 体中赋值：`self.voiceUploading = voiceUploading; self.fileUploading = fileUploading`

- [ ] **Step 4: 新增 `sendVoice` 和 `sendFile` 方法**

```swift
public func sendVoice(audioData: Data, duration: Int, fileName: String) {
    voiceUploading?.uploadVoice(audioData, fileName: fileName) { [weak self] result in
        guard let self else { return }
        if case .success(let url) = result {
            try? self.messageSending?.sendVoice(to: self.target, conversationType: self.conversationType, line: self.line, remoteURL: url, duration: duration)
        }
    }
}

public func sendFile(fileData: Data, fileName: String) {
    let size = fileData.count
    fileUploading?.uploadFile(fileData, fileName: fileName) { [weak self] result in
        guard let self else { return }
        if case .success(let url) = result {
            try? self.messageSending?.sendFile(to: self.target, conversationType: self.conversationType, line: self.line, name: fileName, size: size, remoteURL: url)
        }
    }
}
```

- [ ] **Step 5: 确认编译通过（包含 MessagingService 对协议的符合）**

```bash
swift build 2>&1 | grep "error:" | head -10
```

- [ ] **Step 6: Commit**

```bash
git add Sources/IMKit/MessageSending.swift Sources/IMMessaging/MessagingService.swift Sources/IMKit/ConversationViewModel.swift
git commit -m "feat(IMKit): add sendVoice/sendFile to protocol, ViewModel, and MessagingService"
```

---

## Task 5：App — EmojiPanelView

**Files:**
- Create: `App/EmojiPanelView.swift`

**Interfaces:**
- Produces:
  - `class EmojiPanelView: UIView`
  - `var onEmojiTapped: ((String) -> Void)?` — 返回 emoji 字符串
  - `var onDeleteTapped: (() -> Void)?` — 退格
- 面板高度：260pt，固定

**Emoji 数据：** 130 个来自 Android `emoji.xml` 的 Unicode 码点，转为 Swift String：
```swift
private static let emojis: [String] = [
    "😃","😀","😊","☺️","😉","😍","😘","😙","😜","😝","😒","😌","😔","😞","😟",
    "😠","😡","😢","😂","😪","😥","😰","😓","😭","😖","😣","😤","😩","😫","😨",
    "😱","😵","😲","😳","😯","😴","😷","😎","😆","😋","😛","😜","😝","😒","😏",
    "😀","😸","😹","😺","😻","😼","😽","🙀","😿","😾","🙈","🙉","🙊","💀","👽",
    "💩","🔥","✨","🌟","💫","💥","💢","💦","💧","💤","👂","👀","👃","👅","👄",
    "👍","👎","👌","👊","✊","✌️","👋","✋","👐","👆","👇","👉","👈","🙌","🙏",
    "☝️","👏","💪","🚶","🏃","💃","👫","👪","👬","👭","💏","💑","👶","👦","👧",
    "👱","👩","👴","👵","👲","👳","👮","👷","💂","🎅","👸","👰","🚀","🎩","👑",
    "💼","👜","👝","🎒","💰","💳","📱","📷","📚","✏️","🏠","🚽","💡","📢","⏰",
    "⏳","💣","🔫","💊","🌍","🚀"
]
```

- [ ] **Step 1: 创建 `EmojiPanelView.swift`**

```swift
import UIKit

final class EmojiPanelView: UIView {
    static let panelHeight: CGFloat = 260

    var onEmojiTapped: ((String) -> Void)?
    var onDeleteTapped: (() -> Void)?

    private static let emojis: [String] = [
        "😃","😀","😊","☺️","😉","😍","😘","😙","😜","😝","😒","😌","😔","😞","😟",
        "😠","😡","😢","😂","😪","😥","😰","😓","😭","😖","😣","😤","😩","😫","😨",
        "😱","😵","😲","😳","😯","😴","😷","😎","😆","😋","😛","😃","😀","😒","😏",
        "😸","😹","😺","😻","😼","😽","🙀","😿","😾","🙈","🙉","🙊","💀","👽","💩",
        "🔥","✨","🌟","💫","💥","💢","💦","💧","💤","👂","👀","👃","👅","👄","👍",
        "👎","👌","👊","✊","✌️","👋","✋","👐","👆","👇","👉","👈","🙌","🙏","☝️",
        "👏","💪","🚶","🏃","💃","👫","👪","👬","👭","💏","💑","👶","👦","👧","👱",
        "👩","👴","👵","👲","👳","👮","👷","💂","🎅","👸","👰","🎩","👑","💼","👜",
        "👝","🎒","💰","💳","📱","📷","📚","✏️","🏠","💡","📢","⏰","⏳","💣","💊","🌍"
    ]
    // 每页 20 个表情 + 1 退格键 = 21 格；7列 × 3行
    private static let columns = 7
    private static let rows = 3
    private static let perPage = columns * rows - 1  // 20

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.isPagingEnabled = true
        cv.showsHorizontalScrollIndicator = false
        cv.backgroundColor = .clear
        cv.register(EmojiCell.self, forCellWithReuseIdentifier: "EmojiCell")
        cv.dataSource = self
        cv.delegate = self
        return cv
    }()

    private let pageControl = UIPageControl()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        addSubview(collectionView)
        addSubview(pageControl)
        pageControl.currentPageIndicatorTintColor = Theme.accent
        pageControl.pageIndicatorTintColor = Theme.accent.withAlphaComponent(0.3)
        let pageCount = Int(ceil(Double(Self.emojis.count) / Double(Self.perPage)))
        pageControl.numberOfPages = pageCount
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: pageControl.topAnchor, constant: -4),
            pageControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4),
            pageControl.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let w = collectionView.bounds.width / CGFloat(Self.columns)
            let h = (collectionView.bounds.height) / CGFloat(Self.rows)
            layout.itemSize = CGSize(width: w, height: h)
            layout.sectionInset = .zero
        }
    }
}

extension EmojiPanelView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let pages = Int(ceil(Double(Self.emojis.count) / Double(Self.perPage)))
        return pages * (Self.perPage + 1)  // 每页 21 格（含退格）
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EmojiCell", for: indexPath) as! EmojiCell
        let pageIndex = indexPath.item / (Self.perPage + 1)
        let itemInPage = indexPath.item % (Self.perPage + 1)
        if itemInPage == Self.perPage {
            cell.configure(emoji: nil, isDelete: true)
        } else {
            let emojiIndex = pageIndex * Self.perPage + itemInPage
            let emoji = emojiIndex < Self.emojis.count ? Self.emojis[emojiIndex] : nil
            cell.configure(emoji: emoji, isDelete: false)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let itemInPage = indexPath.item % (Self.perPage + 1)
        if itemInPage == Self.perPage {
            onDeleteTapped?()
        } else {
            let pageIndex = indexPath.item / (Self.perPage + 1)
            let emojiIndex = pageIndex * Self.perPage + itemInPage
            guard emojiIndex < Self.emojis.count else { return }
            onEmojiTapped?(Self.emojis[emojiIndex])
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let page = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        pageControl.currentPage = page
    }
}

private final class EmojiCell: UICollectionViewCell {
    private let label = UILabel()
    private let deleteLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 26)
        label.textAlignment = .center
        deleteLabel.text = "⌫"
        deleteLabel.font = .systemFont(ofSize: 20)
        deleteLabel.textAlignment = .center
        deleteLabel.textColor = .secondaryLabel
        for v in [label, deleteLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                v.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(emoji: String?, isDelete: Bool) {
        label.isHidden = isDelete || emoji == nil
        deleteLabel.isHidden = !isDelete
        label.text = emoji
    }
}
```

- [ ] **Step 2: 确认编译通过**

```bash
swift build 2>&1 | grep "error:" | head -10
```

- [ ] **Step 3: Commit**

```bash
git add App/EmojiPanelView.swift
git commit -m "feat(App): add EmojiPanelView with 130 emoji + backspace, paged collectionView"
```

---

## Task 6：App — ExtPanelView（更多功能面板）

**Files:**
- Create: `App/ExtPanelView.swift`

**Interfaces:**
- Produces:
  - `class ExtPanelView: UIView`
  - `var onAlbum: (() -> Void)?`
  - `var onCamera: (() -> Void)?`
  - `var onFile: (() -> Void)?`
- 面板高度：260pt（与 EmojiPanelView 一致）

- [ ] **Step 1: 创建 `ExtPanelView.swift`**

```swift
import UIKit

final class ExtPanelView: UIView {
    static let panelHeight: CGFloat = 260

    var onAlbum: (() -> Void)?
    var onCamera: (() -> Void)?
    var onFile: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        let items: [(icon: String, title: String, action: Selector)] = [
            ("photo.on.rectangle", "相册", #selector(albumTapped)),
            ("camera", "拍摄", #selector(cameraTapped)),
            ("doc", "文件", #selector(fileTapped)),
        ]
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.heightAnchor.constraint(equalToConstant: 100),
        ])
        for item in items {
            let btn = makeButton(icon: item.icon, title: item.title, action: item.action)
            stack.addArrangedSubview(btn)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func makeButton(icon: String, title: String, action: Selector) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 8

        let iconContainer = UIView()
        iconContainer.backgroundColor = Theme.backgroundTertiary
        iconContainer.layer.cornerRadius = 12
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 60),
            iconContainer.heightAnchor.constraint(equalToConstant: 60),
        ])

        let img = UIImageView(image: UIImage(systemName: icon))
        img.tintColor = Theme.accent
        img.contentMode = .scaleAspectFit
        img.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(img)
        NSLayoutConstraint.activate([
            img.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            img.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 30),
            img.heightAnchor.constraint(equalToConstant: 30),
        ])

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel

        let tap = UITapGestureRecognizer(target: self, action: action)
        iconContainer.addGestureRecognizer(tap)
        iconContainer.isUserInteractionEnabled = true

        container.addArrangedSubview(iconContainer)
        container.addArrangedSubview(label)
        return container
    }

    @objc private func albumTapped() { onAlbum?() }
    @objc private func cameraTapped() { onCamera?() }
    @objc private func fileTapped() { onFile?() }
}
```

- [ ] **Step 2: Commit**

```bash
git add App/ExtPanelView.swift
git commit -m "feat(App): add ExtPanelView with album/camera/file buttons"
```

---

## Task 7：App — VoiceMessageCell 和 FileMessageCell

**Files:**
- Create: `App/VoiceMessageCell.swift`
- Create: `App/FileMessageCell.swift`

**Interfaces:**
- Consumes: `StoredMessageRow` from `ChatMessageRow.swift`
- `VoiceMessageCell.reuseIdentifier = "VoiceMessageCell"`
- `FileMessageCell.reuseIdentifier = "FileMessageCell"`

**注意：** `StoredMessageRow` 的 `text` 字段此时已包含格式化后的内容（"[语音] 12秒" 或 "[文件] report.pdf 200KB"），由 Task 1 的 `makeRow` 负责生成。Cell 只负责显示，无需自己解析。

- [ ] **Step 1: 创建 `VoiceMessageCell.swift`**

参考 `TextMessageCell.swift` 的气泡布局，显示语音图标 + 时长文字，右侧（发送）或左侧（接收）对齐：

```swift
import UIKit
import IMKit

final class VoiceMessageCell: UITableViewCell {
    static let reuseIdentifier = "VoiceMessageCell"

    private let bubbleView = UIView()
    private let iconView = UIImageView()
    private let durationLabel = UILabel()
    private let avatarView = AvatarImageView()
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        bubbleView.layer.cornerRadius = 16
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.image = UIImage(systemName: "waveform")
        durationLabel.font = .systemFont(ofSize: 15)
        durationLabel.textColor = .white

        let hStack = UIStackView(arrangedSubviews: [iconView, durationLabel])
        hStack.axis = .horizontal
        hStack.spacing = 6
        hStack.alignment = .center

        for v in [bubbleView, avatarView, hStack] { v.translatesAutoresizingMaskIntoConstraints = false }
        hStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarView)
        contentView.addSubview(bubbleView)
        bubbleView.addSubview(hStack)

        leadingConstraint = bubbleView.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 8)
        trailingConstraint = bubbleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubbleView.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            hStack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 10),
            hStack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10),
            hStack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 14),
            hStack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -14),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(with row: StoredMessageRow) {
        let isOutgoing = row.isOutgoing
        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.backgroundSecondary
        durationLabel.textColor = isOutgoing ? .white : .label
        iconView.tintColor = isOutgoing ? .white : Theme.accent

        // 解析 "[语音] 12秒" 中的时长
        let text = row.text ?? ""
        durationLabel.text = text.components(separatedBy: " ").dropFirst().first ?? ""

        leadingConstraint.isActive = !isOutgoing
        trailingConstraint.isActive = isOutgoing

        if isOutgoing {
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor).isActive = false
            avatarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12).isActive = true
        } else {
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12).isActive = true
        }

        if let urlStr = row.senderAvatarURL { avatarView.setImage(urlString: urlStr) }
    }
}
```

- [ ] **Step 2: 创建 `FileMessageCell.swift`**（结构同上，显示文件图标 + 文件名 + 大小）

```swift
import UIKit
import IMKit

final class FileMessageCell: UITableViewCell {
    static let reuseIdentifier = "FileMessageCell"

    private let bubbleView = UIView()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let sizeLabel = UILabel()
    private let avatarView = AvatarImageView()
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        bubbleView.layer.cornerRadius = 16

        iconView.image = UIImage(systemName: "doc.fill")
        iconView.contentMode = .scaleAspectFit

        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.numberOfLines = 2

        sizeLabel.font = .systemFont(ofSize: 12)
        sizeLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [nameLabel, sizeLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let hStack = UIStackView(arrangedSubviews: [iconView, textStack])
        hStack.axis = .horizontal
        hStack.spacing = 10
        hStack.alignment = .center

        for v in [bubbleView, avatarView, hStack] { v.translatesAutoresizingMaskIntoConstraints = false }
        contentView.addSubview(avatarView)
        contentView.addSubview(bubbleView)
        bubbleView.addSubview(hStack)

        leadingConstraint = bubbleView.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 8)
        trailingConstraint = bubbleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubbleView.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            hStack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 12),
            hStack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -12),
            hStack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 14),
            hStack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -14),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(with row: StoredMessageRow) {
        let isOutgoing = row.isOutgoing
        bubbleView.backgroundColor = isOutgoing ? Theme.accent : Theme.backgroundSecondary
        nameLabel.textColor = isOutgoing ? .white : .label
        iconView.tintColor = isOutgoing ? .white : Theme.accent

        // 解析 "[文件] report.pdf 200KB" 中的文件名和大小
        let parts = (row.text ?? "").components(separatedBy: " ")
        nameLabel.text = parts.count > 1 ? parts[1] : ""
        sizeLabel.text = parts.count > 2 ? parts[2] : ""

        if isOutgoing {
            trailingConstraint.isActive = true
            leadingConstraint.isActive = false
            avatarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12).isActive = true
        } else {
            leadingConstraint.isActive = true
            trailingConstraint.isActive = false
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12).isActive = true
        }

        if let urlStr = row.senderAvatarURL { avatarView.setImage(urlString: urlStr) }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add App/VoiceMessageCell.swift App/FileMessageCell.swift
git commit -m "feat(App): add VoiceMessageCell and FileMessageCell bubble cells"
```

---

## Task 8：App — 重写 MessageInputBar

**Files:**
- Modify: `App/MessageInputBar.swift`（完整重写）

**Interfaces:**
- Consumes: `EmojiPanelView`, `ExtPanelView` from Tasks 5/6
- Produces（对外 callback）：
  - `var onSendText: ((_ text: String, _ mentionedType: Int32, _ mentionedTargets: [String]) -> Void)?`（已有）
  - `var onPickImage: (() -> Void)?`（已有，现在由 ExtPanel 触发）
  - `var onCamera: (() -> Void)?`（新）
  - `var onPickFile: (() -> Void)?`（新）
  - `var onSendVoice: ((_ audioData: Data, _ duration: Int, _ fileName: String) -> Void)?`（新）
  - `var onMentionTriggered: (() -> Void)?`（已有）
  - `func insertMention(uid:displayName:)`（已有）
  - `func removeTrailingMentionTrigger()`（已有）

**三态面板互斥状态机：**
```
.keyboard   — 系统键盘显示，自定义面板隐藏
.emoji      — emoji 面板显示，键盘收起
.ext        — 更多面板显示，键盘收起
.voice      — 语音录制模式，输入框隐藏换成录音按钮
```

- [ ] **Step 1: 完整重写 `MessageInputBar.swift`**（见下方完整代码）

```swift
import UIKit
import AVFoundation

final class MessageInputBar: UIView {

    // MARK: - Public callbacks
    var onSendText: ((_ text: String, _ mentionedType: Int32, _ mentionedTargets: [String]) -> Void)?
    var onPickImage: (() -> Void)?
    var onCamera: (() -> Void)?
    var onPickFile: (() -> Void)?
    var onSendVoice: ((_ audioData: Data, _ duration: Int, _ fileName: String) -> Void)?
    var onMentionTriggered: (() -> Void)?

    // MARK: - Mention state
    private var mentionedType: Int32 = 0
    private var mentionedTargets: [String] = []

    // MARK: - Panel state
    private enum PanelState { case none, emoji, ext }
    private var panelState: PanelState = .none
    private var isVoiceMode = false

    // MARK: - Input bar subviews
    private let voiceToggleButton = UIButton(type: .system)
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let recordButton = UIButton(type: .system)   // "按住说话"
    private let emojiButton = UIButton(type: .system)
    private let extButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private var textViewHeightConstraint: NSLayoutConstraint!

    // MARK: - Panels
    private let emojiPanel = EmojiPanelView()
    private let extPanel = ExtPanelView()

    // MARK: - Voice recording
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartTime: Date?
    private var recordingTimer: Timer?
    private var recordingURL: URL?

    // MARK: - Panel height constraint (emoji/ext)
    private var panelHeightConstraint: NSLayoutConstraint!
    private var panelBottomConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        setupInputBar()
        setupPanels()
        wireCallbacks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API (mention)
    func insertMention(uid: String?, displayName: String) {
        textView.text += "@\(displayName) "
        if let uid {
            if mentionedType != 2 { mentionedType = 1; mentionedTargets.append(uid) }
        } else {
            mentionedType = 2; mentionedTargets = []
        }
        textViewDidChange(textView)
    }

    func removeTrailingMentionTrigger() {
        guard textView.text.hasSuffix("@") else { return }
        textView.text.removeLast()
        textViewDidChange(textView)
    }

    // MARK: - Keyboard driven collapse
    func collapseCustomPanels() {
        guard panelState != .none else { return }
        panelState = .none
        updatePanelVisibility(animated: true)
    }

    // MARK: - Layout
    private func setupInputBar() {
        // Voice toggle
        voiceToggleButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        voiceToggleButton.tintColor = Theme.accent
        voiceToggleButton.addTarget(self, action: #selector(voiceToggleTapped), for: .touchUpInside)

        // TextView
        textView.font = .systemFont(ofSize: 16)
        textView.backgroundColor = Theme.backgroundTertiary
        textView.layer.cornerRadius = Theme.cardCornerRadius
        textView.isScrollEnabled = false
        textView.delegate = self

        // Placeholder
        placeholderLabel.text = "发消息..."
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .systemFont(ofSize: 16)

        // Record button (voice mode)
        recordButton.setTitle("按住说话", for: .normal)
        recordButton.titleLabel?.font = .systemFont(ofSize: 16)
        recordButton.backgroundColor = Theme.backgroundTertiary
        recordButton.layer.cornerRadius = Theme.cardCornerRadius
        recordButton.isHidden = true
        recordButton.addTarget(self, action: #selector(recordTouchDown), for: .touchDown)
        recordButton.addTarget(self, action: #selector(recordTouchUp), for: [.touchUpInside, .touchUpOutside])
        recordButton.addTarget(self, action: #selector(recordTouchCancel), for: .touchCancel)

        // Emoji button
        emojiButton.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        emojiButton.tintColor = Theme.accent
        emojiButton.addTarget(self, action: #selector(emojiTapped), for: .touchUpInside)

        // Ext button
        extButton.setImage(UIImage(systemName: "plus.circle"), for: .normal)
        extButton.tintColor = Theme.accent
        extButton.addTarget(self, action: #selector(extTapped), for: .touchUpInside)

        // Send button
        sendButton.setTitle("发送", for: .normal)
        sendButton.tintColor = Theme.accent
        sendButton.isHidden = true
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        let inputRowViews: [UIView] = [voiceToggleButton, textView, recordButton, emojiButton, extButton, sendButton]
        inputRowViews.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)

        NSLayoutConstraint.activate([
            voiceToggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            voiceToggleButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            voiceToggleButton.widthAnchor.constraint(equalToConstant: 32),
            voiceToggleButton.heightAnchor.constraint(equalToConstant: 32),

            textView.leadingAnchor.constraint(equalTo: voiceToggleButton.trailingAnchor, constant: 6),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            textViewHeightConstraint,

            recordButton.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            recordButton.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            recordButton.topAnchor.constraint(equalTo: textView.topAnchor),
            recordButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 8),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.topAnchor, constant: 18),

            emojiButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 6),
            emojiButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            emojiButton.widthAnchor.constraint(equalToConstant: 32),
            emojiButton.heightAnchor.constraint(equalToConstant: 32),

            extButton.leadingAnchor.constraint(equalTo: emojiButton.trailingAnchor, constant: 4),
            extButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            extButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            extButton.widthAnchor.constraint(equalToConstant: 32),
            extButton.heightAnchor.constraint(equalToConstant: 32),

            sendButton.leadingAnchor.constraint(equalTo: emojiButton.trailingAnchor, constant: 4),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
        ])
    }

    private func setupPanels() {
        emojiPanel.translatesAutoresizingMaskIntoConstraints = false
        extPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emojiPanel)
        addSubview(extPanel)
        emojiPanel.isHidden = true
        extPanel.isHidden = true

        let panelTop = safeAreaLayoutGuide.bottomAnchor   // anchored at bottom initially collapsed
        NSLayoutConstraint.activate([
            emojiPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            emojiPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            emojiPanel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 8),
            emojiPanel.heightAnchor.constraint(equalToConstant: EmojiPanelView.panelHeight),

            extPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            extPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            extPanel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 8),
            extPanel.heightAnchor.constraint(equalToConstant: ExtPanelView.panelHeight),
        ])
    }

    private func wireCallbacks() {
        emojiPanel.onEmojiTapped = { [weak self] emoji in
            self?.textView.insertText(emoji)
        }
        emojiPanel.onDeleteTapped = { [weak self] in
            guard let tv = self?.textView, !tv.text.isEmpty else { return }
            tv.deleteBackward()
            self?.textViewDidChange(tv)
        }
        extPanel.onAlbum = { [weak self] in self?.onPickImage?() }
        extPanel.onCamera = { [weak self] in self?.onCamera?() }
        extPanel.onFile = { [weak self] in self?.onPickFile?() }
    }

    // MARK: - Button Actions
    @objc private func voiceToggleTapped() {
        isVoiceMode.toggle()
        textView.isHidden = isVoiceMode
        recordButton.isHidden = !isVoiceMode
        let icon = isVoiceMode ? "keyboard" : "mic.fill"
        voiceToggleButton.setImage(UIImage(systemName: icon), for: .normal)
        if isVoiceMode {
            textView.resignFirstResponder()
            collapseCustomPanels()
        }
    }

    @objc private func emojiTapped() {
        if panelState == .emoji {
            panelState = .none
            textView.becomeFirstResponder()
        } else {
            panelState = .emoji
            textView.resignFirstResponder()
        }
        updatePanelVisibility(animated: true)
    }

    @objc private func extTapped() {
        if panelState == .ext {
            panelState = .none
            textView.becomeFirstResponder()
        } else {
            panelState = .ext
            textView.resignFirstResponder()
        }
        updatePanelVisibility(animated: true)
    }

    @objc private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSendText?(text, mentionedType, mentionedTargets)
        textView.text = ""
        mentionedType = 0; mentionedTargets = []
        placeholderLabel.isHidden = false
        updateSendExtVisibility()
        updateHeight()
    }

    // MARK: - Voice Recording
    @objc private func recordTouchDown() {
        startRecording()
        recordButton.setTitle("松开发送 (上滑取消)", for: .normal)
    }

    @objc private func recordTouchUp() {
        guard let url = recordingURL, let start = recordingStartTime else { return }
        stopRecording()
        let duration = Int(Date().timeIntervalSince(start))
        guard duration >= 1 else { resetRecordButton(); return }
        guard let data = try? Data(contentsOf: url) else { resetRecordButton(); return }
        let fileName = url.lastPathComponent
        onSendVoice?(data, duration, fileName)
        resetRecordButton()
    }

    @objc private func recordTouchCancel() {
        stopRecording()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        resetRecordButton()
    }

    private func resetRecordButton() { recordButton.setTitle("按住说话", for: .normal) }

    private func startRecording() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            guard granted else { return }
            DispatchQueue.main.async {
                let fileName = "voice-\(Int(Date().timeIntervalSince1970)).m4a"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                self.recordingURL = url
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                ]
                self.audioRecorder = try? AVAudioRecorder(url: url, settings: settings)
                self.audioRecorder?.record()
                self.recordingStartTime = Date()
            }
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
    }

    // MARK: - Layout helpers
    private func updatePanelVisibility(animated: Bool) {
        emojiPanel.isHidden = panelState != .emoji
        extPanel.isHidden = panelState != .ext
        let icon = panelState == .emoji ? "keyboard" : "face.smiling"
        emojiButton.setImage(UIImage(systemName: icon), for: .normal)
    }

    private func updateSendExtVisibility() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isHidden = !hasText
        extButton.isHidden = hasText
    }

    private func updateHeight() {
        let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        let capped = min(max(size.height, 36), 120)
        textView.isScrollEnabled = size.height > 120
        textViewHeightConstraint.constant = capped
    }
}

// MARK: - UITextViewDelegate
extension MessageInputBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateSendExtVisibility()
        updateHeight()
        if textView.text.hasSuffix("@") { onMentionTriggered?() }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if panelState != .none {
            panelState = .none
            updatePanelVisibility(animated: false)
        }
    }
}
```

- [ ] **Step 2: 确认编译通过**

```bash
swift build 2>&1 | grep "error:" | head -10
```

- [ ] **Step 3: Commit**

```bash
git add App/MessageInputBar.swift
git commit -m "feat(App): rewrite MessageInputBar with voice/emoji/ext panels aligned to Android design"
```

---

## Task 9：App — ConversationViewController 串联所有功能

**Files:**
- Modify: `App/ConversationViewController.swift`

**修改点：**
1. 注册 `VoiceMessageCell`、`FileMessageCell`
2. 在 `bindInputBar()` 中接入新回调：`onCamera`、`onPickFile`、`onSendVoice`
3. 在 `tableView(_:cellForRowAt:)` 中处理新 cell 类型
4. 将 `ConversationViewModel` 初始化传入 `voiceUploading` 和 `fileUploading`

- [ ] **Step 1: 注册新 Cell**

在 `layoutViews()` 的 `tableView.register(...)` 块中新增：
```swift
tableView.register(VoiceMessageCell.self, forCellReuseIdentifier: VoiceMessageCell.reuseIdentifier)
tableView.register(FileMessageCell.self, forCellReuseIdentifier: FileMessageCell.reuseIdentifier)
```

- [ ] **Step 2: 接入 onCamera（拍摄）**

```swift
inputBar.onCamera = { [weak self] in self?.presentCamera() }

private func presentCamera() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = self
    present(picker, animated: true)
}
```

在已有的 `UINavigationControllerDelegate & UIImagePickerControllerDelegate` extension 中实现（或新增）：
```swift
func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage,
          let fullData = image.jpegData(compressionQuality: 0.8),
          let thumbnail = image.jpegData(compressionQuality: 0.2) else { return }
    viewModel.sendImage(fullImageData: fullData, thumbnail: thumbnail)
}
```

- [ ] **Step 3: 接入 onPickFile（文件选择）**

```swift
inputBar.onPickFile = { [weak self] in self?.presentFilePicker() }

private func presentFilePicker() {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .pdf, .text, .image])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
}
```

```swift
extension ConversationViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        viewModel.sendFile(fileData: data, fileName: url.lastPathComponent)
    }
}
```

- [ ] **Step 4: 接入 onSendVoice**

```swift
inputBar.onSendVoice = { [weak self] audioData, duration, fileName in
    self?.viewModel.sendVoice(audioData: audioData, duration: duration, fileName: fileName)
}
```

- [ ] **Step 5: 在 dataSource 中处理新 cell（`cellForRowAt`）**

在已有的 `UITableViewDataSource` 配置中，根据 text 前缀判断 cell 类型（或基于 `StoredMessageRow` 的内容类型字段判断）：

```swift
// 在 dataSource.cellProvider 中，case .message(let row):
if row.text?.hasPrefix("[语音]") == true {
    let cell = tableView.dequeueReusableCell(withIdentifier: VoiceMessageCell.reuseIdentifier, for: indexPath) as! VoiceMessageCell
    cell.configure(with: row)
    return cell
} else if row.text?.hasPrefix("[文件]") == true {
    let cell = tableView.dequeueReusableCell(withIdentifier: FileMessageCell.reuseIdentifier, for: indexPath) as! FileMessageCell
    cell.configure(with: row)
    return cell
}
// else 走现有 TextMessageCell / ImageMessageCell
```

**注意：** 此处用文本前缀判断是临时方案，若后续需要更精确的区分，应在 `StoredMessageRow` 中增加 `contentType` 字段（另一个迭代）。

- [ ] **Step 6: 将 voiceUploading/fileUploading 传入 ViewModel**

在 `AppEnvironment` 或 `SceneDelegate` 中构造 `ConversationViewModel` 的地方，传入 `MediaUploadService` 实例作为 `voiceUploading` 和 `fileUploading`。

- [ ] **Step 7: 确认编译通过**

```bash
swift build 2>&1 | grep "error:" | head -10
```

- [ ] **Step 8: Commit**

```bash
git add App/ConversationViewController.swift
git commit -m "feat(App): wire voice/file/camera into ConversationViewController, register new cells"
```

---

## 验收标准

| 功能 | 验收条件 |
|------|---------|
| 输入栏布局 | 与 Android 截图对齐：🎤 \| 输入框 \| 😊 \| ➕（无文字）或发送（有文字）|
| 语音切换 | 点 🎤 切到"按住说话"按钮，再点切回文本输入 |
| Emoji 面板 | 点 😊 弹出面板，点表情插入文本，点 ⌫ 删除字符 |
| 更多面板 | 点 ➕ 弹出面板，三个按钮可点击 |
| 发送图片（相册） | 选图 → 上传 → 消息出现在列表 |
| 拍摄发图 | 调起相机 → 拍照 → 上传 → 消息出现在列表 |
| 发送文件 | 选择文件 → 上传 → 文件消息气泡显示文件名+大小 |
| 语音录制 | 按住录制（≥1秒）→ 松开 → 上传 → 语音消息气泡显示时长 |
| 键盘/面板互斥 | 点击输入框时自定义面板收起，点 😊/➕ 时键盘收起 |
