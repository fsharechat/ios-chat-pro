# Video Message Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full send + receive + playback support for video messages (wire type 4) across all layers.

**Architecture:** Mirror the existing image/voice/file pattern exactly — parallel video types at each layer, no reuse of image types. Wire type 4 maps to `MessageContentType.video`, decoded/encoded by `MessageContentCodec`, uploaded via `MediaUploadService.uploadVideo` (mediaType=3), displayed in `VideoMessageCell` (thumbnail + ▶ overlay + duration), played via system `AVPlayerViewController`.

**Tech Stack:** Swift, GRDB, Combine, PHPickerViewController, AVFoundation, AVKit (AVPlayerViewController), UniformTypeIdentifiers

## Global Constraints

- iOS deployment target: 15.0
- All code must be called from main queue — no internal locking anywhere
- No new singletons; all dependencies injected via init or closure
- New App/ files are auto-discovered by the `sources: - App` glob in `project.yml`; no project file edits needed
- New SPM source files are auto-discovered; no `Package.swift` edits needed
- Run `swift test` after each task to verify no regressions

---

### Task 1: Storage Layer — `video` type in MessageEnums + StoredMessage

**Files:**
- Modify: `Sources/IMStorage/MessageEnums.swift`
- Modify: `Sources/IMStorage/StoredMessage.swift`
- Modify: `Tests/IMStorageTests/StoredMessageTests.swift`

**Interfaces:**
- Produces: `MessageContentType.video` (raw value `4`); `MessageContent.video(thumbnail: Data?, remoteURL: String?, localPath: String?, duration: Int)`; `StoredMessage.content` returns `.video`; `StoredMessage.setContent(.video(...))` flattens to columns

- [ ] **Step 1: Write failing tests**

Add to `Tests/IMStorageTests/StoredMessageTests.swift`:

```swift
func test_videoMessage_initFlattensContentToColumns() {
    let thumbnail = Data([0xAA, 0xBB])
    let message = StoredMessage(
        localMessageId: 10, conversationType: .single, target: "u2", from: "u1",
        content: .video(thumbnail: thumbnail, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 42),
        timestamp: 1_000, status: .sent, direction: .send
    )
    XCTAssertEqual(message.contentType, .video)
    XCTAssertEqual(message.searchableContent, "[视频]")
    XCTAssertEqual(message.textContent, "42")
    XCTAssertEqual(message.mediaThumbnail, thumbnail)
    XCTAssertEqual(message.mediaRemoteURL, "https://example.com/v.mp4")
    XCTAssertNil(message.mediaLocalPath)
    XCTAssertNil(message.groupNotificationOperator)
    XCTAssertNil(message.callId)
}

func test_videoMessage_contentPropertyRoundTrips() {
    let thumbnail = Data([0xAA])
    let original = MessageContent.video(thumbnail: thumbnail, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 42)
    let message = StoredMessage(
        localMessageId: 10, conversationType: .single, target: "u2", from: "u1",
        content: original, timestamp: 1_000, status: .sent, direction: .send
    )
    XCTAssertEqual(message.content, original)
}

func test_videoMessage_setContent_clearsPreviousColumns() {
    var message = StoredMessage(
        localMessageId: 10, conversationType: .single, target: "u2", from: "u1",
        content: .text("hello"), timestamp: 1_000, status: .sent, direction: .send
    )
    message.setContent(.video(thumbnail: nil, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 10))
    XCTAssertNil(message.groupNotificationOperator)
    XCTAssertNil(message.callId)
    XCTAssertEqual(message.contentType, .video)
}
```

- [ ] **Step 2: Run tests — expect compile failure** (`MessageContentType` has no `video`)

```bash
swift test --filter IMStorageTests/StoredMessageTests
```

Expected: compile error — `type 'MessageContentType' has no member 'video'`

- [ ] **Step 3: Add `case video = 4` to `MessageEnums.swift`**

In `Sources/IMStorage/MessageEnums.swift`, insert after `case image = 3`:

```swift
case video = 4
```

- [ ] **Step 4: Add `.video` case to `MessageContent` enum in `StoredMessage.swift`**

In `Sources/IMStorage/StoredMessage.swift`, after the `.voice` case in `MessageContent`:

```swift
/// Wire type 4. `duration` is in seconds. Fields follow the same
/// optional-presence convention as `.image` and `.voice`.
case video(thumbnail: Data?, remoteURL: String?, localPath: String?, duration: Int)
```

- [ ] **Step 5: Update `StoredMessage.content` computed property**

In the `switch contentType` inside the `content` computed property, add after the `.voice` case:

```swift
case .video:
    return .video(
        thumbnail: mediaThumbnail,
        remoteURL: mediaRemoteURL,
        localPath: mediaLocalPath,
        duration: Int(textContent ?? "0") ?? 0
    )
```

