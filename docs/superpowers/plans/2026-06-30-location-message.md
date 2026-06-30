# 地理位置消息 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 iOS 地理位置消息的完整收发与展示，与 Android `LocationMessageContent`（type=4）wire 格式完全兼容。

**Architecture:** 从底层到顶层分四个任务逐层实现：IMStorage 数据模型 → IMMessaging 编解码+发送 → IMKit ViewModel → App UI。每个任务独立可测，任务间依赖单向向上。

**Tech Stack:** Swift，MapKit，CoreLocation，CLGeocoder，MKMapSnapshotter，GRDB（已有），XCTest

## Global Constraints

- Wire type=4，JSON key 用 `long` 不是 `lng`（与 Android `LocationMessageContent.encode()` 一致）
- 无需 MinIO 上传，缩略图直接走 wire `data`（`binaryContent`）字段
- 零 SQLite schema 变更，所有字段映射到已有列
- 所有代码在主队列调用（无内部锁，现有约定）
- 只请求 `whenInUse` 定位权限，不使用后台定位

---

## 文件变更总览

| 文件 | 操作 |
|---|---|
| `Sources/IMStorage/StoredMessage.swift` | 改 |
| `Sources/IMMessaging/MessageContentCodec.swift` | 改 |
| `Sources/IMMessaging/MessagingService.swift` | 改 |
| `Sources/IMKit/MessageSending.swift` | 改 |
| `Sources/IMKit/ChatMessageRow.swift` | 改 |
| `Sources/IMKit/ConversationViewModel.swift` | 改 |
| `Tests/IMStorageTests/StoredMessageTests.swift` | 改 |
| `Tests/IMMessagingTests/MessageContentCodecTests.swift` | 改 |
| `Tests/IMMessagingTests/MessagingServiceTests.swift` | 改 |
| `Tests/IMKitTests/ConversationViewModelTests.swift` | 改 |
| `App/ExtPanelView.swift` | 改 |
| `App/ConversationViewController.swift` | 改 |
| `App/LocationPickerViewController.swift` | 新建 |
| `App/LocationMessageCell.swift` | 新建 |
| `App/LocationPreviewViewController.swift` | 新建 |
| `App/Info.plist` | 改 |

---

## Task 1: IMStorage — MessageContent.location case + StoredMessage 列映射

**Files:**
- Modify: `Sources/IMStorage/StoredMessage.swift`
- Test: `Tests/IMStorageTests/StoredMessageTests.swift`

**Interfaces:**
- Produces: `MessageContent.location(lat: Double, lng: Double, title: String, thumbnail: Data?)` case，供 Tasks 2、3 使用

---

- [ ] **Step 1: 写失败测试**

在 `Tests/IMStorageTests/StoredMessageTests.swift` 末尾添加新的 `final class LocationMessageTests: XCTestCase`：

```swift
final class LocationMessageTests: XCTestCase {
    func test_locationMessage_initFlattensContentToColumns() {
        let thumbnail = Data([0xAA, 0xBB])
        let message = StoredMessage(
            localMessageId: 10, conversationType: .single, target: "u2", from: "u1",
            content: .location(lat: 31.23, lng: 121.47, title: "上海市中心", thumbnail: thumbnail),
            timestamp: 1_000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.contentType, .location)
        XCTAssertEqual(message.searchableContent, "上海市中心")
        XCTAssertEqual(message.textContent, "{\"lat\":31.23,\"long\":121.47}")
        XCTAssertEqual(message.mediaThumbnail, thumbnail)
        XCTAssertNil(message.mediaRemoteURL)
        XCTAssertNil(message.groupNotificationOperator)
        XCTAssertNil(message.callId)
    }

    func test_locationMessage_contentPropertyRoundTrips() {
        let thumbnail = Data([0xCC])
        let original = MessageContent.location(lat: 39.9, lng: 116.4, title: "北京", thumbnail: thumbnail)
        let message = StoredMessage(
            localMessageId: 11, conversationType: .single, target: "u2", from: "u1",
            content: original, timestamp: 1_000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.content, original)
    }

    func test_locationMessage_nilThumbnail_roundTrips() {
        let original = MessageContent.location(lat: 22.5, lng: 114.1, title: "深圳", thumbnail: nil)
        let message = StoredMessage(
            localMessageId: 12, conversationType: .single, target: "u2", from: "u1",
            content: original, timestamp: 1_000, status: .sent, direction: .send
        )
        XCTAssertEqual(message.content, original)
    }

    func test_locationMessage_setContent_clearsPreviousColumns() {
        var message = StoredMessage(
            localMessageId: 13, conversationType: .single, target: "u2", from: "u1",
            content: .text("hello"), timestamp: 1_000, status: .sent, direction: .send
        )
        message.setContent(.location(lat: 31.0, lng: 121.0, title: "测试", thumbnail: nil))
        XCTAssertNil(message.groupNotificationOperator)
        XCTAssertNil(message.callId)
        XCTAssertEqual(message.contentType, .location)
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
swift test --filter IMStorageTests/LocationMessageTests
```

