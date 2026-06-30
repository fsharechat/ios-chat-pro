# 地理位置消息设计文档

日期：2026-06-30

## 背景

iOS 端目前不支持发送或显示地理位置消息。`MessageContentType.location = 4` 仅作 DB 占位符存在，`MessageContent` 枚举无对应 case，编解码、ViewModel、App UI 全部缺失。本文档对照 Android 实现（`LocationMessageContent` / `MyLocationActivity` / `ShowLocationActivity`）完整规划 iOS 端的实现方案。

地图 SDK 选用苹果原生 MapKit + CoreLocation，无需引入第三方依赖或申请外部 Key。

---

## Wire 格式（与 Android 对齐）

type = 4，字段映射与 `LocationMessageContent.encode()` 完全一致：

| wire 字段 | 内容 |
|---|---|
| `type` | 4 |
| `searchableContent` | POI 名称（title） |
| `data`（binaryContent） | 地图缩略图 JPEG bytes |
| `content` | `{"lat": x, "long": y}`（注意 key 是 `long` 不是 `lng`） |

---

## 第一部分：IMStorage

### MessageContent 枚举

新增：

```swift
case location(lat: Double, lng: Double, title: String, thumbnail: Data?)
```

### StoredMessage 字段映射（零 schema 变更）

复用现有列，无需数据库迁移：

| 字段 | 复用列 |
|---|---|
| POI 名称 | `searchableContent` |
| 坐标 JSON `{"lat":x,"long":y}` | `textContent` |
| 缩略图 JPEG | `mediaThumbnail` |
| 消息类型 | `contentType = .location` |

### StoredMessage.content 的 `.location` 分支

从 `textContent` 解析坐标 JSON，从 `searchableContent` 取 title，从 `mediaThumbnail` 取缩略图：

```swift
case .location:
    // 内部 Decodable struct：LocationCoords { let lat: Double; let long: Double }
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

### StoredMessage.setContent 的 `.location` 分支

```swift
case .location(let lat, let lng, let title, let thumbnail):
    contentType = .location
    searchableContent = title
    textContent = "{\"lat\":\(lat),\"long\":\(lng)}"
    mediaThumbnail = thumbnail
    mediaRemoteURL = nil
    mediaLocalPath = nil
    groupNotificationOperator = nil; groupNotificationMembersRaw = nil; groupNotificationValue = nil
    callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0
```

### StoredMessageRow 新增字段

```swift
public let locationLat: Double?   // nil 表示非位置消息
public let locationLng: Double?
```

`text` 复用存 POI title，`imageThumbnail` 复用存缩略图。App 层通过 `locationLat != nil` 区分 image 和 location。

---

## 第二部分：IMMessaging

### MessageContentCodec.encode

```swift
case .location(let lat, let lng, let title, let thumbnail):
    wire.type = 4
    wire.searchableContent = title
    if let thumbnail { wire.data = thumbnail }
    wire.content = "{\"lat\":\(lat),\"long\":\(lng)}"
```

### MessageContentCodec.decode

```swift
case 4:
    // LocationCoords：{ lat: Double, long: Double }
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

`LocationCoords` 定义为 `MessageContentCodec` 内的私有 struct，与已有的 `VoiceWireContent`、`VideoDurationPayload` 同级。

---

## 第三部分：IMKit

### ConversationViewModel.makeRow

新增分支：

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

`buildStoredMessageRow` 接收新增的 `locationLat`/`locationLng` 可选参数，透传给 `StoredMessageRow`。

### ConversationViewModel.sendLocation

```swift
public func sendLocation(lat: Double, lng: Double, title: String, thumbnail: Data)
```

内部调用 `MessagingService.send(.location(lat: lat, lng: lng, title: title, thumbnail: thumbnail))`。缩略图直接走 wire `data` 字段，无需上传 MinIO，与 Android 行为一致。

---

## 第四部分：App 层

### ExtPanelView

在现有相册、拍摄、文件按钮后追加第四个按钮：

- 图标：`location.fill`（SF Symbols）
- 标题：`"位置"`
- 新增回调属性：`var onLocation: (() -> Void)?`