- [ ] **Step 6: Update `StoredMessage.setContent(_:)` method**

After the `case .file(...)` block (before `case .recalled`), add:

```swift
case .video(let thumbnail, let remoteURL, let localPath, let duration):
    contentType = .video
    textContent = "\(duration)"
    searchableContent = "[视频]"
    mediaRemoteURL = remoteURL
    mediaLocalPath = localPath
    mediaThumbnail = thumbnail
    groupNotificationOperator = nil
    groupNotificationMembersRaw = nil
    groupNotificationValue = nil
    callId = nil; callTargetId = nil; callAudioOnly = false; callStatus = 0; callConnectTime = 0; callEndTime = 0
```

- [ ] **Step 7: Update the exhaustive switch in `renderSystemTipText` in `ConversationViewModel.swift`**

Find the line in `Sources/IMKit/ConversationViewModel.swift`:
```swift
case .text, .image, .callStart, .voice, .file, .recalled:
```
Change to:
```swift
case .text, .image, .video, .callStart, .voice, .file, .recalled:
```

- [ ] **Step 8: Run tests — expect pass**

```bash
swift test --filter IMStorageTests/StoredMessageTests
```

Expected: all `StoredMessageTests` pass

- [ ] **Step 9: Commit**

```bash
git add Sources/IMStorage/MessageEnums.swift Sources/IMStorage/StoredMessage.swift Sources/IMKit/ConversationViewModel.swift Tests/IMStorageTests/StoredMessageTests.swift
git commit -m "feat(IMStorage): add video message type (wire type 4)"
```

---

### Task 2: Codec + MessagingService

**Files:**
- Modify: `Sources/IMMessaging/MessageContentCodec.swift`
- Modify: `Sources/IMMessaging/MessagingService.swift`
- Modify: `Tests/IMMessagingTests/MessageContentCodecTests.swift`

**Interfaces:**
- Consumes: `MessageContent.video` from Task 1
- Produces: `MessageContentCodec.decode()` handles wire type 4; `MessageContentCodec.encode(.video(...))` produces wire type 4; `MessagingService.sendVideo(to:conversationType:line:thumbnail:remoteURL:duration:)`

- [ ] **Step 1: Write failing codec tests**

Add to `Tests/IMMessagingTests/MessageContentCodecTests.swift`:

```swift
func test_encodeVideo_setsTypeSearchableThumbnailRemoteURLAndDurationJSON() throws {
    let thumbnail = Data([0xCC, 0xDD])
    let wire = MessageContentCodec.encode(
        .video(thumbnail: thumbnail, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 42)
    )
    XCTAssertEqual(wire.type, 4)
    XCTAssertEqual(wire.searchableContent, "[视频]")
    XCTAssertEqual(wire.data, thumbnail)
    XCTAssertEqual(wire.remoteMediaURL, "https://example.com/v.mp4")
    XCTAssertTrue(wire.hasContent)
    let parsed = try JSONDecoder().decode([String: Int].self, from: Data(wire.content.utf8))
    XCTAssertEqual(parsed["duration"], 42)
}

func test_decodeVideo_readsThumbnailRemoteURLAndDuration() throws {
    var wire = Im_MessageContent()
    wire.type = 4
    wire.data = Data([0xCC, 0xDD])
    wire.remoteMediaURL = "https://example.com/v.mp4"
    wire.content = "{\"duration\":42}"
    let content = try MessageContentCodec.decode(wire)
    XCTAssertEqual(content, .video(thumbnail: Data([0xCC, 0xDD]), remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 42))
}

func test_decodeVideo_missingDurationField_defaultsToZero() throws {
    var wire = Im_MessageContent()
    wire.type = 4
    wire.remoteMediaURL = "https://example.com/v.mp4"
    let content = try MessageContentCodec.decode(wire)
    XCTAssertEqual(content, .video(thumbnail: nil, remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 0))
}

func test_videoRoundTrip() throws {
    let original = MessageContent.video(thumbnail: Data([0xEE]), remoteURL: "https://example.com/v.mp4", localPath: nil, duration: 15)
    let roundTripped = try MessageContentCodec.decode(MessageContentCodec.encode(original))
    XCTAssertEqual(roundTripped, original)
}
```

- [ ] **Step 2: Run tests — expect compile failure**

```bash
swift test --filter IMMessagingTests/MessageContentCodecTests
```

Expected: compile error — `.video` not handled in `encode`

- [ ] **Step 3: Add private `VideoDurationPayload` struct to `MessageContentCodec.swift`**

In `Sources/IMMessaging/MessageContentCodec.swift`, after the `VoiceWireContent` struct:

```swift
/// Wire shape for type 4 (video)'s `content` field — mirrors voice's
/// duration JSON convention.
private struct VideoDurationPayload: Codable {
    let duration: Int
}
```