期望：编译失败，提示 `location` 不是 `MessageContent` 的成员。

- [ ] **Step 3: 在 `MessageContent` 枚举添加 `.location` case**

打开 `Sources/IMStorage/StoredMessage.swift`，在 `case recalled` 下方添加：

```swift
/// Wire type 4. `thumbnail` is the JPEG map screenshot. Coordinates use
/// Android's wire key names: `lat`/`long` (not `lng`).
case location(lat: Double, lng: Double, title: String, thumbnail: Data?)
```

- [ ] **Step 4: 在 `StoredMessage.content` 的 `switch` 中添加 `.location` 分支**

在 `case .recalled:` 下方添加（注意 `LocationCoords` 是本文件私有 struct）：

```swift
case .location:
    struct LocationCoords: Decodable { let lat: Double; let long: Double }
    let coords = textContent
        .flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONDecoder().decode(LocationCoords.self, from: $0) }
    return .location(
        lat: coords?.lat ?? 0,
        lng: coords?.long ?? 0,
        title: searchableContent ?? "",
        thumbnail: mediaThumbnail
    )
```

- [ ] **Step 5: 在 `StoredMessage.setContent` 的 `switch` 中添加 `.location` 分支**

在 `case .recalled` 分支下方添加：

```swift
case .location(let lat, let lng, let title, let thumbnail):
    contentType = .location
    searchableContent = title
    textContent = "{\"lat\":\(lat),\"long\":\(lng)}"
    mediaThumbnail = thumbnail
    mediaRemoteURL = nil
    mediaLocalPath = nil
    groupNotificationOperator = nil
    groupNotificationMembersRaw = nil
    groupNotificationValue = nil
    callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0
```

- [ ] **Step 6: 修复所有因枚举新增 case 导致的 switch 编译错误**

全局搜索 `switch content` 和 `switch message.content`（`grep -rn "case .recalled" Sources/ --include="*.swift"`），在每处 `case .recalled:` 后插入位置消息的 fallthrough 或合并到已有的 exhaustive 模式。目前只在 `StoredMessage.swift` 内部有这两处 switch，不涉及其他文件（IMMessaging/IMKit 的 switch 将在 Task 2、3 中处理）。

- [ ] **Step 7: 运行测试，确认通过**

```bash
swift test --filter IMStorageTests/LocationMessageTests
```

期望：4 个测试全部 PASS。

- [ ] **Step 8: 运行全量存储测试，确认无回归**

```bash
swift test --filter IMStorageTests
```

期望：所有测试 PASS。

- [ ] **Step 9: 提交**

```bash
git add Sources/IMStorage/StoredMessage.swift Tests/IMStorageTests/StoredMessageTests.swift
git commit -m "feat(IMStorage): add MessageContent.location case with zero-migration column mapping"
```

---

## Task 2: IMMessaging — Codec type=4 + MessagingService.sendLocation + MessageSending 协议

**Files:**
- Modify: `Sources/IMMessaging/MessageContentCodec.swift`
- Modify: `Sources/IMMessaging/MessagingService.swift`
- Modify: `Sources/IMKit/MessageSending.swift`
- Test: `Tests/IMMessagingTests/MessageContentCodecTests.swift`
- Test: `Tests/IMMessagingTests/MessagingServiceTests.swift`

**Interfaces:**
- Consumes: `MessageContent.location` from Task 1
- Produces:
  - `MessageContentCodec.encode(.location(...))` → `Im_MessageContent` (type=4)
  - `MessageContentCodec.decode(wire where type==4)` → `.location(...)`
  - `MessagingService.sendLocation(to:conversationType:line:lat:lng:title:thumbnail:)`
  - `MessageSending.sendLocation(to:conversationType:line:lat:lng:title:thumbnail:)` protocol method

