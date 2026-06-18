# Phase 1 / Plan H: Media Upload Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the image-upload protocol layer — requesting a presigned MinIO upload URL over the wire, then PUTting the image bytes to it — so Plan I's chat screen can actually send image messages. `MessagingService.sendImage(thumbnail:remoteURL:)` (Plan D) already assumes a `remoteURL` has been obtained; nothing in this codebase obtains one yet.

**Architecture:** A new `IMMedia` SwiftPM target (depending only on `IMClient`/`IMProto`/`IMTransport` — no `IMStorage`, since this layer is pure network plumbing with no persistence) holds `MinioUploadURLHandler` (a `MessageHandler` parsing the `PUB_ACK`/`GMURL` response), `MinioUploadURLTracker` (correlates a request to its response by wire `messageId`, mirroring `IMMessaging`'s `OutgoingMessageTracker`), and `MediaUploadService` (the facade: generates the upload key, requests the presigned URL over the wire, awaits it via `async`/`await`, then PUTs the image bytes to it via `URLSession`, returning the final `remoteURL` string). `AppEnvironment` constructs one alongside `MessagingService`/`ContactSyncService`.

**Tech Stack:** Builds on existing Plan A–B targets (`IMClient`/`IMProto`/`IMTransport`) plus plain `URLSession` for the HTTP PUT — no object-storage SDK, no new external dependency.

---

**Reference facts this plan is built from** (verified by reading the actual Android client and chat-server-pro source — not assumed):

- **This was a known open risk from the very start of this project**: the original migration design doc's §11 risk list already flagged "图片消息对象存储 —— Android 用 MinIO/七牛上传... 实现阶段要确认是直传 URL 还是分片上传" (confirm at implementation time whether it's direct-to-URL or chunked upload) — this plan resolves that risk.
- **MinIO is the active production path; Qiniu is a legacy/secondary fallback, explicitly out of scope for this plan.** Verified server-side: `chat-server-pro`'s `application.properties` configures a real MinIO endpoint/credentials; Qiniu's equivalent handler is only reached behind a `MediaServerConfig.USER_QINIU` flag. The Android client has TWO upload paths — MinIO (`GetMinioUploadUrlHandler`, a simple presigned-URL PUT) and Qiniu (`QiniuTokenHandler`, using Qiniu's vendor SDK for resumable/chunked upload, no iOS equivalent without integrating a third-party SDK). This plan only ports the MinIO path.
- **Wire protocol, verified against both the Android client and the real chat-server-pro server**: request is `Signal.PUBLISH`/`SubSignal.GMURL` with body `Im_GetMinioUploadUrlRequest{type: Int32, key: String}` (protobuf, same convention as Plan D/F/G's other `PUBLISH`-signal business messages). Response is `Signal.PUB_ACK`/`SubSignal.GMURL`, body "1 byte error code, then `Im_GetMinioUploadUrlResult`" — the same universal `PUB_ACK` convention already fixed in `ReceiveMessageHandler` and followed by `FriendSyncHandler`/`UserInfoSyncHandler`/`MessageSendAckHandler` — verified directly against `GetMinioUploadUrlHandler.java`'s `int errorCode = byteBufferList.get(); ... if (errorCode == 0) { parse... }` gate, not just assumed by precedent. `Im_GetMinioUploadUrlResult{domain: String, server: String, port: Int32, url: String}` — `domain` and `url` are the two fields this plan actually uses.
- **`type` is a media-type-to-bucket-routing value, not `MessageContentType`** — for an image, Android hardcodes `type = 1` (`MessageContentMediaType.IMAGE.getValue()`, a *different* enum from `MessageContentType.image = 3` already used elsewhere in this codebase — do not confuse the two). Server-side, `type` only selects which MinIO bucket the file lands in (`GetMinioUploadUrlHandler.java`'s bucket-name switch); it does no content validation. This plan only ever sends `type: 1` (images only — voice/video upload, other `type` values, are out of Phase 1 scope).
- **`key` is generated client-side**, verified verbatim from `AbstractProtoService.java`: `mediaType + "-" + getUserName() + "-" + System.currentTimeMillis() + ".png"` — e.g. `"1-u123-1718953200000.png"`. This plan's Swift port matches this exactly: `"\(mediaType)-\(userId)-\(nowMillis).png"`.
- **The final `remoteURL` is constructed client-side, not returned by the upload response**: `domain + "/" + key` (Android: `minioMessage.getDomain() + "/" + key`, confirmed in `AbstractProtoService.java`'s upload-completion callback). The presigned PUT response itself is discarded once it succeeds (HTTP 200) — only its *status* matters, not its body.
- **The HTTP PUT sets `Content-Type: application/binary`** (verified in Android's `ByteBody.java`) — not `image/png` despite the `.png` filename extension in `key`. This plan matches that exactly, since the server doesn't validate content-type but there's no reason to deviate from a confirmed-working header.
- **No chunking, no multi-step upload** — it's a single `PUT <bytes>` to the presigned URL Visa `URLSession.upload(for:from:)` (or `.data(for:)` with `httpBody`), checking for HTTP 200. This is the entire reason this plan is feasible without a vendor SDK.
- **Thumbnail generation is explicitly out of scope for this plan** — Android embeds a separately-generated small JPEG thumbnail directly in the wire message (`Im_MessageContent.data`), never uploaded to object storage; only the full-size image goes through this plan's upload flow. Generating that thumbnail from a picked `UIImage` is Plan I's job (a `UIKit`-dependent concern, this plan's `IMMedia` target deliberately has no `UIKit` dependency, consistent with `IMKit`'s `AvatarLoader` design in Plan G).
- **`SubSignal.gmurl` (34) and `Im_GetMinioUploadUrlRequest`/`Im_GetMinioUploadUrlResult` already exist** in `Sources/IMTransport/SubSignal.swift` and `Sources/IMProto/Generated/WFCMessage.pb.swift` (Plan A generated the whole `chat-proto` file) — no enum or codegen changes needed.
- **No `IMStorage` dependency needed**: unlike `MessagingService`/`ContactSyncService`, this layer never reads or writes `IMStorage` — it's a pure request-a-URL-then-PUT-bytes utility. `IMMedia`'s target dependencies are just `["IMClient", "IMProto", "IMTransport"]`.

---

## Task 1: Scaffold the `IMMedia` SwiftPM target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/IMMedia/_Scaffold.swift`
- Create: `Tests/IMMediaTests/_Scaffold.swift`

- [ ] **Step 1: Edit `Package.swift`**

Add to `products` (after `IMKit`):

```swift
        .library(name: "IMMedia", targets: ["IMMedia"]),
```

Add to `targets` (after `IMKit`'s entries):

```swift
        .target(name: "IMMedia", dependencies: ["IMClient", "IMProto", "IMTransport"]),
        .testTarget(name: "IMMediaTests", dependencies: ["IMMedia"]),
```

Add `IMMedia` to `AppCore`'s target dependencies (`AppEnvironment`, Task 5, needs to construct `MediaUploadService`):

```swift
        .target(name: "AppCore", dependencies: ["IMClient", "IMStorage", "IMMessaging", "IMContacts", "IMMedia"]),
```

- [ ] **Step 2: Create placeholder source**

```bash
mkdir -p Sources/IMMedia Tests/IMMediaTests
echo "// IMMedia placeholder, removed in Task 2" > Sources/IMMedia/_Scaffold.swift
echo "// IMMediaTests placeholder, removed in Task 2" > Tests/IMMediaTests/_Scaffold.swift
```

- [ ] **Step 3: Build and test**

```bash
swift build
swift test
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `swift build` → `Build complete!`; `swift test` → all previously-existing tests still pass; `xcodebuild` → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift ios-chat-pro.xcodeproj Sources/IMMedia Tests/IMMediaTests
git commit -m "chore: scaffold IMMedia SwiftPM target"
```

---

## Task 2: `MinioUploadURLTracker`

Correlates a `GMURL` request to its response by the wire `messageId` `IMClient.sendFrame` returns — the exact same shape as `IMMessaging`'s `OutgoingMessageTracker` (Plan D), just for a different `SubSignal`.

**Files:**
- Create: `Sources/IMMedia/MinioUploadURLTracker.swift`
- Test: `Tests/IMMediaTests/MinioUploadURLTrackerTests.swift`
- Modify: delete `Sources/IMMedia/_Scaffold.swift`, delete `Tests/IMMediaTests/_Scaffold.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMMediaTests/MinioUploadURLTrackerTests.swift
import XCTest
import IMClient
import IMProto
@testable import IMMedia

final class MinioUploadURLTrackerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: MinioUploadURLTracker!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = MinioUploadURLTracker(scheduler: scheduler)
    }

    private func makeResult(url: String) -> Im_GetMinioUploadUrlResult {
        var result = Im_GetMinioUploadUrlResult()
        result.domain = "https://media.example.com"
        result.url = url
        return result
    }

    func test_resolve_afterTrack_invokesCompletionWithSuccess() {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .success(makeResult(url: "https://put.example.com/presigned")))

        switch captured {
        case .success(let result): XCTAssertEqual(result.url, "https://put.example.com/presigned")
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_resolve_withFailure_invokesCompletionWithFailure() {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .failure(.serverError(errorCode: 6)))

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_resolve_unknownWireMessageId_doesNothingNoCrash() {
        tracker.resolve(wireMessageId: 42, result: .success(makeResult(url: "https://put.example.com/x"))) // no track() call first
    }

    func test_timeout_firesFailureWithTimeoutError_ifNoResponseArrives() {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        XCTAssertEqual(scheduler.scheduledDelays, [5])
        XCTAssertTrue(scheduler.fireNext())

        switch captured {
        case .failure(.timeout): break
        default: XCTFail("expected .failure(.timeout), got \(String(describing: captured))")
        }
    }

    func test_resolve_beforeTimeoutFires_cancelsTheTimeout() {
        var completionCallCount = 0
        tracker.track(wireMessageId: 7) { _ in completionCallCount += 1 }

        tracker.resolve(wireMessageId: 7, result: .success(makeResult(url: "https://put.example.com/x")))
        XCTAssertEqual(completionCallCount, 1)

        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(completionCallCount, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MinioUploadURLTrackerTests`
Expected: FAIL with `error: cannot find type 'MinioUploadURLTracker' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMMedia/MinioUploadURLTracker.swift
import IMClient
import IMProto

/// Correlates an outgoing `Signal.PUBLISH`/`SubSignal.GMURL` request to its
/// response by the wire `messageId` `IMClient.sendFrame` returned — same
/// shape as `IMMessaging`'s `OutgoingMessageTracker`. Schedules a
/// 5-second timeout (matching the same constant used elsewhere in this
/// codebase for `PUB_ACK` waits) that resolves as `.timeout` if no response
/// arrives in time.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class MinioUploadURLTracker {
    public enum TrackerError: Error, Equatable {
        case serverError(errorCode: Int32)
        case timeout
    }

    private final class Pending {
        let completion: (Result<Im_GetMinioUploadUrlResult, TrackerError>) -> Void
        var timeoutToken: SchedulerToken?

        init(completion: @escaping (Result<Im_GetMinioUploadUrlResult, TrackerError>) -> Void) {
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, completion: @escaping (Result<Im_GetMinioUploadUrlResult, TrackerError>) -> Void) {
        let entry = Pending(completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failure(.timeout))
        }
        pending[wireMessageId] = entry
    }

    /// Called by `MinioUploadURLHandler` when a `PUB_ACK`/`GMURL` frame
    /// arrives, or internally when the timeout fires. A no-op if
    /// `wireMessageId` isn't (or is no longer) tracked.
    public func resolve(wireMessageId: UInt16, result: Result<Im_GetMinioUploadUrlResult, TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
```

- [ ] **Step 4: Remove Task 1 scaffolding**

```bash
rm -f Sources/IMMedia/_Scaffold.swift Tests/IMMediaTests/_Scaffold.swift
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MinioUploadURLTrackerTests`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMMedia/MinioUploadURLTracker.swift Tests/IMMediaTests/MinioUploadURLTrackerTests.swift
git add -u Sources/IMMedia Tests/IMMediaTests
git commit -m "feat(IMMedia): add MinioUploadURLTracker"
```

---

## Task 3: `MinioUploadURLHandler`

**Files:**
- Create: `Sources/IMMedia/MinioUploadURLHandler.swift`
- Test: `Tests/IMMediaTests/MinioUploadURLHandlerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMMediaTests/MinioUploadURLHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
@testable import IMMedia

final class MinioUploadURLHandlerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: MinioUploadURLTracker!
    private var handler: MinioUploadURLHandler!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = MinioUploadURLTracker(scheduler: scheduler)
        handler = MinioUploadURLHandler(tracker: tracker)
    }

    private func makeFrame(errorCode: UInt8, domain: String = "", url: String = "") throws -> Frame {
        var result = Im_GetMinioUploadUrlResult()
        result.domain = domain
        result.url = url
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .gmurl, bodyLength: UInt32(body.count), messageId: 9), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndGMURL() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .gmurl))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .fp))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .gmurl))
    }

    func test_handle_successBody_resolvesTrackerWithResult() throws {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let frame = try makeFrame(errorCode: 0, domain: "https://media.example.com", url: "https://put.example.com/presigned")
        handler.handle(frame: frame)

        switch captured {
        case .success(let result):
            XCTAssertEqual(result.domain, "https://media.example.com")
            XCTAssertEqual(result.url, "https://put.example.com/presigned")
        default:
            XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_handle_nonZeroErrorCode_resolvesTrackerWithServerError() throws {
        var captured: Result<Im_GetMinioUploadUrlResult, MinioUploadURLTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let frame = try makeFrame(errorCode: 6)
        handler.handle(frame: frame)

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .gmurl, bodyLength: 0, messageId: 9), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MinioUploadURLHandlerTests`
Expected: FAIL with `error: cannot find type 'MinioUploadURLHandler' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMMedia/MinioUploadURLHandler.swift
import IMClient
import IMTransport
import IMProto

/// Parses the `PUB_ACK`/`GMURL` response to a presigned-upload-URL request
/// and resolves the matching `MinioUploadURLTracker` entry. Same "1 byte
/// error code, then protobuf" wire format as every other `PUB_ACK` handler
/// in this codebase — see this plan's "Reference facts".
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class MinioUploadURLHandler: MessageHandler {
    private let tracker: MinioUploadURLTracker

    public init(tracker: MinioUploadURLTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .gmurl
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        if errorCode == 0 {
            guard let result = try? Im_GetMinioUploadUrlResult(serializedBytes: frame.body.dropFirst()) else { return }
            tracker.resolve(wireMessageId: frame.header.messageId, result: .success(result))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.serverError(errorCode: Int32(errorCode))))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MinioUploadURLHandlerTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMMedia/MinioUploadURLHandler.swift Tests/IMMediaTests/MinioUploadURLHandlerTests.swift
git commit -m "feat(IMMedia): add MinioUploadURLHandler"
```

---

## Task 4: `MediaUploadService`

The facade: generates the upload key, sends the wire request, and on a successful response, PUTs the image bytes to the presigned URL.

**A deliberate API design choice, to keep this fully testable without flaky timing**: `uploadImage` takes a completion handler, not `async`/`await`, for its overall shape — matching this codebase's established style for "fire a wire request, get notified later" services (`OutgoingMessageTracker`, `ContactSyncService`). Only the actual HTTP PUT step (a single self-contained `URLSession` call with no cross-callback timing dependency) uses `async`/`await` internally, exactly like `LoginAPIClient`/`AvatarLoader`. This split avoids the exact kind of flaky test that an earlier plan in this project hit and had to remove (a hand-rolled `Task{}`/continuation construction for a genuine concurrent-call race) — here there's no race to construct: the wire round-trip is driven synchronously by the test calling `fakeTransport.simulateReceivedData(...)` directly, and only the final HTTP-PUT completion is awaited via `XCTestExpectation`, the same reliable pattern already used throughout this project's Combine-based view model tests.

**Files:**
- Create: `Sources/IMMedia/MediaUploadService.swift`
- Create: `Tests/IMMediaTests/Support/FakeTransportConnection.swift` (same rationale as every other plan's local copy of this fake — `internal` types don't cross SwiftPM test targets)
- Create: `Tests/IMMediaTests/Support/MockURLProtocol.swift` (same rationale, for the HTTP PUT half)
- Test: `Tests/IMMediaTests/MediaUploadServiceTests.swift`

- [ ] **Step 1: Add the local test support**

```swift
// Tests/IMMediaTests/Support/FakeTransportConnection.swift
import Foundation
import IMClient

final class FakeTransportConnection: IMTransportConnection {
    var onEvent: ((IMTransportEvent) -> Void)?
    var onDataReceived: ((Data) -> Void)?

    private(set) var sentFrames: [Data] = []

    func start() {}
    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        sentFrames.append(data)
        completion(.success(()))
    }
    func cancel() {}

    func simulate(_ event: IMTransportEvent) { onEvent?(event) }
    func simulateReceivedData(_ data: Data) { onDataReceived?(data) }
}
```

```swift
// Tests/IMMediaTests/Support/MockURLProtocol.swift
import Foundation

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/IMMediaTests/MediaUploadServiceTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
@testable import IMMedia

final class MediaUploadServiceTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var imClient: IMClient!
    private var service: MediaUploadService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "u1", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        service = MediaUploadService(imClient: imClient, session: MockURLProtocol.makeSession(), nowMillis: { 1_000 })

        imClient.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()
    }

    private func decodeOnlySentFrame() throws -> Frame {
        try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
    }

    private func simulateGMURLResponse(domain: String, url: String) throws {
        var result = Im_GetMinioUploadUrlResult()
        result.domain = domain
        result.url = url
        let body = Data([0x00]) + (try result.serializedData())
        let frame = try decodeOnlySentFrame()
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .gmurl, messageId: frame.header.messageId, body: body)
        fakeTransport.simulateReceivedData(frameBytes)
    }

    func test_uploadImage_sendsGMURLRequestWithExpectedKeyAndType() throws {
        service.uploadImage(Data([0x01])) { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .gmurl)
        let request = try Im_GetMinioUploadUrlRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.type, 1)
        XCTAssertEqual(request.key, "1-u1-1000.png")
    }

    func test_uploadImage_endToEnd_returnsConstructedRemoteURL() throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        var capturedResult: Result<String, MediaUploadError>?
        let expectation = expectation(description: "upload completes")
        service.uploadImage(Data([0x01, 0x02])) { result in
            capturedResult = result
            expectation.fulfill()
        }

        try simulateGMURLResponse(domain: "https://media.example.com", url: "https://put.example.com/presigned")
        wait(for: [expectation], timeout: 2)

        switch capturedResult {
        case .success(let url): XCTAssertEqual(url, "https://media.example.com/1-u1-1000.png")
        default: XCTFail("expected .success, got \(String(describing: capturedResult))")
        }
    }

    func test_uploadImage_httpPutFailure_resolvesWithHttpFailureError() throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        var capturedResult: Result<String, MediaUploadError>?
        let expectation = expectation(description: "upload completes")
        service.uploadImage(Data([0x01])) { result in
            capturedResult = result
            expectation.fulfill()
        }

        try simulateGMURLResponse(domain: "https://media.example.com", url: "https://put.example.com/presigned")
        wait(for: [expectation], timeout: 2)

        switch capturedResult {
        case .failure(.httpFailure(let statusCode)): XCTAssertEqual(statusCode, 500)
        default: XCTFail("expected .httpFailure, got \(String(describing: capturedResult))")
        }
    }

    func test_uploadImage_wireErrorResponse_resolvesWithWireError() throws {
        var capturedResult: Result<String, MediaUploadError>?
        let expectation = expectation(description: "upload completes")
        service.uploadImage(Data([0x01])) { result in
            capturedResult = result
            expectation.fulfill()
        }

        let frame = try decodeOnlySentFrame()
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .gmurl, messageId: frame.header.messageId, body: Data([0x06]))
        fakeTransport.simulateReceivedData(frameBytes)
        wait(for: [expectation], timeout: 2)

        switch capturedResult {
        case .failure(.wireError(.serverError(let code))): XCTAssertEqual(code, 6)
        default: XCTFail("expected .wireError(.serverError), got \(String(describing: capturedResult))")
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter MediaUploadServiceTests`
Expected: FAIL with `error: cannot find type 'MediaUploadService' in scope`

- [ ] **Step 4: Implement**

```swift
// Sources/IMMedia/MediaUploadService.swift
import Foundation
import IMClient
import IMProto

public enum MediaUploadError: Error, Equatable {
    case wireError(MinioUploadURLTracker.TrackerError)
    case requestEncodingFailed
    case invalidUploadURL
    case httpFailure(statusCode: Int)
}

/// Generates the upload key, requests a presigned MinIO URL over the wire,
/// and PUTs the image bytes to it. See this plan's "Reference facts" for
/// the exact key format / `Content-Type` / final-URL-construction details,
/// verified against the real Android client and server.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class MediaUploadService {
    private let imClient: IMClient
    private let tracker: MinioUploadURLTracker
    private let session: URLSession
    private let nowMillis: () -> Int64

    public init(
        imClient: IMClient,
        scheduler: Scheduler = DispatchQueueScheduler(),
        session: URLSession = .shared,
        nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.imClient = imClient
        tracker = MinioUploadURLTracker(scheduler: scheduler)
        self.session = session
        self.nowMillis = nowMillis
        imClient.register(MinioUploadURLHandler(tracker: tracker))
    }

    /// Uploads `data` (a full-size image — thumbnail generation is Plan I's
    /// job, see this plan's "Reference facts") and returns the final
    /// remote URL string to embed in an outgoing image message's
    /// `remoteURL` field.
    public func uploadImage(_ data: Data, completion: @escaping (Result<String, MediaUploadError>) -> Void) {
        let key = "1-\(imClient.userId)-\(nowMillis()).png"

        var wireRequest = Im_GetMinioUploadUrlRequest()
        wireRequest.type = 1
        wireRequest.key = key
        guard let body = try? wireRequest.serializedData() else {
            completion(.failure(.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gmurl, body: body)

        tracker.track(wireMessageId: wireMessageId) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(.wireError(error)))
            case .success(let uploadResult):
                Task { await self.performUpload(data: data, uploadResult: uploadResult, key: key, completion: completion) }
            }
        }
    }

    private func performUpload(
        data: Data,
        uploadResult: Im_GetMinioUploadUrlResult,
        key: String,
        completion: @escaping (Result<String, MediaUploadError>) -> Void
    ) async {
        guard let url = URL(string: uploadResult.url) else {
            completion(.failure(.invalidUploadURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/binary", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            completion(.failure(.httpFailure(statusCode: -1)))
            return
        }
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            completion(.failure(.httpFailure(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)))
            return
        }

        completion(.success("\(uploadResult.domain)/\(key)"))
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MediaUploadServiceTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 6: Run the entire suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/IMMedia/MediaUploadService.swift Tests/IMMediaTests/Support/FakeTransportConnection.swift Tests/IMMediaTests/Support/MockURLProtocol.swift Tests/IMMediaTests/MediaUploadServiceTests.swift
git commit -m "feat(IMMedia): add MediaUploadService facade"
```

---

## Task 5: Wire `MediaUploadService` into `AppEnvironment`

**Files:**
- Modify: `Sources/AppCore/AppEnvironment.swift`
- Modify: `Tests/AppCoreTests/AppEnvironmentTests.swift`

- [ ] **Step 1: Write the failing test**

Read `Tests/AppCoreTests/AppEnvironmentTests.swift`'s current content first. Append this test:

```swift
    func test_connectIfPossible_withCredentials_alsoConstructsMediaUploadService() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))

        XCTAssertTrue(environment.connectIfPossible())

        XCTAssertNotNil(environment.mediaUploadService)
    }

    func test_logOut_clearsMediaUploadService() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))
        environment.connectIfPossible()

        environment.logOut()

        XCTAssertNil(environment.mediaUploadService)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter AppEnvironmentTests`
Expected: FAIL with `error: value of type 'AppEnvironment' has no member 'mediaUploadService'`

- [ ] **Step 3: Implement**

In `Sources/AppCore/AppEnvironment.swift`, add the import near the top:

```swift
import IMMedia
```

Add a stored property (near `contactSyncService`):

```swift
    public private(set) var mediaUploadService: MediaUploadService?