- [ ] **Step 4: Add `.video` case to `encode(_:)` in `MessageContentCodec.swift`**

After the `.file` case block (before `case .recalled`):

```swift
case .video(let thumbnail, let remoteURL, _, let duration):
    wire.type = 4
    wire.searchableContent = "[视频]"
    if let thumbnail { wire.data = thumbnail }
    if let remoteURL { wire.remoteMediaURL = remoteURL }
    if let json = try? JSONEncoder().encode(VideoDurationPayload(duration: duration)),
       let str = String(data: json, encoding: .utf8) {
        wire.content = str
    }
```

- [ ] **Step 5: Add `case 4:` to `decode(_:)` in `MessageContentCodec.swift`**

After `case 80:` (the recalled case), before `default:`:

```swift
case 4:
    let duration: Int
    if wire.hasContent,
       let data = wire.content.data(using: .utf8),
       let payload = try? JSONDecoder().decode(VideoDurationPayload.self, from: data) {
        duration = payload.duration
    } else {
        duration = 0
    }
    return .video(
        thumbnail: wire.hasData ? wire.data : nil,
        remoteURL: wire.hasRemoteMediaURL ? wire.remoteMediaURL : nil,
        localPath: nil,
        duration: duration
    )
```

- [ ] **Step 6: Run codec tests — expect pass**

```bash
swift test --filter IMMessagingTests/MessageContentCodecTests
```

Expected: all codec tests pass

- [ ] **Step 7: Add `sendVideo` to `MessagingService.swift`**

In `Sources/IMMessaging/MessagingService.swift`, after `sendFile`:

```swift
public func sendVideo(to target: String, conversationType: ConversationType = .single, line: Int = 0, thumbnail: Data?, remoteURL: String, duration: Int) throws {
    try send(to: target, conversationType: conversationType, line: line,
             content: .video(thumbnail: thumbnail, remoteURL: remoteURL, localPath: nil, duration: duration),
             mentionedType: 0, mentionedTargets: [])
}
```

- [ ] **Step 8: Run all messaging tests**

```bash
swift test --filter IMMessagingTests
```

Expected: all pass

- [ ] **Step 9: Commit**

```bash
git add Sources/IMMessaging/MessageContentCodec.swift Sources/IMMessaging/MessagingService.swift Tests/IMMessagingTests/MessageContentCodecTests.swift
git commit -m "feat(IMMessaging): decode/encode video messages, add sendVideo"
```

---

### Task 3: Upload Layer — `uploadVideo` + `VideoUploading` protocol

**Files:**
- Modify: `Sources/IMMedia/MediaUploadService.swift`
- Create: `Sources/IMKit/VideoUploading.swift`

**Interfaces:**
- Produces: `MediaUploadService.uploadVideo(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void)`; `VideoUploading` protocol

- [ ] **Step 1: Add `uploadVideo` to `MediaUploadService.swift`**

In `Sources/IMMedia/MediaUploadService.swift`, after `uploadFile`:

```swift
/// Uploads video data and returns the remote URL string.
/// mediaType=3 matches WildFireChat's server-side convention (1=image,
/// 2=voice, 3=video, 4=file).
public func uploadVideo(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
    upload(data, mediaType: 3, fileName: fileName, completion: completion)
}
```

- [ ] **Step 2: Create `Sources/IMKit/VideoUploading.swift`**

```swift
import Foundation
import IMMedia

/// Narrow interface `ConversationViewModel` depends on instead of the
/// concrete `MediaUploadService` — same decoupling-for-testability pattern
/// as `ImageUploading`/`VoiceUploading`.
public protocol VideoUploading: AnyObject {
    func uploadVideo(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void)
}

extension MediaUploadService: VideoUploading {}
```

- [ ] **Step 3: Run tests**

```bash
swift test --filter IMMediaTests
```

Expected: all pass (upload method follows identical code path as existing types)

- [ ] **Step 4: Commit**

```bash
git add Sources/IMMedia/MediaUploadService.swift Sources/IMKit/VideoUploading.swift
git commit -m "feat(IMMedia): add uploadVideo (mediaType=3)"
```

---

### Task 4: IMKit Data Types — `PendingVideoUpload`, `StoredMessageRow.videoDuration`, `ChatMessageRow.pendingVideo`

**Files:**
- Modify: `Sources/IMKit/ChatMessageRow.swift`
- Modify: `Sources/IMKit/MessageSending.swift`

