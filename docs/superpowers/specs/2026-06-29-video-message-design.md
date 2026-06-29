# Video Message — Design Spec

**Date:** 2026-06-29  
**Scope:** Send + receive + playback of video messages (wire type 4)

---

## Problem

Video messages (wire type 4) arrive from the server but are silently discarded. `MessageContentCodec.decode()` has no `case 4:` handler, throws `unsupportedContentType`, and `ReceiveMessageHandler.persist()` drops the message via `guard … else { return }`. Result: no storage, no message-list display, no conversation-list update. There is also no send path.

---

## Approach

Mirror the existing image/voice/file pattern exactly (Approach B). Each layer gets a parallel video type rather than reusing or extending image types.

---

## Wire Format (type = 4)

Verified against WildFireChat Android `VideoMessageContent`:

| Proto field       | Video value                            |
|-------------------|----------------------------------------|
| `type`            | `4`                                    |
| `searchableContent` | `"[视频]"`                           |
| `data`            | thumbnail JPEG bytes                   |
| `remoteMediaUrl`  | video file URL (MP4)                   |
| `content`         | JSON string `{"duration": <seconds>}`  |
| `mediaType` (upload) | `3` (1=image, 2=voice, 3=video, 4=file) |

---

## Data Layer (`IMStorage`)

### `MessageEnums.swift`
Add to `MessageContentType`:
```swift
case video = 4
```

### `StoredMessage.swift`
Add to `MessageContent` enum:
```swift
case video(thumbnail: Data?, remoteURL: String?, localPath: String?, duration: Int)
```

Storage column mapping (reuses existing columns):
- `mediaThumbnail` → thumbnail bytes
- `mediaRemoteURL` → video URL
- `mediaLocalPath` → local cache path (nil until downloaded)
- `textContent` → duration as integer string (same convention as voice)
- `searchableContent` → `"[视频]"`

`StoredMessage.content` computed property and `setContent(_:)` each get a `.video` branch following the same clear-all-other-columns pattern as every other case.

---

## Codec Layer (`IMMessaging`)

### `MessageContentCodec.swift`

**`decode()`** — add `case 4:`:
```swift
case 4:
    let duration = wire.hasContent
        ? (try? JSONDecoder().decode(VideoDurationPayload.self, from: Data(wire.content.utf8)))?.duration ?? 0
        : 0
    return .video(
        thumbnail: wire.hasData ? wire.data : nil,
        remoteURL: wire.hasRemoteMediaURL ? wire.remoteMediaURL : nil,
        localPath: nil,
        duration: duration
    )
```
Private helper struct `VideoDurationPayload: Decodable { let duration: Int }`.

**`encode(_:)`** — add `.video` branch:
```swift
case .video(let thumbnail, let remoteURL, _, let duration):
    wire.type = 4
    wire.searchableContent = "[视频]"
    if let thumbnail { wire.data = thumbnail }
    if let remoteURL { wire.remoteMediaURL = remoteURL }
    if let json = try? JSONEncoder().encode(VideoDurationPayload(duration: duration)),
       let str = String(data: json, encoding: .utf8) { wire.content = str }
```

### `MessagingService.swift`
Add `sendVideo(to:conversationType:line:thumbnail:remoteURL:duration:)` following the same pattern as `sendImage` / `sendVoice`.

---

## Upload Layer (`IMMedia`)

### `MediaUploadService.swift`
Add:
```swift
public func uploadVideo(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
    upload(data, mediaType: 3, fileName: fileName, completion: completion)
}
```

---

## IMKit Layer

### `VideoUploading.swift` (new file)
```swift
public protocol VideoUploading: AnyObject {
    func uploadVideo(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void)
}
extension MediaUploadService: VideoUploading {}
```

### `ChatMessageRow.swift`

`PendingVideoUpload` (new struct):
```swift
public struct PendingVideoUpload: Equatable, Hashable {
    public enum State: Equatable, Hashable { case uploading, failed }
    public let id: UUID
    public let thumbnail: Data
    public let videoData: Data
    public let duration: Int
    public var state: State
}
```

`StoredMessageRow` — add one field:
```swift
public let videoDuration: Int?   // nil = image; non-nil = video
```

`ChatMessageRow` — add case:
```swift
case pendingVideo(PendingVideoUpload)
```
Update `storageId` and `timestamp` switch arms to handle `.pendingVideo` the same as `.pendingImage` (return nil).

### `MessageSending.swift`
Add to protocol:
```swift
func sendVideo(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String, duration: Int) throws
```

### `ConversationViewModel.swift`

`makeRow(_:)` — add `.video` branch:
```swift
case .video(let thumbnail, let remoteURL, _, let duration):
    return .message(buildStoredMessageRow(message,
        text: nil,
        imageThumbnail: thumbnail,
        imageRemoteURL: remoteURL,
        videoDuration: duration))
```