---

- [ ] **Step 1: 写失败的 Codec 测试**

在 `Tests/IMMessagingTests/MessageContentCodecTests.swift` 末尾添加：

```swift
func test_encodeLocation_setsType4AndAllWireFields() {
    let thumbnail = Data([0x01, 0x02])
    let wire = MessageContentCodec.encode(
        .location(lat: 31.23, lng: 121.47, title: "上海市中心", thumbnail: thumbnail)
    )
    XCTAssertEqual(wire.type, 4)
    XCTAssertEqual(wire.searchableContent, "上海市中心")
    XCTAssertEqual(wire.data, thumbnail)
    XCTAssertTrue(wire.content.contains("\"lat\":31.23"))
    XCTAssertTrue(wire.content.contains("\"long\":121.47"))
}

func test_decodeType4_parsesAllFields() throws {
    var wire = Im_MessageContent()
    wire.type = 4
    wire.searchableContent = "上海市中心"
    wire.data = Data([0x03, 0x04])
    wire.content = "{\"lat\":31.23,\"long\":121.47}"
    let content = try MessageContentCodec.decode(wire)
    XCTAssertEqual(content, .location(lat: 31.23, lng: 121.47, title: "上海市中心", thumbnail: Data([0x03, 0x04])))
}

func test_decodeType4_missingThumbnail_nilThumbnail() throws {
    var wire = Im_MessageContent()
    wire.type = 4
    wire.searchableContent = "POI"
    wire.content = "{\"lat\":22.5,\"long\":114.1}"
    let content = try MessageContentCodec.decode(wire)
    XCTAssertEqual(content, .location(lat: 22.5, lng: 114.1, title: "POI", thumbnail: nil))
}

func test_locationMessage_roundTrips_throughCodec() throws {
    let original = MessageContent.location(lat: 39.9, lng: 116.4, title: "北京", thumbnail: Data([0xFF]))
    let decoded = try MessageContentCodec.decode(MessageContentCodec.encode(original))
    XCTAssertEqual(decoded, original)
}
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
swift test --filter IMMessagingTests/MessageContentCodecTests/test_encodeLocation_setsType4AndAllWireFields
```

期望：编译失败，`location` 不在 `encode` 的 switch 中。

- [ ] **Step 3: 在 MessageContentCodec 添加 LocationCoords 私有 struct**

在 `Sources/IMMessaging/MessageContentCodec.swift` 中，与 `VoiceWireContent` 等同级添加：

```swift
private struct LocationCoords: Codable {
    let lat: Double
    let long: Double
}
```

- [ ] **Step 4: 在 `encode` 中添加 `.location` 分支**

在 `case .recalled:` 分支下方添加：

```swift
case .location(let lat, let lng, let title, let thumbnail):
    wire.type = 4
    wire.searchableContent = title
    if let thumbnail { wire.data = thumbnail }
    if let json = try? JSONEncoder().encode(LocationCoords(lat: lat, long: lng)),
       let str = String(data: json, encoding: .utf8) {
        wire.content = str
    }
```

- [ ] **Step 5: 在 `decode` 中添加 `case 4` 分支**

在 `case 6:` 分支上方添加（放在数字升序位置）：

```swift
case 4:
    let title = wire.hasSearchableContent ? wire.searchableContent : ""
    let thumbnail: Data? = wire.hasData ? wire.data : nil
    var lat = 0.0, lng = 0.0
    if wire.hasContent,
       let data = wire.content.data(using: .utf8),
       let coords = try? JSONDecoder().decode(LocationCoords.self, from: data) {
        lat = coords.lat; lng = coords.long
    }
    return .location(lat: lat, lng: lng, title: title, thumbnail: thumbnail)
```

- [ ] **Step 6: 运行 Codec 测试，确认通过**

```bash
swift test --filter IMMessagingTests/MessageContentCodecTests
```

期望：全部 PASS。

- [ ] **Step 7: 写失败的 MessagingService 测试**

在 `Tests/IMMessagingTests/MessagingServiceTests.swift` 末尾添加：