**Interfaces:**
- Consumes: `VideoUploading` from Task 3
- Produces:
  - `PendingVideoUpload` struct with `id: UUID`, `thumbnail: Data`, `videoData: Data`, `duration: Int`, `state: PendingVideoUpload.State`
  - `StoredMessageRow.videoDuration: Int?` — nil=image, non-nil=video
  - `ChatMessageRow.pendingVideo(PendingVideoUpload)`
  - `MessageSending.sendVideo(to:conversationType:line:thumbnail:remoteURL:duration:)` protocol requirement

- [ ] **Step 1: Add `PendingVideoUpload` to `ChatMessageRow.swift`**

After the `PendingImageUpload` struct:

```swift
/// A video message still uploading — lives only in `ConversationViewModel`'s
/// in-memory state until upload succeeds, same lifecycle as `PendingImageUpload`.
public struct PendingVideoUpload: Equatable, Hashable {
    public enum State: Equatable, Hashable {
        case uploading
        case failed
    }

    public let id: UUID
    public let thumbnail: Data
    public let videoData: Data
    public let duration: Int
    public var state: State

    public init(id: UUID, thumbnail: Data, videoData: Data, duration: Int, state: State) {
        self.id = id
        self.thumbnail = thumbnail
        self.videoData = videoData
        self.duration = duration
        self.state = state
    }
}
```

- [ ] **Step 2: Add `videoDuration: Int?` to `StoredMessageRow`**

In the `StoredMessageRow` struct, after `imageRemoteURL`:

```swift
/// Non-nil only for video messages — used by `ConversationViewController`
/// to dispatch to `VideoMessageCell` instead of `ImageMessageCell`.
public let videoDuration: Int?
```