`buildStoredMessageRow` — pass `videoDuration` through to `StoredMessageRow` init.

`sendVideo(videoData:thumbnail:duration:)` — new public method:
1. Create `PendingVideoUpload(state: .uploading)`
2. Append to `pendingVideos`, call `publishRows()`
3. Call `videoUploader.uploadVideo(videoData, fileName: "\(nowMillis()).mp4") { result in … }`
4. On success: call `messaging.sendVideo(…)`, remove pending, `publishRows()`
5. On failure: mark pending `.failed`, `publishRows()`

`rows` computed property includes `pendingVideos.map { .pendingVideo($0) }`.

`ConversationListViewModel` — `searchableContent` of `"[视频]"` already flows through the existing `lastMessage?.searchableContent` path; no change needed.

---

## App / UI Layer

### `VideoMessageCell.swift` (new file)

Layout (mirrors `ImageMessageCell`):
- Bubble container with outgoing/incoming direction support, avatar, sender name
- `UIImageView` for thumbnail (`contentMode = .scaleAspectFill`, clipped)
- Overlay: 44×44 semi-transparent black circle (`alpha 0.6`) centered, containing `UIImageView(systemName: "play.fill")` in white
- Duration label: bottom-right, white text on black background, 4pt corner radius, format `"m:ss"`
- Uploading state: adds a `UIActivityIndicatorView` over the play button; failed state: replaces circle with `exclamationmark.circle.fill`
- Exposes `onTapped: (() -> Void)?`

### `ConversationViewController.swift`

**PHPickerViewController** — change filter:
```swift
configuration.filter = .any(of: [.images, .videos])
```

**`PHPickerViewControllerDelegate`** — branch on media type:
```swift
if provider.canLoadObject(ofClass: UIImage.self) {
    // existing image path
} else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
        guard let url, let self else { return }
        self.handlePickedVideo(at: url)
    }
}
```

**`handlePickedVideo(at:)`**:
1. Load `AVAsset`, read `duration` in seconds
2. `AVAssetImageGenerator` → first-frame `CGImage` → scale to 200px → JPEG ≤60 KB (same `makeThumbnailData` logic)
3. Read video file into `Data`
4. `DispatchQueue.main.async { viewModel.sendVideo(videoData:thumbnail:duration:) }`

**Cell dispatch** — insert before existing image case (highest priority):
```swift
case .message(let m) where m.videoDuration != nil:
    let cell = tableView.dequeueReusableCell(…, VideoMessageCell.self)
    cell.configure(with: …)
    cell.onTapped = { [weak self] in self?.presentVideoPlayer(urlString: m.imageRemoteURL) }
    return cell
case .pendingVideo(let pending):
    let cell = tableView.dequeueReusableCell(…, VideoMessageCell.self)
    cell.configurePending(pending)
    return cell
```

**`presentVideoPlayer(urlString:)`** (new private method):
```swift
guard let urlString, let url = URL(string: urlString) else { return }
let player = AVPlayer(url: url)
let vc = AVPlayerViewController()
vc.player = player
present(vc, animated: true) { player.play() }
```
Streams directly from remote URL — no temp file needed (MP4 over HTTP is natively supported).

---

## File Change Summary

| File | Change |
|------|--------|
| `Sources/IMStorage/MessageEnums.swift` | Add `case video = 4` |
| `Sources/IMStorage/StoredMessage.swift` | Add `case video(…)` to `MessageContent`; update `content` + `setContent` |
| `Sources/IMMessaging/MessageContentCodec.swift` | Add `case 4:` decode + `.video` encode |
| `Sources/IMMessaging/MessagingService.swift` | Add `sendVideo(…)` |
| `Sources/IMKit/MessageSending.swift` | Add `sendVideo` to protocol |
| `Sources/IMKit/ChatMessageRow.swift` | Add `PendingVideoUpload`; add `videoDuration` to `StoredMessageRow`; add `.pendingVideo` to `ChatMessageRow` |
| `Sources/IMKit/ConversationViewModel.swift` | Add `sendVideo`; handle `.video` in `makeRow`; publish `pendingVideos` |
| `Sources/IMKit/VideoUploading.swift` | New protocol + `MediaUploadService` conformance |
| `Sources/IMMedia/MediaUploadService.swift` | Add `uploadVideo(…)` with mediaType 3 |
| `App/VideoMessageCell.swift` | New cell: thumbnail + play button + duration label |
| `App/ConversationViewController.swift` | PHPicker filter; video pick handler; cell dispatch; `presentVideoPlayer` |

---

## Out of Scope

- Video compression before upload (upload raw file from Photos)
- Local video caching after download
- Video message in group notification digest
- Camera capture (not requested)