```swift
func test_sendLocation_insertsLocalEchoAndSendsCorrectWireFrame() throws {
    let thumbnail = Data([0xAB, 0xCD])
    try service.sendLocation(to: "them", lat: 31.23, lng: 121.47, title: "上海", thumbnail: thumbnail)

    let echo = try storage.messages.messages(conversationType: .single, target: "them").first
    XCTAssertEqual(echo?.content, .location(lat: 31.23, lng: 121.47, title: "上海", thumbnail: thumbnail))
    XCTAssertEqual(echo?.status, .sending)

    let frame = try decodeOnlySentFrame()
    let wireMessage = try Im_Message(serializedBytes: frame.body)
    XCTAssertEqual(try MessageContentCodec.decode(wireMessage.content),
                   .location(lat: 31.23, lng: 121.47, title: "上海", thumbnail: thumbnail))
}
```

- [ ] **Step 8: 运行测试，确认失败**

```bash
swift test --filter IMMessagingTests/MessagingServiceTests/test_sendLocation_insertsLocalEchoAndSendsCorrectWireFrame
```

期望：编译失败，`sendLocation` 不存在。

- [ ] **Step 9: 在 `MessagingService` 添加 `sendLocation` 方法**

在 `Sources/IMMessaging/MessagingService.swift` 中，紧跟 `sendVideo` 方法后添加：

```swift
public func sendLocation(to target: String, conversationType: ConversationType = .single, line: Int = 0, lat: Double, lng: Double, title: String, thumbnail: Data?) throws {
    try send(to: target, conversationType: conversationType, line: line,
             content: .location(lat: lat, lng: lng, title: title, thumbnail: thumbnail),
             mentionedType: 0, mentionedTargets: [])
}
```

- [ ] **Step 10: 在 `MessageSending` 协议添加 `sendLocation`**

打开 `Sources/IMKit/MessageSending.swift`，在 `func sendVideo(...)` 后添加：

```swift
func sendLocation(to target: String, conversationType: ConversationType, line: Int, lat: Double, lng: Double, title: String, thumbnail: Data?) throws
```

- [ ] **Step 11: 运行 MessagingService 测试，确认通过**

```bash
swift test --filter IMMessagingTests/MessagingServiceTests
```

期望：全部 PASS。

- [ ] **Step 12: 运行全量 IMMessagingTests，确认无回归**

```bash
swift test --filter IMMessagingTests
```

期望：全部 PASS。

- [ ] **Step 13: 提交**

```bash
git add Sources/IMMessaging/MessageContentCodec.swift \
        Sources/IMMessaging/MessagingService.swift \
        Sources/IMKit/MessageSending.swift \
        Tests/IMMessagingTests/MessageContentCodecTests.swift \
        Tests/IMMessagingTests/MessagingServiceTests.swift
git commit -m "feat(IMMessaging): encode/decode location type=4, add sendLocation to MessagingService and MessageSending"
```

---

## Task 3: IMKit — StoredMessageRow location 字段 + ViewModel makeRow + sendLocation

**Files:**
- Modify: `Sources/IMKit/ChatMessageRow.swift`
- Modify: `Sources/IMKit/ConversationViewModel.swift`
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift`

**Interfaces:**
- Consumes:
  - `MessageContent.location` from Task 1
  - `MessageSending.sendLocation(to:conversationType:line:lat:lng:title:thumbnail:)` from Task 2
- Produces:
  - `StoredMessageRow.locationLat: Double?`
  - `StoredMessageRow.locationLng: Double?`
  - `ConversationViewModel.sendLocation(lat:lng:title:thumbnail:)`

---

- [ ] **Step 1: 写失败测试**

在 `Tests/IMKitTests/ConversationViewModelTests.swift` 末尾添加：

```swift
func testMakeRow_location_setsLocationCoordinatesAndTitle() throws {
    let thumbnail = Data([0xAA])
    try storage.messages.insert(StoredMessage(
        localMessageId: 1, conversationType: .single, target: "them", from: "them",
        content: .location(lat: 31.23, lng: 121.47, title: "上海市中心", thumbnail: thumbnail),
        timestamp: 1_000, status: .unread, direction: .receive
    ))

    waitForFirstNonEmptyRows()

    guard case .message(let m)? = viewModel.rows.first else { return XCTFail("expected a message row") }
    XCTAssertEqual(m.locationLat, 31.23)
    XCTAssertEqual(m.locationLng, 121.47)
    XCTAssertEqual(m.text, "上海市中心")
    XCTAssertEqual(m.imageThumbnail, thumbnail)
}