### LocationPickerViewController（新建）

**职责**：让用户选择当前位置并确认发送。

**UI**：
```
┌─────────────────────────────────┐
│  [取消]   发送位置    [发送]      │
├─────────────────────────────────┤
│                                 │
│        MKMapView（全屏）         │
│           📍（中心固定大头针）    │
│                                 │
├─────────────────────────────────┤
│  📍 POI 名称（逆地理编码结果）    │
│     副标题：纬度 / 经度           │
└─────────────────────────────────┘
```

**流程**：
1. `CLLocationManager.requestWhenInUseAuthorization()`，获取一次位置后将地图中心移至该位置
2. `MKMapView.regionDidChangeAnimated` 触发时调用 `CLGeocoder.reverseGeocodeLocation`，用结果更新底部 POI 名
3. 用户拖动地图可重新选点，POI 名实时更新
4. 点击"发送"：`MKMapSnapshotter` 截取当前地图视口（200×120 pt @2x）→ 压缩为 JPEG（quality 0.75）→ 触发回调

**回调**：
```swift
var onPicked: ((_ lat: Double, _ lng: Double, _ title: String, _ thumbnail: Data) -> Void)?
```

**错误处理**：定位权限被拒时底部展示提示文案，"发送"按钮不可用。

### LocationMessageCell（新建）

气泡样式与 `ImageMessageCell` 相同，内部布局：

```
┌──────────────────────────┐
│  [地图缩略图 200×120 pt]  │
│──────────────────────────│
│  POI title（单行截断）    │
└──────────────────────────┘
```

- 缩略图圆角 8pt，`contentMode = .scaleAspectFill`
- 缩略图为 nil 时显示占位图（`mappin.and.ellipse` SF Symbol）
- 支持发送/接收两个方向（复用气泡背景逻辑）
- 点击 → 推送 `LocationPreviewViewController`

### LocationPreviewViewController（新建）

**职责**：只读展示收到的位置。

- `MKMapView` 全屏，设置中心为目标坐标，zoom 级别 16
- 添加 `MKPointAnnotation`，`title = POI 名`，自动 `showAnnotations` 居中
- 导航栏标题 = POI 名
- 无"发送"按钮（纯查看）

### ConversationViewController 变更点

| 位置 | 变更 |
|---|---|
| `configureDataSource` | 注册 `LocationMessageCell` |
| cell 分发逻辑 | `row.locationLat != nil` → 分发到 `LocationMessageCell` |
| `bindInputBar` | `extPanel.onLocation` → push `LocationPickerViewController`，onPicked 回调调用 `viewModel.sendLocation` |
| cell 点击处理 | location cell → push `LocationPreviewViewController(lat:lng:title:)` |

### Info.plist

新增权限描述：

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>需要获取您的位置以发送位置消息</string>
```

---

## 变更范围汇总

| 文件 | 变更类型 |
|---|---|
| `Sources/IMStorage/StoredMessage.swift` | 改：新增 `.location` case 处理 |
| `Sources/IMKit/ChatMessageRow.swift` | 改：`StoredMessageRow` 新增 `locationLat`/`locationLng` |
| `Sources/IMKit/ConversationViewModel.swift` | 改：makeRow + buildStoredMessageRow + sendLocation |
| `Sources/IMMessaging/MessageContentCodec.swift` | 改：encode/decode type=4 |
| `App/ExtPanelView.swift` | 改：新增位置按钮 |
| `App/ConversationViewController.swift` | 改：注册 cell + 分发 + 点击处理 |
| `App/LocationPickerViewController.swift` | 新建 |
| `App/LocationMessageCell.swift` | 新建 |
| `App/LocationPreviewViewController.swift` | 新建 |
| `App/Info.plist` | 改：新增位置权限描述 |

---

## 不在范围内

- 腾讯地图 / 高德地图 SDK 集成
- POI 搜索列表（Android 的 RecyclerView POI 选择列表）——第一期只做逆地理编码单结果
- 后台持续定位
- 消息搜索对地理位置的支持