```

In `connectIfPossible()`, after the existing `contactSyncService = contactSync` line and before `client.connect()`, add:

```swift
        mediaUploadService = MediaUploadService(imClient: client)
```

In `logOut()`, also clear the new property:

```swift
    public func logOut() {
        imClient?.disconnect()
        imClient = nil
        messagingService = nil
        contactSyncService = nil
        mediaUploadService = nil
        credentialsStore.clear()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppEnvironmentTests`
Expected: all `AppEnvironmentTests` pass, including the two new ones.

- [ ] **Step 5: Run the full suite and the Xcode build**

```bash
swift test
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: all tests pass; `** BUILD SUCCEEDED **`. Check `git status` for a regenerated `project.pbxproj` and include it in the commit if changed (this Xcode project uses an explicit file list — a gotcha hit in several earlier plans).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/AppEnvironment.swift Tests/AppCoreTests/AppEnvironmentTests.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(AppCore): construct MediaUploadService alongside the other connect-time services"
```

---

## Task 6: End-to-end build/test verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full `swift test` suite**

```bash
swift test
```

Expected: all tests pass (205 from Plans A–G + this plan's new `IMMediaTests`/`AppCoreTests` additions).

- [ ] **Step 2: Build the App target**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Simulator smoke test**

```bash
xcrun simctl boot "iPhone 15" 2>/dev/null || true
APP_PATH=$(find .build/xcode/Build/Products -name "App.app" -maxdepth 2 | head -1)
xcrun simctl install "iPhone 15" "$APP_PATH"
xcrun simctl launch "iPhone 15" com.fshare.ios-chat-pro.App
xcrun simctl io "iPhone 15" screenshot /tmp/plan-h-smoke-test.png
```

This plan doesn't touch any UI, so there's no new screen to visually verify — this step just confirms the App target still launches without crashing after this plan's changes (the previous plan's session finally got `simctl install`/`launch` working in this environment after several earlier attempts hung; if it hangs again here, fall back to `swift test` + `xcodebuild` as the strongest available verification, consistent with the pattern already documented in Plan E/F/G's self-review notes, rather than spending excessive time re-litigating a known environment quirk).

No commit for this task — it's a verification gate, not new code.

---

## Plan Self-Review Notes

- **Spec coverage:** Resolves the open risk flagged in the original migration design doc's §11 ("图片消息对象存储... 实现阶段要确认是直传 URL 还是分片上传") by porting the MinIO direct-PUT path. Does **not** port the Qiniu fallback path (vendor-SDK-based resumable upload, not a presigned-URL PUT — would need a third-party iOS SDK integration, out of scope; MinIO is confirmed as the active production path, not a guess).
- **Voice/video upload, or any `type` value other than `1` (image), is out of scope** — Phase 1 is text+image only per the migration design doc's roadmap; this plan's `MediaUploadService` only ever sends `type: 1`.
- **Thumbnail generation is explicitly Plan I's job**, not this plan's — this plan only uploads whatever `Data` it's given (the full-size image); resizing/compressing a picked `UIImage` into a small embedded thumbnail is `UIKit`-dependent work this plan's deliberately-`UIKit`-free `IMMedia` target doesn't do.
- **`MediaUploadService` registering a handler in its initializer is a side effect**, same accepted Phase-1 double-construction risk already documented for `MessagingService`/`ContactSyncService` — constructing a second `MediaUploadService` against the same `IMClient` would register a duplicate handler. Not a concern since `AppEnvironment` constructs exactly one.
- **No retry logic for a failed upload** — if the HTTP PUT fails (network error, non-200 status), `uploadImage`'s completion fires with `.httpFailure`/`.wireError` and the caller (Plan I) is responsible for deciding what to show the user (e.g. marking the message `.sendFailure`, matching the pattern already established for text-message send failures in `MessagingService`). No automatic retry is built here.
- **`MediaUploadService` is independent of `IMStorage`** — it never persists anything itself; Plan I's chat screen is responsible for calling `uploadImage`, then passing the resulting `remoteURL` into `MessagingService.sendImage(thumbnail:remoteURL:)` (already built in Plan D), which is the thing that actually writes to `IMStorage`.
- **No placeholders:** every step above has complete, runnable code; nothing is left as "TODO" or "similar to above."