func testMakeRow_location_nilThumbnail_locationLatNonNil() throws {
    try storage.messages.insert(StoredMessage(
        localMessageId: 2, conversationType: .single, target: "them", from: "them",
        content: .location(lat: 22.5, lng: 114.1, title: "深圳", thumbnail: nil),
        timestamp: 1_000, status: .unread, direction: .receive
    ))

    waitForFirstNonEmptyRows()

    guard case .message(let m)? = viewModel.rows.first else { return XCTFail("expected a message row") }
    XCTAssertNotNil(m.locationLat)
    XCTAssertNil(m.imageThumbnail)
}
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
swift test --filter IMKitTests/ConversationViewModelTests/testMakeRow_location_setsLocationCoordinatesAndTitle
```

期望：编译失败，`locationLat` 不存在。

- [ ] **Step 3: 在 `StoredMessageRow` 添加 location 字段**

打开 `Sources/IMKit/ChatMessageRow.swift`，在 `public let videoDuration: Int?` 下方添加：

```swift
/// Non-nil for location messages. Used by ConversationViewController to
/// dispatch to LocationMessageCell and by LocationPreviewViewController.
public let locationLat: Double?
public let locationLng: Double?
```

更新 `init`，在 `videoDuration: Int? = nil` 参数后添加：

```swift
locationLat: Double? = nil,
locationLng: Double? = nil
```

并在 init 体内赋值：

```swift
self.locationLat = locationLat
self.locationLng = locationLng
```

- [ ] **Step 4: 在 `buildStoredMessageRow` 添加 location 参数**

打开 `Sources/IMKit/ConversationViewModel.swift`，找到 `private func buildStoredMessageRow` 的签名，在 `videoDuration: Int? = nil` 后添加：

```swift
locationLat: Double? = nil,
locationLng: Double? = nil
```

在方法体内 `StoredMessageRow(...)` 的构造调用中，在 `videoDuration: videoDuration` 后添加：

```swift
locationLat: locationLat,
locationLng: locationLng
```

- [ ] **Step 5: 在 `makeRow` 的 switch 中添加 `.location` 分支**

找到 `case .recalled(let operatorId):` 分支，在其下方添加：

```swift
case .location(let lat, let lng, let title, let thumbnail):
    return .message(buildStoredMessageRow(
        message,
        text: title,
        imageThumbnail: thumbnail,
        imageRemoteURL: nil,
        locationLat: lat,
        locationLng: lng
    ))
```

- [ ] **Step 6: 在 `ConversationViewModel` 添加 `sendLocation` 公开方法**

紧跟 `sendVideo` 方法后添加：

```swift
public func sendLocation(lat: Double, lng: Double, title: String, thumbnail: Data?) {
    try? messageSending?.sendLocation(
        to: target, conversationType: conversationType, line: line,
        lat: lat, lng: lng, title: title, thumbnail: thumbnail
    )
}
```

- [ ] **Step 7: 运行测试，确认通过**

```bash
swift test --filter IMKitTests/ConversationViewModelTests/testMakeRow_location_setsLocationCoordinatesAndTitle
swift test --filter IMKitTests/ConversationViewModelTests/testMakeRow_location_nilThumbnail_locationLatNonNil
```

期望：2 个测试均 PASS。

- [ ] **Step 8: 运行全量 IMKitTests，确认无回归**

```bash
swift test --filter IMKitTests
```

期望：全部 PASS。

- [ ] **Step 9: 运行全量测试**

```bash
swift test
```

期望：全部 PASS。

- [ ] **Step 10: 提交**

```bash
git add Sources/IMKit/ChatMessageRow.swift \
        Sources/IMKit/ConversationViewModel.swift \
        Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat(IMKit): add location fields to StoredMessageRow, makeRow and sendLocation to ViewModel"
```

---

## Task 4: App UI — LocationPickerVC + LocationMessageCell + LocationPreviewVC + ConversationVC 接入

**Files:**
- Modify: `App/Info.plist`
- Modify: `App/ExtPanelView.swift`
- Create: `App/LocationPickerViewController.swift`
- Create: `App/LocationMessageCell.swift`
- Create: `App/LocationPreviewViewController.swift`
- Modify: `App/ConversationViewController.swift`

**Interfaces:**
- Consumes:
  - `StoredMessageRow.locationLat / locationLng` from Task 3
  - `ConversationViewModel.sendLocation(lat:lng:title:thumbnail:)` from Task 3
- Produces: 完整的地理位置消息发送/展示 UI

> **注意：** App target 依赖 UIKit/MapKit，无法在 `swift test` 中运行。本 Task 通过 `xcodebuild build` 验证编译，UI 正确性由人工在模拟器中验证。

---

- [ ] **Step 1: Info.plist 添加定位权限**

打开 `App/Info.plist`，在根 `<dict>` 内添加：

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>需要获取您的位置以发送位置消息</string>
```