Update the `init` to include `videoDuration: Int? = nil` (with default so existing callers don't break):

```swift
public init(
    storageId: Int64,
    localMessageId: Int64,
    isOutgoing: Bool,
    status: MessageStatus,
    timestamp: Int64,
    text: String?,
    imageThumbnail: Data?,
    imageRemoteURL: String?,
    senderDisplayName: String? = nil,
    senderAvatarURL: String? = nil,
    videoDuration: Int? = nil
) {
    self.storageId = storageId
    self.localMessageId = localMessageId
    self.isOutgoing = isOutgoing
    self.status = status
    self.timestamp = timestamp
    self.text = text
    self.imageThumbnail = imageThumbnail
    self.imageRemoteURL = imageRemoteURL
    self.senderDisplayName = senderDisplayName
    self.senderAvatarURL = senderAvatarURL
    self.videoDuration = videoDuration
}
```

- [ ] **Step 3: Add `.pendingVideo` to `ChatMessageRow` enum**

After `case pendingImage(PendingImageUpload)`:

```swift
case pendingVideo(PendingVideoUpload)
```

Update the `storageId` and `timestamp` extension to handle the new case (add to the existing `pendingImage` branch or explicitly):

In `extension ChatMessageRow`, change:
```swift
case .pendingImage, .timeHeader: return nil
```
to (in both `storageId` and `timestamp`):
```swift
case .pendingImage, .pendingVideo, .timeHeader: return nil
```

- [ ] **Step 4: Add `sendVideo` to `MessageSending` protocol in `MessageSending.swift`**

After `sendFile`:

```swift
func sendVideo(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String, duration: Int) throws
```

- [ ] **Step 5: Run tests — expect compile failure in ConversationViewModelTests**

```bash
swift test --filter IMKitTests
```

Expected: compile error — `FakeMessageSending` does not conform to `MessageSending` (missing `sendVideo`)

- [ ] **Step 6: Add `sendVideo` stub to `FakeMessageSending` in `Tests/IMKitTests/ConversationViewModelTests.swift`**

Add to the `FakeMessageSending` class:

```swift
private(set) var sentVideos: [(target: String, thumbnail: Data?, remoteURL: String, duration: Int)] = []

func sendVideo(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String, duration: Int) throws {
    sentVideos.append((target, thumbnail, remoteURL, duration))
}
```

- [ ] **Step 7: Run tests — expect pass**

```bash
swift test --filter IMKitTests
```

Expected: all pass

- [ ] **Step 8: Commit**

```bash
git add Sources/IMKit/ChatMessageRow.swift Sources/IMKit/MessageSending.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat(IMKit): add PendingVideoUpload, videoDuration, pendingVideo row, sendVideo protocol"
```

---

### Task 5: ConversationViewModel — `sendVideo`, `makeRow(.video)`, pending video handling

**Files:**
- Modify: `Sources/IMKit/ConversationViewModel.swift`
- Modify: `Tests/IMKitTests/ConversationViewModelTests.swift`

**Interfaces:**
- Consumes: `PendingVideoUpload`, `VideoUploading`, `MessageSending.sendVideo` from Tasks 3–4
- Produces: `ConversationViewModel.sendVideo(videoData:thumbnail:duration:)` public method; `.video` rows in `rows` publisher; `.pendingVideo` rows while uploading

- [ ] **Step 1: Write failing ViewModel tests**

Add `FakeVideoUploading` to `Tests/IMKitTests/ConversationViewModelTests.swift` (after `FakeImageUploading`):

```swift
private final class FakeVideoUploading: VideoUploading {
    var nextResult: Result<String, MediaUploadError> = .failure(.invalidUploadURL)
    var completesSynchronously = true
    private(set) var uploadedData: [Data] = []
    private(set) var pendingCompletions: [(Result<String, MediaUploadError>) -> Void] = []

    func uploadVideo(_ data: Data, fileName: String, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
        uploadedData.append(data)
        if completesSynchronously {
            completion(nextResult)
        } else {
            pendingCompletions.append(completion)
        }
    }
}
```

Add test methods:

```swift
func test_sendVideo_whileUploading_showsPendingVideoRow() {
    let fakeVideo = FakeVideoUploading()
    fakeVideo.completesSynchronously = false
    let vm = ConversationViewModel(
        storage: storage, messageSending: sending, imageUploading: uploading,
        videoUploading: fakeVideo, target: "them", pageSize: 3, currentUserId: "me"
    )
    vm.sendVideo(videoData: Data([0x01, 0x02]), thumbnail: Data([0x03]), duration: 10)
    XCTAssertEqual(vm.rows.count, 1)
    guard case .pendingVideo(let p) = vm.rows.first else {
        return XCTFail("Expected .pendingVideo, got \(String(describing: vm.rows.first))")
    }
    XCTAssertEqual(p.state, .uploading)
    XCTAssertEqual(p.duration, 10)
}

func test_sendVideo_onUploadSuccess_removePendingAndSendsMessage() {
    let fakeVideo = FakeVideoUploading()
    fakeVideo.nextResult = .success("https://example.com/v.mp4")
    fakeVideo.completesSynchronously = true
    let vm = ConversationViewModel(
        storage: storage, messageSending: sending, imageUploading: uploading,
        videoUploading: fakeVideo, target: "them", pageSize: 3, currentUserId: "me"
    )
    vm.sendVideo(videoData: Data([0x01]), thumbnail: Data([0x02]), duration: 5)
    // pendingVideo removed after successful upload
    XCTAssertTrue(vm.rows.allSatisfy { if case .pendingVideo = $0 { return false }; return true })
    XCTAssertEqual(sending.sentVideos.first?.remoteURL, "https://example.com/v.mp4")
    XCTAssertEqual(sending.sentVideos.first?.duration, 5)
}

func test_sendVideo_onUploadFailure_showsFailedPendingRow() {
    let fakeVideo = FakeVideoUploading()
    fakeVideo.nextResult = .failure(.invalidUploadURL)
    fakeVideo.completesSynchronously = true
    let vm = ConversationViewModel(
        storage: storage, messageSending: sending, imageUploading: uploading,
        videoUploading: fakeVideo, target: "them", pageSize: 3, currentUserId: "me"
    )
    vm.sendVideo(videoData: Data([0x01]), thumbnail: Data([0x02]), duration: 5)
    guard case .pendingVideo(let p) = vm.rows.first else {
        return XCTFail("Expected .pendingVideo")
    }
    XCTAssertEqual(p.state, .failed)
}
```

- [ ] **Step 2: Run — expect compile failure**

```bash
swift test --filter IMKitTests/ConversationViewModelTests
```

Expected: `ConversationViewModel` has no `videoUploading` parameter or `sendVideo` method

- [ ] **Step 3: Add `videoUploading` property and `pendingVideos` array to `ConversationViewModel`**

After the `private let fileUploading: FileUploading?` line, add:

```swift
private let videoUploading: VideoUploading?
```

After `private var pendingImages: [PendingImageUpload] = []`, add:

```swift
private var pendingVideos: [PendingVideoUpload] = []
```

- [ ] **Step 4: Add `videoUploading` parameter to `init`**

After `fileUploading: FileUploading? = nil,`, add:

```swift
videoUploading: VideoUploading? = nil,
```

At the end of the init body (before the `cancellable = ...` line), add:

```swift
self.videoUploading = videoUploading
```

- [ ] **Step 5: Update `publishRows()` to include pending videos**

Change:
```swift
rows = olderRows + liveRows + pendingImages.map { .pendingImage($0) }
```
To:
```swift
rows = olderRows + liveRows + pendingImages.map { .pendingImage($0) } + pendingVideos.map { .pendingVideo($0) }
```

- [ ] **Step 6: Add `.video` branch to `makeRow(_:)` and update `buildStoredMessageRow`**

In `makeRow(_:)`, after the `.image` case:

```swift
case .video(let thumbnail, let remoteURL, _, let duration):
    return .message(buildStoredMessageRow(message, text: nil, imageThumbnail: thumbnail, imageRemoteURL: remoteURL, videoDuration: duration))
```

Update `buildStoredMessageRow` signature to accept `videoDuration`:

```swift
private func buildStoredMessageRow(_ message: StoredMessage, text: String?, imageThumbnail: Data?, imageRemoteURL: String?, videoDuration: Int? = nil) -> StoredMessageRow {
```

And pass it through to `StoredMessageRow` init. The `StoredMessageRow` init call inside `buildStoredMessageRow` currently ends with `senderAvatarURL: senderAvatarURL`. Add:

```swift
return StoredMessageRow(
    storageId: message.id ?? -1,
    localMessageId: message.localMessageId,
    isOutgoing: message.direction == .send,
    status: message.status,
    timestamp: message.timestamp,
    text: text,
    imageThumbnail: imageThumbnail,
    imageRemoteURL: imageRemoteURL,
    senderDisplayName: senderDisplayName,
    senderAvatarURL: senderAvatarURL,
    videoDuration: videoDuration
)
```

- [ ] **Step 7: Add `sendVideo(videoData:thumbnail:duration:)` and `startVideoUpload(_:)` methods**

After `sendFile`:

```swift
public func sendVideo(videoData: Data, thumbnail: Data, duration: Int) {
    let pending = PendingVideoUpload(id: UUID(), thumbnail: thumbnail, videoData: videoData, duration: duration, state: .uploading)
    pendingVideos.append(pending)
    publishRows()
    startVideoUpload(pending)
}

private func startVideoUpload(_ pending: PendingVideoUpload) {
    let fileName = "\(UUID().uuidString).mp4"
    videoUploading?.uploadVideo(pending.videoData, fileName: fileName) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let remoteURL):
            try? self.messageSending?.sendVideo(
                to: self.target, conversationType: self.conversationType, line: self.line,
                thumbnail: pending.thumbnail, remoteURL: remoteURL, duration: pending.duration
            )
            self.pendingVideos.removeAll { $0.id == pending.id }
        case .failure:
            if let index = self.pendingVideos.firstIndex(where: { $0.id == pending.id }) {
                self.pendingVideos[index].state = .failed
            }
        }
        self.publishRows()
    }
}
```

- [ ] **Step 8: Add `.pendingVideo` case to `retry(_:)`**

In `retry(row:)`, after `case .pendingImage`:

```swift
case .pendingVideo(let pending):
    guard let index = pendingVideos.firstIndex(where: { $0.id == pending.id }) else { return }
    pendingVideos[index].state = .uploading
    publishRows()
    startVideoUpload(pendingVideos[index])
```

Also update the `case .systemTip, .timeHeader:` line to include `.pendingVideo` if Swift requires exhaustive handling — check whether the switch is already exhaustive after adding `.pendingVideo` to the case above (it is, because `.pendingVideo` is handled explicitly now).

- [ ] **Step 9: Run tests — expect pass**

```bash
swift test --filter IMKitTests/ConversationViewModelTests
```

Expected: all pass

- [ ] **Step 10: Run full suite**

```bash
swift test
```

Expected: all pass

- [ ] **Step 11: Commit**

```bash
git add Sources/IMKit/ConversationViewModel.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat(IMKit): ConversationViewModel sendVideo, pending video rows, makeRow(.video)"
```

---

### Task 6: `VideoMessageCell`

**Files:**
- Create: `App/VideoMessageCell.swift`

**Interfaces:**
- Consumes: `StoredMessageRow.videoDuration`, `PendingVideoUpload` from Task 4
- Produces: `VideoMessageCell` with `reuseIdentifier`, `configure(with:duration:)`, `configurePending(_:)`, `onTapped: (() -> Void)?`, `onRetryTapped: (() -> Void)?`

- [ ] **Step 1: Create `App/VideoMessageCell.swift`**

```swift
import UIKit
import IMKit
import AVFoundation

struct VideoBubbleData: Equatable {
    let thumbnail: Data?
    let duration: Int
    let isOutgoing: Bool
    let isUploading: Bool
    let isFailed: Bool
    let senderDisplayName: String?
    let senderAvatarURL: String?
}

final class VideoMessageCell: UITableViewCell {
    static let reuseIdentifier = "VideoMessageCell"

    private let bubbleContainer = UIView()
    private let thumbnailView = UIImageView()
    private let playCircle = UIView()
    private let playIcon = UIImageView(image: UIImage(systemName: "play.fill"))
    private let durationLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let senderNameLabel = UILabel()
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader.shared)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()

    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTapped = nil
        onRetryTapped = nil
        thumbnailView.image = nil
        activityIndicator.stopAnimating()
    }

    private func layoutViews() {
        // Thumbnail fills the bubble
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.backgroundColor = Theme.backgroundTertiary

        // Play button circle (semi-transparent black, centered)
        playCircle.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        playCircle.layer.cornerRadius = 22
        playCircle.isUserInteractionEnabled = false
        playCircle.translatesAutoresizingMaskIntoConstraints = false

        playIcon.tintColor = .white
        playIcon.contentMode = .scaleAspectFit
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playCircle.addSubview(playIcon)

        // Duration label (bottom-right)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        durationLabel.layer.cornerRadius = 4
        durationLabel.clipsToBounds = true
        durationLabel.textAlignment = .center
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        // Activity indicator (shown during upload)
        activityIndicator.color = .white
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false

        // Retry button
        retryButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        retryButton.tintColor = .systemRed
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        // Bubble container holds thumbnail + overlays
        bubbleContainer.layer.cornerRadius = Theme.bubbleCornerRadius
        bubbleContainer.clipsToBounds = true
        bubbleContainer.isUserInteractionEnabled = true
        bubbleContainer.translatesAutoresizingMaskIntoConstraints = false
        bubbleContainer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        bubbleContainer.addSubview(thumbnailView)
        bubbleContainer.addSubview(playCircle)
        bubbleContainer.addSubview(durationLabel)
        bubbleContainer.addSubview(activityIndicator)

        senderNameLabel.font = .systemFont(ofSize: 12)
        senderNameLabel.textColor = Theme.textPrimary.withAlphaComponent(0.6)

        bubbleColumn.axis = .vertical
        bubbleColumn.spacing = 2
        bubbleColumn.addArrangedSubview(senderNameLabel)
        bubbleColumn.addArrangedSubview(bubbleContainer)

        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        rowStack.addArrangedSubview(bubbleColumn)

        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 36),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 36),

            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            bubbleContainer.widthAnchor.constraint(equalToConstant: 160),
            bubbleContainer.heightAnchor.constraint(equalToConstant: 160),

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
    }

    func configure(with data: VideoBubbleData) {
        thumbnailView.image = data.thumbnail.flatMap { UIImage(data: $0) }
        durationLabel.text = " \(formatDuration(data.duration)) "
        playCircle.isHidden = data.isUploading
        durationLabel.isHidden = data.isUploading
        activityIndicator.isHidden = !data.isUploading
        if data.isUploading { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }

        let showsSender = !data.isOutgoing && data.senderDisplayName != nil
        senderNameLabel.isHidden = !showsSender
        senderNameLabel.text = showsSender ? data.senderDisplayName : nil

        applyLayout(isOutgoing: data.isOutgoing, isFailed: data.isFailed,
                    avatarURL: data.senderAvatarURL, displayName: data.senderDisplayName ?? "")
    }

    func configurePending(_ pending: PendingVideoUpload) {
        configure(with: VideoBubbleData(
            thumbnail: pending.thumbnail,
            duration: pending.duration,
            isOutgoing: true,
            isUploading: pending.state == .uploading,
            isFailed: pending.state == .failed,
            senderDisplayName: nil,
            senderAvatarURL: nil
        ))
    }

    private func applyLayout(isOutgoing: Bool, isFailed: Bool, avatarURL: String?, displayName: String) {
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            if view !== bubbleColumn { view.removeFromSuperview() }
        }
        retryButton.removeFromSuperview()
        senderAvatarImageView.removeFromSuperview()

        if isOutgoing {
            rowStack.addArrangedSubview(spacer)
            rowStack.addArrangedSubview(bubbleColumn)
            if isFailed { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(senderAvatarImageView)
            senderAvatarImageView.setAvatar(urlString: avatarURL, displayName: "我")
        } else {
            rowStack.addArrangedSubview(senderAvatarImageView)
            rowStack.addArrangedSubview(bubbleColumn)
            rowStack.addArrangedSubview(spacer)
            senderAvatarImageView.setAvatar(urlString: avatarURL, displayName: displayName)
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    @objc private func tapped() { onTapped?() }
    @objc private func retryTapped() { onRetryTapped?() }
}
```

- [ ] **Step 2: Verify project builds**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

(If project file is stale, regenerate first: `bash Scripts/generate-xcodeproj.sh`)

- [ ] **Step 3: Commit**

```bash
git add App/VideoMessageCell.swift
git commit -m "feat(App): add VideoMessageCell with thumbnail, play button, duration label"
```

---

### Task 7: `ConversationViewController` — PHPicker, video handling, cell dispatch, playback

**Files:**
- Modify: `App/ConversationViewController.swift`

**Interfaces:**
- Consumes: `VideoMessageCell`, `ConversationViewModel.sendVideo`, `StoredMessageRow.videoDuration`, `PendingVideoUpload` from Tasks 5–6
- Produces: complete video send + display + playback flow

- [ ] **Step 1: Register `VideoMessageCell` in `layoutViews()`**

After `tableView.register(FileMessageCell.self, forCellReuseIdentifier: FileMessageCell.reuseIdentifier)`:

```swift
tableView.register(VideoMessageCell.self, forCellReuseIdentifier: VideoMessageCell.reuseIdentifier)
```

- [ ] **Step 2: Add video cases to `configureDataSource()`**

Insert before `case .message(let message)` (the existing image fallthrough — the one with no `where` clause):

```swift
case .message(let message) where message.videoDuration != nil:
    let cell = tableView.dequeueReusableCell(withIdentifier: VideoMessageCell.reuseIdentifier, for: indexPath) as! VideoMessageCell
    cell.configure(with: VideoBubbleData(
        thumbnail: message.imageThumbnail,
        duration: message.videoDuration ?? 0,
        isOutgoing: message.isOutgoing,
        isUploading: message.status == .sending,
        isFailed: message.status == .sendFailure,
        senderDisplayName: message.senderDisplayName,
        senderAvatarURL: message.senderAvatarURL
    ))
    cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
    cell.onTapped = { [weak self] in self?.presentVideoPlayer(urlString: message.imageRemoteURL) }
    return cell
case .pendingVideo(let pending):
    let cell = tableView.dequeueReusableCell(withIdentifier: VideoMessageCell.reuseIdentifier, for: indexPath) as! VideoMessageCell
    cell.configurePending(pending)
    cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
    return cell
```

- [ ] **Step 3: Change PHPickerViewController filter from `.images` to include videos**

In `presentImagePicker()`, change:

```swift
configuration.filter = .images
```
to:
```swift
configuration.filter = .any(of: [.images, .videos])
```

- [ ] **Step 4: Update `PHPickerViewControllerDelegate` to branch on media type**

Replace the full `picker(_:didFinishPicking:)` implementation:

```swift
extension ConversationViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }

        if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { self?.handlePickedImage(image) }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
                guard let url else { return }
                // Copy to a stable temp path — the provided URL is only valid
                // during this completion handler.
                let ext = url.pathExtension.lowercased().isEmpty ? "mp4" : url.pathExtension.lowercased()
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + ext)
                guard (try? FileManager.default.copyItem(at: url, to: tempURL)) != nil else { return }
                DispatchQueue.main.async { self?.handlePickedVideo(at: tempURL) }
            }
        }
    }
}
```

- [ ] **Step 5: Add `handlePickedVideo(at:)` method**

After `handlePickedImage(_:)`:

```swift
private func handlePickedVideo(at url: URL) {
    let asset = AVAsset(url: url)
    let durationSeconds = Int(CMTimeGetSeconds(asset.duration).rounded())

    let thumbnailData: Data?
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
        let uiImage = UIImage(cgImage: cgImage)
        thumbnailData = Self.makeThumbnailData(uiImage)
    } else {
        thumbnailData = nil
    }

    guard let videoData = try? Data(contentsOf: url) else { return }
    try? FileManager.default.removeItem(at: url)

    viewModel.sendVideo(videoData: videoData, thumbnail: thumbnailData ?? Data(), duration: durationSeconds)
}
```

- [ ] **Step 6: Add `presentVideoPlayer(urlString:)` method**

After `presentImagePreview(thumbnail:remoteURL:)`:

```swift
private func presentVideoPlayer(urlString: String?) {
    guard let urlString, let url = URL(string: urlString) else { return }
    let player = AVPlayer(url: url)
    let playerVC = AVPlayerViewController()
    playerVC.player = player
    present(playerVC, animated: true) { player.play() }
}
```

This requires `import AVKit` — add at the top of the file after `import AVFoundation`:

```swift
import AVKit
```

- [ ] **Step 7: Wire `videoUploading` in all 4 `ConversationViewModel` init calls in `SceneDelegate.swift`**

`App/SceneDelegate.swift` has 4 `ConversationViewModel(` calls (lines ~130, ~158, ~276, ~314). In each one, add `videoUploading:` after `fileUploading:`:

```swift
let conversationViewModel = ConversationViewModel(
    storage: self.environment.storage,
    messageSending: self.environment.messagingService,
    imageUploading: self.environment.mediaUploadService,
    voiceUploading: self.environment.mediaUploadService,
    fileUploading: self.environment.mediaUploadService,
    videoUploading: self.environment.mediaUploadService,   // ← add this line
    target: ...,
    conversationType: ...,
    ...
)
```

- [ ] **Step 8: Build**

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 9: Run full test suite**

```bash
swift test
```

Expected: all pass

- [ ] **Step 10: Commit**

```bash
git add App/ConversationViewController.swift
git commit -m "feat(App): video send/receive/playback — PHPicker, VideoMessageCell dispatch, AVPlayerViewController"
```