- [ ] **Step 2: ExtPanelView 添加"位置"按钮**

打开 `App/ExtPanelView.swift`，添加 `onLocation` 回调属性（与 `onAlbum` 同级）：

```swift
var onLocation: (() -> Void)?
```

在 `init` 的 `items` 数组末尾追加：

```swift
("location.fill", "位置", #selector(locationTapped)),
```

在文件末尾添加 action 方法：

```swift
@objc private func locationTapped() { onLocation?() }
```

- [ ] **Step 3: 创建 LocationPickerViewController**

新建 `App/LocationPickerViewController.swift`，完整内容：

```swift
import UIKit
import MapKit
import CoreLocation

final class LocationPickerViewController: UIViewController {
    var onPicked: ((_ lat: Double, _ lng: Double, _ title: String, _ thumbnail: Data) -> Void)?

    private let mapView = MKMapView()
    private let pinImageView = UIImageView(image: UIImage(systemName: "mappin"))
    private let infoView = UIView()
    private let titleLabel = UILabel()
    private let coordLabel = UILabel()
    private let sendButton = UIBarButtonItem()
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var isGeocoding = false
    private var pendingGeocode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "发送位置"
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消", style: .plain, target: self, action: #selector(cancelTapped)
        )
        sendButton.title = "发送"
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.isEnabled = false
        navigationItem.rightBarButtonItem = sendButton

        layoutViews()
        setupLocationManager()
    }

    private func layoutViews() {
        mapView.delegate = self
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)

        // Fixed center pin (not an annotation — stays centered as map moves)
        pinImageView.tintColor = .systemRed
        pinImageView.contentMode = .scaleAspectFit
        pinImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pinImageView)

        infoView.backgroundColor = Theme.backgroundSecondary
        infoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.text = "定位中…"
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        coordLabel.font = .systemFont(ofSize: 12)
        coordLabel.textColor = Theme.textSecondary
        coordLabel.translatesAutoresizingMaskIntoConstraints = false

        infoView.addSubview(titleLabel)
        infoView.addSubview(coordLabel)

        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: infoView.topAnchor),

            pinImageView.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
            pinImageView.centerYAnchor.constraint(equalTo: mapView.centerYAnchor, constant: -12),
            pinImageView.widthAnchor.constraint(equalToConstant: 28),
            pinImageView.heightAnchor.constraint(equalToConstant: 36),

            infoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            infoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            infoView.heightAnchor.constraint(equalToConstant: 80),

            titleLabel.leadingAnchor.constraint(equalTo: infoView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: infoView.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: infoView.topAnchor, constant: 14),

            coordLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            coordLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            coordLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
    }

    private func reverseGeocodeCenter() {
        guard !isGeocoding else { pendingGeocode = true; return }
        isGeocoding = true
        pendingGeocode = false
        let center = mapView.centerCoordinate
        let loc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            guard let self else { return }
            self.isGeocoding = false
            let poi = placemarks?.first.flatMap { p in
                [p.name, p.thoroughfare, p.locality].compactMap { $0 }.first
            } ?? "未知位置"
            self.titleLabel.text = poi
            self.coordLabel.text = String(format: "%.5f, %.5f", center.latitude, center.longitude)
            self.sendButton.isEnabled = true
            if self.pendingGeocode { self.reverseGeocodeCenter() }
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func sendTapped() {
        let center = mapView.centerCoordinate
        let title = titleLabel.text ?? "位置"
        let region = mapView.region
        let opts = MKMapSnapshotter.Options()
        opts.region = region
        opts.size = CGSize(width: 400, height: 240)
        opts.scale = 2
        MKMapSnapshotter(options: opts).start { [weak self] snapshot, _ in
            guard let self else { return }
            let image = snapshot?.image ?? UIImage()
            let jpeg = image.jpegData(compressionQuality: 0.75) ?? Data()
            DispatchQueue.main.async {
                self.onPicked?(center.latitude, center.longitude, title, jpeg)
                self.dismiss(animated: true)
            }
        }
    }
}

extension LocationPickerViewController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        let coord = loc.coordinate
        let region = MKCoordinateRegion(center: coord, latitudinalMeters: 500, longitudinalMeters: 500)
        mapView.setRegion(region, animated: true)
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            titleLabel.text = "定位权限被拒绝，请在设置中开启"
            sendButton.isEnabled = false
        default:
            break
        }
    }
}

extension LocationPickerViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        reverseGeocodeCenter()
    }
}
```

- [ ] **Step 4: 创建 LocationMessageCell**

新建 `App/LocationMessageCell.swift`，完整内容：

```swift
import UIKit
import IMKit

struct LocationBubbleData: Equatable {
    let thumbnail: Data?
    let title: String
    let isOutgoing: Bool
    let senderDisplayName: String?
    let senderAvatarURL: String?

    init(thumbnail: Data?, title: String, isOutgoing: Bool,
         senderDisplayName: String? = nil, senderAvatarURL: String? = nil) {
        self.thumbnail = thumbnail
        self.title = title
        self.isOutgoing = isOutgoing
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
    }
}

final class LocationMessageCell: UITableViewCell {
    static let reuseIdentifier = "LocationMessageCell"

    private let mapImageView = UIImageView()
    private let titleLabel = UILabel()
    private let bubbleStack = UIStackView()
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()
    private let senderNameLabel = UILabel()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader.shared)

    var onTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        bubbleStack.addGestureRecognizer(tap)
        bubbleStack.isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTapped = nil
        mapImageView.image = nil
        titleLabel.text = nil
    }

    private func layoutViews() {
        mapImageView.contentMode = .scaleAspectFill
        mapImageView.clipsToBounds = true
        mapImageView.layer.cornerRadius = 8
        mapImageView.backgroundColor = Theme.backgroundTertiary
        mapImageView.tintColor = Theme.textSecondary
        mapImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mapImageView.widthAnchor.constraint(equalToConstant: 200),
            mapImageView.heightAnchor.constraint(equalToConstant: 120),
        ])

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        bubbleStack.axis = .vertical
        bubbleStack.spacing = 6
        bubbleStack.layer.cornerRadius = 12
        bubbleStack.clipsToBounds = true
        bubbleStack.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        bubbleStack.isLayoutMarginsRelativeArrangement = true
        bubbleStack.addArrangedSubview(mapImageView)
        bubbleStack.addArrangedSubview(titleLabel)

        senderNameLabel.font = .systemFont(ofSize: 11)
        senderNameLabel.textColor = Theme.textSecondary
        senderAvatarImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),
        ])

        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 4
        bubbleColumn.addArrangedSubview(senderNameLabel)
        bubbleColumn.addArrangedSubview(bubbleStack)

        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
        ])
    }

    func configure(with data: LocationBubbleData) {
        titleLabel.text = data.title
        titleLabel.textColor = data.isOutgoing ? .white : Theme.textPrimary

        if let thumbData = data.thumbnail, let img = UIImage(data: thumbData) {
            mapImageView.image = img
        } else {
            mapImageView.image = UIImage(systemName: "mappin.and.ellipse")
        }

        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        senderNameLabel.isHidden = data.senderDisplayName == nil

        if data.isOutgoing {
            bubbleStack.backgroundColor = Theme.accent
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
        } else {
            bubbleStack.backgroundColor = Theme.backgroundTertiary
            senderNameLabel.text = data.senderDisplayName
            rowStack.addArrangedSubview(senderAvatarImageView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            senderAvatarImageView.setAvatar(urlString: data.senderAvatarURL)
        }
    }

    @objc private func handleTap() { onTapped?() }
}
```

- [ ] **Step 5: 创建 LocationPreviewViewController**

新建 `App/LocationPreviewViewController.swift`，完整内容：

```swift
import UIKit
import MapKit

final class LocationPreviewViewController: UIViewController {
    private let lat: Double
    private let lng: Double
    private let poiTitle: String
    private let mapView = MKMapView()

    init(lat: Double, lng: Double, title: String) {
        self.lat = lat
        self.lng = lng
        self.poiTitle = title
        super.init(nibName: nil, bundle: nil)
        self.title = title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let region = MKCoordinateRegion(center: coord, latitudinalMeters: 500, longitudinalMeters: 500)
        mapView.setRegion(region, animated: false)

        let annotation = MKPointAnnotation()
        annotation.coordinate = coord
        annotation.title = poiTitle
        mapView.addAnnotation(annotation)
        mapView.selectAnnotation(annotation, animated: false)
    }
}
```

- [ ] **Step 6: ConversationViewController — 注册 cell，添加位置分发，接入 ExtPanel，实现位置点击**

打开 `App/ConversationViewController.swift`：

**6a. 在 `configureDataSource` 的 `layoutViews` 注册列表中添加：**

```swift
tableView.register(LocationMessageCell.self, forCellReuseIdentifier: LocationMessageCell.reuseIdentifier)
```

**6b. 在 `configureDataSource` 的 switch 语句中，在 `case .message(let message) where message.text != nil:` 分支之前添加位置消息分支（必须在文本分支之前，否则 `text = POI名` 会被 TextMessageCell 拦截）：**

```swift
case .message(let message) where message.locationLat != nil:
    let cell = tableView.dequeueReusableCell(withIdentifier: LocationMessageCell.reuseIdentifier, for: indexPath) as! LocationMessageCell
    cell.configure(with: LocationBubbleData(
        thumbnail: message.imageThumbnail,
        title: message.text ?? "",
        isOutgoing: message.isOutgoing,
        senderDisplayName: message.senderDisplayName,
        senderAvatarURL: message.senderAvatarURL
    ))
    cell.onTapped = { [weak self] in
        guard let lat = message.locationLat, let lng = message.locationLng else { return }
        self?.presentLocationPreview(lat: lat, lng: lng, title: message.text ?? "位置")
    }
    return cell
```

**6c. 在 `bindInputBar` 中，找到 `extPanel.onFile` 设置的位置，在其下方添加：**

```swift
extPanel.onLocation = { [weak self] in
    guard let self else { return }
    let picker = LocationPickerViewController()
    picker.onPicked = { [weak self] lat, lng, title, thumbnail in
        self?.viewModel.sendLocation(lat: lat, lng: lng, title: title, thumbnail: thumbnail)
    }
    let nav = UINavigationController(rootViewController: picker)
    nav.modalPresentationStyle = .fullScreen
    self.present(nav, animated: true)
}
```

**6d. 在文件末尾添加 `presentLocationPreview` 私有方法（与 `presentImagePreview`、`presentVideoPlayer` 同级）：**

```swift
private func presentLocationPreview(lat: Double, lng: Double, title: String) {
    let vc = LocationPreviewViewController(lat: lat, lng: lng, title: title)
    navigationController?.pushViewController(vc, animated: true)
}
```

- [ ] **Step 7: 编译验证**

```bash
xcodebuild -project ios-chat-pro.xcodeproj \
           -scheme App \
           -destination 'platform=iOS Simulator,name=iPhone 16' \
           build 2>&1 | tail -20
```

期望：`BUILD SUCCEEDED`，无 warning/error。

- [ ] **Step 8: 人工验证（在模拟器中运行）**

按顺序验证：

1. 打开任意对话，点击"+"展开扩展面板，确认出现"位置"按钮
2. 点击"位置"按钮，弹出地图选择界面
3. 等待定位，地图中心跳转，底部显示 POI 名和坐标
4. 拖动地图，POI 名随之更新
5. 点击"发送"，消息气泡出现在对话列表（缩略图 + POI 名）
6. 点击该消息气泡，跳转到全屏地图并显示大头针

- [ ] **Step 9: 运行全量 SPM 测试，确认无回归**

```bash
swift test
```

期望：全部 PASS。

- [ ] **Step 10: 提交**

```bash
git add App/Info.plist \
        App/ExtPanelView.swift \
        App/LocationPickerViewController.swift \
        App/LocationMessageCell.swift \
        App/LocationPreviewViewController.swift \
        App/ConversationViewController.swift
git commit -m "feat(App): location message UI — picker, cell, preview, ConversationVC wiring"
```

---

## 完成标准

- `swift test` 全部通过（Tasks 1-3 新增测试 + 全量无回归）
- `xcodebuild build` 无编译错误
- 模拟器中可发送位置消息并显示地图缩略图和 POI 名
- 点击位置消息可查看全屏地图
- Android 发出的 type=4 消息可在 iOS 正确显示（wire 格式兼容）
