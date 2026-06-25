# Phase 4「我的」Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 Phase 4 第一个子项目——对齐 `android-chat-pro`(`MeFragment`)的「我的」Tab:资料卡、改昵称、改头像、个人二维码、设置(主题/关于/退出登录),并修复退出登录从不清本地会话数据/同步游标的真实 bug。

**Architecture:** 新增能力分布在现有模块体系里,不新建 SPM package。`IMContacts.ContactSyncService` 新增 `updateDisplayName`/`updatePortrait`(走协议已定义、目前零引用的 `SubSignal.mmi`,新增 `ProfileUpdateTracker`/`ProfileUpdateHandler` 走"1 字节错误码"ack 模式,与 `FriendRequestActionTracker`/`Handler` 同构);`IMStorage` 新增 `clearSessionData()`;`AppCore` 新增 `ThemePreferenceStore`,扩展 `AppEnvironment.logOut()`;`IMKit` 新增 `ProfileUpdating` 协议、`MyProfileViewModel`、`QRCodeContent`;`App` 新增 6 个文件(`MeViewController`/`MyProfileViewController`/`MyQRCodeViewController`/`SettingsViewController`/`ThemeViewController`/`AboutViewController`/`ThemeMode+UIKit`),`SceneDelegate` 扩成 3 个 tab。

**Tech Stack:** Swift 5.8 / SPM / GRDB / Combine / UIKit / PhotosUI(`PHPickerViewController`,已有依赖)/ CoreImage(`CIQRCodeGenerator`)/ xcodegen(`./Scripts/generate-xcodeproj.sh`)。

## Global Constraints

- 不新增 SPM package,不新增 proto 文件,不新增 `SubSignal`(`mmi` 协议里已定义)。
- 退出登录只清 `message`/`conversation` 表 + 重置 `syncState`,**不**清 `user`/`groupInfo`/`groupMember`/`friendRequest` 表(对齐 Android `SqliteDatabaseStore.stop()` 的范围)。
- 改资料只做昵称(`InfoEntry.type=0`)和头像(`type=1`),不加性别/手机号等字段编辑入口。
- 个人二维码内容固定为 `wildfirechat://user/{uid}`,不做扫码。
- 关于页三个链接(功能介绍/用户协议/隐私政策)用占位 URL(`https://example.com/...`),标注待替换。
- 主题用 `window.overrideUserInterfaceStyle` 立即生效,不要求重启 App。
- App 层(`App/*.swift`)没有 XCTest 覆盖(`ios-chat-pro.xcodeproj` 是独立工程,无测试 target);每个改动 App 层文件的任务,验证步骤是 `./Scripts/generate-xcodeproj.sh` + `xcodebuild` 编译通过,不是单测。

---

## Task 1: `IMStorage.clearSessionData()`

**Files:**
- Modify: `Sources/IMStorage/IMStorage.swift`
- Test: `Tests/IMStorageTests/IMStorageTests.swift`

**Interfaces:**
- Produces: `IMStorage.clearSessionData() throws` — deletes all `message`/`conversation` rows, resets `syncState` to all-zero. `user`/`groupInfo`/`groupMember`/`friendRequest` untouched.

- [ ] **Step 1: 写失败的测试**

在 `Tests/IMStorageTests/IMStorageTests.swift` 末尾(`test_friendRequests_isWiredIntoFacade` 之后)追加:

```swift
    func test_clearSessionData_deletesMessagesAndConversationsAndResetsSyncState() throws {
        let storage = try IMStorage.openInMemory()
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send
        ))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)
        try storage.syncState.set(StoredSyncState(msgHead: 42, friendHead: 7, friendRequestHead: 3, settingHead: 9))
        try storage.users.upsert(StoredUser(uid: "u2", name: "bob", displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 1))

        try storage.clearSessionData()

        XCTAssertNil(try storage.messages.message(localMessageId: 1))
        XCTAssertTrue(try storage.conversations.conversations().isEmpty)
        let syncState = try storage.syncState.get()
        XCTAssertEqual(syncState.msgHead, 0)
        XCTAssertEqual(syncState.friendHead, 0)
        XCTAssertEqual(syncState.friendRequestHead, 0)
        XCTAssertEqual(syncState.settingHead, 0)
        // users table is untouched — matches Android's SqliteDatabaseStore.stop() scope
        XCTAssertEqual(try storage.users.user(uid: "u2")?.displayName, "Bob")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter IMStorageTests`
Expected: FAIL — `IMStorage` 没有 `clearSessionData()` 方法,编译错误。

- [ ] **Step 3: 实现**

在 `Sources/IMStorage/IMStorage.swift`,`write<T>` 方法之后追加:

```swift
    /// Clears the locally cached chat history on logout, matching Android's
    /// `SqliteDatabaseStore.stop()` scope exactly: deletes every row from
    /// `message`/`conversation` and resets `syncState` back to its all-zero
    /// defaults — the iOS equivalent of Android also `clear()`-ing the
    /// SharedPreferences that hold its sync cursors. `users`/`groups`/
    /// `friendRequests` are deliberately left untouched — Android doesn't
    /// clear them either, and the next login's normal sync flow overwrites
    /// them anyway. Without the `syncState` reset, logging into a different
    /// account on the same device would resume incremental sync from the
    /// previous account's cursors, silently dropping messages.
    public func clearSessionData() throws {
        try database.dbQueue.write { db in
            try StoredMessage.deleteAll(db)
            try StoredConversation.deleteAll(db)
            try StoredSyncState(msgHead: 0, friendHead: 0, friendRequestHead: 0, settingHead: 0).save(db)
        }
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter IMStorageTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/IMStorage.swift Tests/IMStorageTests/IMStorageTests.swift
git commit -m "feat(IMStorage): add clearSessionData for logout"
```

## Task 2: `ProfileUpdateTracker` + `ProfileUpdateHandler`(`.mmi` 裸 ack 收发)

**Files:**
- Create: `Sources/IMContacts/ProfileUpdateTracker.swift`
- Create: `Sources/IMContacts/ProfileUpdateHandler.swift`
- Test: `Tests/IMContactsTests/ProfileUpdateTrackerTests.swift`
- Test: `Tests/IMContactsTests/ProfileUpdateHandlerTests.swift`

`SubSignal.mmi`(28)协议里已定义、目前全代码库零引用。Android 端确认 `ModifyMyInfoRequest` 的 ack 是裸"1 字节错误码,无 payload"(同 `.far`/`.fhr`),所以这两个新类型逐字仿照 `FriendRequestActionTracker`/`FriendRequestActionHandler`,只是只对应一个 subSignal。

**Interfaces:**
- Produces: `ProfileUpdateTracker.TrackerError`(`.serverError(errorCode:)`/`.timeout`)、`ProfileUpdateTracker.track(wireMessageId:completion:)`/`resolve(wireMessageId:result:)`、`ProfileUpdateHandler(tracker:)` 实现 `MessageHandler`,`canHandle` 匹配 `signal == .pubAck && subSignal == .mmi`。

- [ ] **Step 1: 写失败的测试(Tracker)**

创建 `Tests/IMContactsTests/ProfileUpdateTrackerTests.swift`:

```swift
import XCTest
import IMClient
@testable import IMContacts

final class ProfileUpdateTrackerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: ProfileUpdateTracker!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = ProfileUpdateTracker(scheduler: scheduler)
    }

    func test_resolve_afterTrack_invokesCompletionWithSuccess() {
        var captured: Result<Void, ProfileUpdateTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .success(()))

        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_resolve_withFailure_invokesCompletionWithFailure() {
        var captured: Result<Void, ProfileUpdateTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .failure(.serverError(errorCode: 6)))

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_resolve_unknownWireMessageId_doesNothingNoCrash() {
        tracker.resolve(wireMessageId: 42, result: .success(())) // no track() call first
    }

    func test_timeout_firesFailureWithTimeoutError_ifNoResponseArrives() {
        var captured: Result<Void, ProfileUpdateTracker.TrackerError>?
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

        tracker.resolve(wireMessageId: 7, result: .success(()))
        XCTAssertEqual(completionCallCount, 1)

        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(completionCallCount, 1)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ProfileUpdateTrackerTests`
Expected: FAIL — `ProfileUpdateTracker` 不存在,编译错误。

- [ ] **Step 3: 实现 Tracker**

创建 `Sources/IMContacts/ProfileUpdateTracker.swift`:

```swift
import IMClient

/// Correlates an outgoing `Signal.publish`/`.mmi` (modify my info) call to
/// its response by wire `messageId`. Like `FriendRequestActionTracker`,
/// `.mmi`'s ack is a bare "1 byte error code, no payload" response
/// (verified against the Android/server reference), so this resolves to
/// plain `Void` on success rather than a parsed payload.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ProfileUpdateTracker {
    public enum TrackerError: Error, Equatable {
        case serverError(errorCode: Int32)
        case timeout
    }

    private final class Pending {
        let completion: (Result<Void, TrackerError>) -> Void
        var timeoutToken: SchedulerToken?

        init(completion: @escaping (Result<Void, TrackerError>) -> Void) {
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, completion: @escaping (Result<Void, TrackerError>) -> Void) {
        let entry = Pending(completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failure(.timeout))
        }
        pending[wireMessageId] = entry
    }

    /// Called by `ProfileUpdateHandler` when a `PUB_ACK`/`.mmi` frame
    /// arrives, or internally when the timeout fires. A no-op if
    /// `wireMessageId` isn't (or is no longer) tracked.
    public func resolve(wireMessageId: UInt16, result: Result<Void, TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
```

- [ ] **Step 4: 运行测试确认通过(Tracker)**

Run: `swift test --filter ProfileUpdateTrackerTests`
Expected: PASS

- [ ] **Step 5: 写失败的测试(Handler)**

创建 `Tests/IMContactsTests/ProfileUpdateHandlerTests.swift`:

```swift
import XCTest
import IMClient
import IMTransport
@testable import IMContacts

final class ProfileUpdateHandlerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: ProfileUpdateTracker!
    private var handler: ProfileUpdateHandler!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = ProfileUpdateTracker(scheduler: scheduler)
        handler = ProfileUpdateHandler(tracker: tracker)
    }

    private func makeFrame(errorCode: UInt8) -> Frame {
        Frame(header: Header(signal: .pubAck, subSignal: .mmi, bodyLength: 1, messageId: 9), body: Data([errorCode]))
    }

    func test_canHandle_matchesPubAckMMI_butNothingElse() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .mmi))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .us))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .mmi))
    }

    func test_handle_successBody_resolvesTrackerWithSuccess() {
        var captured: Result<Void, ProfileUpdateTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(errorCode: 0))

        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_handle_nonZeroErrorCode_resolvesTrackerWithServerError() {
        var captured: Result<Void, ProfileUpdateTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(errorCode: 6))

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .mmi, bodyLength: 0, messageId: 9), body: Data()))
    }
}
```

- [ ] **Step 6: 运行测试确认失败**

Run: `swift test --filter ProfileUpdateHandlerTests`
Expected: FAIL — `ProfileUpdateHandler` 不存在,编译错误。

- [ ] **Step 7: 实现 Handler**

创建 `Sources/IMContacts/ProfileUpdateHandler.swift`:

```swift
import IMClient
import IMTransport

/// Parses the bare "1 byte error code, no payload" `PUB_ACK`/`.mmi`
/// response and resolves the matching `ProfileUpdateTracker` entry.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ProfileUpdateHandler: MessageHandler {
    private let tracker: ProfileUpdateTracker

    public init(tracker: ProfileUpdateTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .mmi
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        if errorCode == 0 {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .success(()))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.serverError(errorCode: Int32(errorCode))))
        }
    }
}
```

- [ ] **Step 8: 运行测试确认通过(Handler)**

Run: `swift test --filter ProfileUpdateHandlerTests`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Sources/IMContacts/ProfileUpdateTracker.swift Sources/IMContacts/ProfileUpdateHandler.swift Tests/IMContactsTests/ProfileUpdateTrackerTests.swift Tests/IMContactsTests/ProfileUpdateHandlerTests.swift
git commit -m "feat(IMContacts): add ProfileUpdateTracker/Handler for the .mmi sub-signal"
```

## Task 3: `ContactSyncService.updateDisplayName` / `updatePortrait`

**Files:**
- Modify: `Sources/IMContacts/ContactSyncService.swift`
- Test: `Tests/IMContactsTests/ContactSyncServiceTests.swift`

**Interfaces:**
- Consumes: `ProfileUpdateTracker`/`ProfileUpdateHandler`(Task 2)、`Im_ModifyMyInfoRequest`/`Im_InfoEntry`(`IMProto`,已生成)、`UserStore.upsertProfile(uid:name:displayName:portrait:mobile:gender:updateDt:)`(已有)。
- Produces: `ContactSyncService.updateDisplayName(_:completion:)` / `updatePortrait(_:completion:)`,签名均为 `(String, completion: @escaping (Result<Void, Error>) -> Void)`,成功才本地 `upsertProfile`、保留其余字段不变。

- [ ] **Step 1: 写失败的测试**

在 `Tests/IMContactsTests/ContactSyncServiceTests.swift` 末尾追加(复用现有 `setUpWithError()` 里 `imClient.userId == "me"`):

```swift
    func test_updateDisplayName_sendsInfoEntryTypeZeroWithName() throws {
        service.updateDisplayName("NewName") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .mmi)
        let request = try Im_ModifyMyInfoRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.entry.count, 1)
        XCTAssertEqual(request.entry.first?.type, 0)
        XCTAssertEqual(request.entry.first?.value, "NewName")
    }

    func test_updatePortrait_sendsInfoEntryTypeOneWithURL() throws {
        service.updatePortrait("https://example.com/a.png") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .mmi)
        let request = try Im_ModifyMyInfoRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.entry.first?.type, 1)
        XCTAssertEqual(request.entry.first?.value, "https://example.com/a.png")
    }

    func test_updateDisplayName_onSuccess_mergesIntoUserStoreKeepingOtherFields() throws {
        try storage.users.upsertProfile(uid: "me", name: "real-name", displayName: "Old", portrait: "old-url", mobile: "123", gender: 1, updateDt: 5)

        var capturedResult: Result<Void, Error>?
        service.updateDisplayName("New") { result in capturedResult = result }

        let frame = try decodeOnlySentFrame()
        let ackFrame = FrameEncoder.encode(signal: .pubAck, subSignal: .mmi, messageId: frame.header.messageId, body: Data([0x00]))
        fakeTransport.simulateReceivedData(ackFrame)

        switch capturedResult {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: capturedResult))")
        }
        let updated = try storage.users.user(uid: "me")
        XCTAssertEqual(updated?.displayName, "New")
        XCTAssertEqual(updated?.name, "real-name")
        XCTAssertEqual(updated?.portrait, "old-url")
        XCTAssertEqual(updated?.mobile, "123")
        XCTAssertEqual(updated?.gender, 1)
    }

    func test_updateDisplayName_onFailure_doesNotWriteUserStore() throws {
        try storage.users.upsertProfile(uid: "me", name: nil, displayName: "Old", portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        service.updateDisplayName("New") { _ in }

        let frame = try decodeOnlySentFrame()
        let ackFrame = FrameEncoder.encode(signal: .pubAck, subSignal: .mmi, messageId: frame.header.messageId, body: Data([0x06]))
        fakeTransport.simulateReceivedData(ackFrame)

        XCTAssertEqual(try storage.users.user(uid: "me")?.displayName, "Old")
    }

    func test_updatePortrait_onSuccess_mergesIntoUserStoreKeepingDisplayName() throws {
        try storage.users.upsertProfile(uid: "me", name: nil, displayName: "Old", portrait: "old-url", mobile: nil, gender: 0, updateDt: 0)

        service.updatePortrait("new-url") { _ in }

        let frame = try decodeOnlySentFrame()
        let ackFrame = FrameEncoder.encode(signal: .pubAck, subSignal: .mmi, messageId: frame.header.messageId, body: Data([0x00]))
        fakeTransport.simulateReceivedData(ackFrame)

        let updated = try storage.users.user(uid: "me")
        XCTAssertEqual(updated?.portrait, "new-url")
        XCTAssertEqual(updated?.displayName, "Old")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ContactSyncServiceTests`
Expected: FAIL — `ContactSyncService` 没有 `updateDisplayName`/`updatePortrait`,编译错误。

- [ ] **Step 3: 实现**

在 `Sources/IMContacts/ContactSyncService.swift`,给 `ContactSyncService` 新增一个存储属性(紧跟 `friendRequestActionTracker` 之后):

```swift
    private let profileUpdateTracker: ProfileUpdateTracker
```

在 `init` 里,`friendRequestActionTracker = FriendRequestActionTracker(scheduler: scheduler)` 之后追加:

```swift
        profileUpdateTracker = ProfileUpdateTracker(scheduler: scheduler)
```

在 `imClient.register(FriendRequestActionHandler(tracker: friendRequestActionTracker))` 之后追加:

```swift
        imClient.register(ProfileUpdateHandler(tracker: profileUpdateTracker))
```

在 `markFriendRequestsAsRead()` 方法之后(文件末尾,closing brace 之前)追加:

```swift
    /// Changes the logged-in user's own nickname (`InfoEntry.type=0`,
    /// matching Android `ModifyMyInfoType.Modify_DisplayName`). Only writes
    /// `UserStore` once the server acks success — no optimistic update, so
    /// a failed write never leaves the local cache out of sync with the
    /// server.
    public func updateDisplayName(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        sendModifyMyInfo(type: 0, value: name) { [weak self] result in
            if case .success = result { self?.applyLocalProfileUpdate(displayName: name) }
            completion(result)
        }
    }

    /// Changes the logged-in user's own avatar URL (`InfoEntry.type=1`,
    /// matching Android `ModifyMyInfoType.Modify_Portrait`). The caller is
    /// responsible for uploading the image first (`IMMedia.MediaUploadService`)
    /// and passing the resulting remote URL here — this method only does
    /// the profile-field write, mirroring `updateDisplayName`'s shape.
    public func updatePortrait(_ url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        sendModifyMyInfo(type: 1, value: url) { [weak self] result in
            if case .success = result { self?.applyLocalProfileUpdate(portrait: url) }
            completion(result)
        }
    }

    private func sendModifyMyInfo(type: Int32, value: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var entry = Im_InfoEntry()
        entry.type = type
        entry.value = value
        var request = Im_ModifyMyInfoRequest()
        request.entry = [entry]
        guard let body = try? request.serializedData() else {
            completion(.failure(ContactSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .mmi, body: body)
        profileUpdateTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    /// Merges a successful `.mmi` ack into `UserStore`, keeping every other
    /// profile field at its current local value — a naive `upsertProfile`
    /// call with only the changed field set would clobber the other
    /// columns back to `nil`/default (see `UserStore.upsertProfile`'s doc
    /// comment: it overwrites every profile column it's given).
    private func applyLocalProfileUpdate(displayName: String? = nil, portrait: String? = nil) {
        let uid = imClient.userId
        let existing = try? storage.users.user(uid: uid)
        try? storage.users.upsertProfile(
            uid: uid,
            name: existing?.name,
            displayName: displayName ?? existing?.displayName,
            portrait: portrait ?? existing?.portrait,
            mobile: existing?.mobile,
            gender: existing?.gender ?? 0,
            updateDt: existing?.updateDt ?? 0
        )
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ContactSyncServiceTests`
Expected: PASS

- [ ] **Step 5: 跑一遍 IMContacts 全量测试**

Run: `swift test --filter IMContactsTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMContacts/ContactSyncService.swift Tests/IMContactsTests/ContactSyncServiceTests.swift
git commit -m "feat(IMContacts): add updateDisplayName/updatePortrait to ContactSyncService"
```

## Task 4: `IMKit.QRCodeContent`(二维码内容拼接)

**Files:**
- Create: `Sources/IMKit/QRCodeContent.swift`
- Test: `Tests/IMKitTests/QRCodeContentTests.swift`

纯字符串拼接,不涉及 `CoreImage`/UIKit——图片生成是 App 层的事(Task 8),这里只测试内容这一层逻辑。

**Interfaces:**
- Produces: `QRCodeContent.userQRCodeString(uid: String) -> String`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/IMKitTests/QRCodeContentTests.swift`:

```swift
import XCTest
@testable import IMKit

final class QRCodeContentTests: XCTestCase {
    func test_userQRCodeString_usesWildfirechatUserPrefix() {
        XCTAssertEqual(QRCodeContent.userQRCodeString(uid: "u1"), "wildfirechat://user/u1")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter QRCodeContentTests`
Expected: FAIL — `QRCodeContent` 不存在,编译错误。

- [ ] **Step 3: 实现**

创建 `Sources/IMKit/QRCodeContent.swift`:

```swift
import Foundation

/// Builds the personal-QR-code payload string — matches Android's
/// `WfcScheme.QR_CODE_PREFIX_USER + uid` exactly, so a future scan-to-add-
/// friend feature on either platform can parse either's generated code.
public enum QRCodeContent {
    public static func userQRCodeString(uid: String) -> String {
        "wildfirechat://user/\(uid)"
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter QRCodeContentTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/QRCodeContent.swift Tests/IMKitTests/QRCodeContentTests.swift
git commit -m "feat(IMKit): add QRCodeContent.userQRCodeString"
```

## Task 5: `IMKit.ProfileUpdating` 协议 + `MyProfileViewModel`

**Files:**
- Create: `Sources/IMKit/ProfileUpdating.swift`
- Create: `Sources/IMKit/MyProfileViewModel.swift`
- Test: `Tests/IMKitTests/MyProfileViewModelTests.swift`

`ProfileUpdating.swift` 是纯协议+extension(跟 `ImageUploading.swift`/`ContactInfoFetching.swift` 一样),这个仓库里这类文件没有单独的测试——行为通过 `MyProfileViewModelTests` 间接验证。

**Interfaces:**
- Consumes: `ContactSyncService.updateDisplayName`/`updatePortrait`(Task 3)、`ContactInfoFetching.fetchUserInfo(uids:forceRefresh:)`(已有)、`IMStorage.UserStore.usersPublisher()`(已有)。
- Produces: `ProfileUpdating` 协议;`MyProfileViewModel(myUid:storage:profileUpdating:contactSync:)`,`@Published var displayName: String`/`avatarURL: String?`,`updateDisplayName(_:completion:)`/`updatePortrait(_:completion:)`,均为 `(String, completion: @escaping (Result<Void, Error>) -> Void) -> Void`。

- [ ] **Step 1: 创建协议**

创建 `Sources/IMKit/ProfileUpdating.swift`:

```swift
// Sources/IMKit/ProfileUpdating.swift
import Foundation
import IMContacts

/// Narrow interface `MyProfileViewModel` depends on instead of the
/// concrete `ContactSyncService` — same decoupling-for-testability pattern
/// as `ImageUploading`/`ContactInfoFetching`.
public protocol ProfileUpdating: AnyObject {
    func updateDisplayName(_ name: String, completion: @escaping (Result<Void, Error>) -> Void)
    func updatePortrait(_ url: String, completion: @escaping (Result<Void, Error>) -> Void)
}

extension ContactSyncService: ProfileUpdating {}
```

- [ ] **Step 2: 写失败的测试**

创建 `Tests/IMKitTests/MyProfileViewModelTests.swift`:

```swift
import XCTest
import Combine
import IMStorage
@testable import IMKit

private final class FakeContactInfoFetcher: ContactInfoFetching {
    private(set) var fetchedUids: [String] = []
    private(set) var lastForceRefresh: Bool?

    func fetchUserInfo(uids: [String], forceRefresh: Bool) {
        fetchedUids.append(contentsOf: uids)
        lastForceRefresh = forceRefresh
    }
}

private final class FakeProfileUpdating: ProfileUpdating {
    private(set) var updatedDisplayNames: [String] = []
    private(set) var updatedPortraits: [String] = []
    var nextResult: Result<Void, Error> = .success(())

    func updateDisplayName(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        updatedDisplayNames.append(name)
        completion(nextResult)
    }

    func updatePortrait(_ url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        updatedPortraits.append(url)
        completion(nextResult)
    }
}

final class MyProfileViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fetcher: FakeContactInfoFetcher!
    private var updating: FakeProfileUpdating!
    private var viewModel: MyProfileViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fetcher = FakeContactInfoFetcher()
        updating = FakeProfileUpdating()
    }

    func test_init_publishesDisplayNameAndAvatarFromUserStore() throws {
        try storage.users.upsertProfile(uid: "me", name: "real", displayName: "Alice", portrait: "https://example.com/a.png", mobile: nil, gender: 0, updateDt: 0)

        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        let expectation = expectation(description: "displayName published")
        viewModel.$displayName
            .dropFirst() // initial "" before the publisher's first real emission
            .sink { name in
                if name == "Alice" { expectation.fulfill() }
            }
            .store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(viewModel.avatarURL, "https://example.com/a.png")
    }

    func test_init_fallsBackToNameThenUidWhenNoDisplayName() throws {
        try storage.users.upsertProfile(uid: "me", name: "real-name", displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        let expectation = expectation(description: "displayName falls back to name")
        viewModel.$displayName
            .sink { name in if name == "real-name" { expectation.fulfill() } }
            .store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    func test_init_alwaysCallsFetchUserInfoForMyUid() {
        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        XCTAssertEqual(fetcher.fetchedUids, ["me"])
        XCTAssertEqual(fetcher.lastForceRefresh, false)
    }

    func test_updateDisplayName_forwardsToProfileUpdating() {
        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        var capturedResult: Result<Void, Error>?
        viewModel.updateDisplayName("New") { result in capturedResult = result }

        XCTAssertEqual(updating.updatedDisplayNames, ["New"])
        switch capturedResult {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: capturedResult))")
        }
    }

    func test_updatePortrait_forwardsToProfileUpdating() {
        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        viewModel.updatePortrait("https://example.com/new.png") { _ in }

        XCTAssertEqual(updating.updatedPortraits, ["https://example.com/new.png"])
    }
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `swift test --filter MyProfileViewModelTests`
Expected: FAIL — `MyProfileViewModel` 不存在,编译错误。

- [ ] **Step 4: 实现**

创建 `Sources/IMKit/MyProfileViewModel.swift`:

```swift
// Sources/IMKit/MyProfileViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the「我的」tab's profile card and profile-detail screen: the
/// logged-in user's own `displayName`/`avatarURL`, kept in sync with
/// `IMStorage.UserStore`, plus the two mutations Android's `MeFragment`
/// exposes (change nickname, change avatar).
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class MyProfileViewModel {
    public let myUid: String

    @Published public private(set) var displayName: String = ""
    @Published public private(set) var avatarURL: String?

    private let profileUpdating: ProfileUpdating?
    private var cancellable: AnyCancellable?

    public init(myUid: String, storage: IMStorage, profileUpdating: ProfileUpdating?, contactSync: ContactInfoFetching?) {
        self.myUid = myUid
        self.profileUpdating = profileUpdating

        cancellable = storage.users.usersPublisher()
            .replaceError(with: [])
            .compactMap { users in users.first { $0.uid == myUid } }
            .sink { [weak self] user in
                self?.displayName = user.displayName ?? user.name ?? myUid
                self?.avatarURL = user.portrait
            }

        // Mirrors `ConversationListViewModel`'s "always ask, let
        // `ContactSyncService` decide if a round trip is needed" pattern —
        // the iOS login flow has never fetched the logged-in user's own
        // profile before this feature, so the first call after a fresh
        // login is never a no-op.
        contactSync?.fetchUserInfo(uids: [myUid], forceRefresh: false)
    }

    public func updateDisplayName(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let profileUpdating else { return }
        profileUpdating.updateDisplayName(name, completion: completion)
    }

    public func updatePortrait(_ url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let profileUpdating else { return }
        profileUpdating.updatePortrait(url, completion: completion)
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test --filter MyProfileViewModelTests`
Expected: PASS

- [ ] **Step 6: 跑一遍 IMKit 全量测试**

Run: `swift test --filter IMKitTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/IMKit/ProfileUpdating.swift Sources/IMKit/MyProfileViewModel.swift Tests/IMKitTests/MyProfileViewModelTests.swift
git commit -m "feat(IMKit): add ProfileUpdating protocol and MyProfileViewModel"
```

## Task 6: `AppCore.ThemePreferenceStore`

**Files:**
- Create: `Sources/AppCore/ThemePreferenceStore.swift`
- Test: `Tests/AppCoreTests/ThemePreferenceStoreTests.swift`

纯 `UserDefaults` 读写,不依赖 UIKit(`AppCore` 整个模块都不依赖 UIKit)——`ThemeMode` 到 `UIUserInterfaceStyle` 的映射是 App 层的事(Task 14)。

**Interfaces:**
- Produces: `public enum ThemeMode: Int, CaseIterable { case light = 0, dark = 1, system = 2 }`;`ThemePreferenceStore(defaults:)`,`var mode: ThemeMode { get set }`,未设置过时默认 `.system`。

- [ ] **Step 1: 写失败的测试**

创建 `Tests/AppCoreTests/ThemePreferenceStoreTests.swift`:

```swift
import XCTest
@testable import AppCore

final class ThemePreferenceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: ThemePreferenceStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ThemePreferenceStoreTests-\(UUID().uuidString)")
        store = ThemePreferenceStore(defaults: defaults)
    }

    func test_mode_defaultsToSystemWhenNeverSet() {
        XCTAssertEqual(store.mode, .system)
    }

    func test_mode_persistsAcrossStoreInstances() {
        store.mode = .dark

        let secondStore = ThemePreferenceStore(defaults: defaults)
        XCTAssertEqual(secondStore.mode, .dark)
    }

    func test_mode_roundTripsEveryCase() {
        for mode in ThemeMode.allCases {
            store.mode = mode
            XCTAssertEqual(store.mode, mode)
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ThemePreferenceStoreTests`
Expected: FAIL — `ThemePreferenceStore`/`ThemeMode` 不存在,编译错误。

- [ ] **Step 3: 实现**

创建 `Sources/AppCore/ThemePreferenceStore.swift`:

```swift
import Foundation

/// Manual theme choice (Phase 4 "设置/换肤"). Raw values are the on-disk
/// format — do not renumber existing cases.
public enum ThemeMode: Int, CaseIterable {
    case light = 0
    case dark = 1
    case system = 2
}

/// Persists the user's manual theme choice. `App`'s `SceneDelegate`/
/// `ThemeViewController` are the only readers/writers — `AppCore` itself
/// has no UIKit dependency, so the `ThemeMode` → `UIUserInterfaceStyle`
/// mapping lives in `App`.
///
/// **Threading contract:** safe to call from any queue — `UserDefaults`
/// serializes its own reads/writes internally, same as `DeviceIdentifierProvider`.
public final class ThemePreferenceStore {
    private static let key = "AppCore.themeMode"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var mode: ThemeMode {
        get {
            guard let stored = defaults.object(forKey: Self.key) as? Int else { return .system }
            return ThemeMode(rawValue: stored) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ThemePreferenceStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AppCore/ThemePreferenceStore.swift Tests/AppCoreTests/ThemePreferenceStoreTests.swift
git commit -m "feat(AppCore): add ThemePreferenceStore"
```

## Task 7: `AppEnvironment.logOut()` 扩展(清本地会话数据)

**Files:**
- Modify: `Sources/AppCore/AppEnvironment.swift`
- Test: `Tests/AppCoreTests/AppEnvironmentTests.swift`

**Interfaces:**
- Consumes: `IMStorage.clearSessionData()`(Task 1)。
- Produces: `AppEnvironment.logOut()` 行为扩展——断连/清服务对象/清凭证(已有)之后追加清本地会话数据。

- [ ] **Step 1: 写失败的测试**

在 `Tests/AppCoreTests/AppEnvironmentTests.swift`,`test_logOut_clearsMediaUploadService` 之后追加:

```swift
    func test_logOut_clearsMessagesConversationsAndResetsSyncState() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))
        environment.connectIfPossible()
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send
        ))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)
        try storage.syncState.set(StoredSyncState(msgHead: 42, friendHead: 7, friendRequestHead: 3, settingHead: 9))

        environment.logOut()

        XCTAssertNil(try storage.messages.message(localMessageId: 1))
        XCTAssertTrue(try storage.conversations.conversations().isEmpty)
        XCTAssertEqual(try storage.syncState.get().msgHead, 0)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AppEnvironmentTests/test_logOut_clearsMessagesConversationsAndResetsSyncState`
Expected: FAIL — 断言失败(`message` 行还在,`syncState.msgHead` 仍是 42),因为 `logOut()` 还没调 `clearSessionData()`。

- [ ] **Step 3: 实现**

在 `Sources/AppCore/AppEnvironment.swift`,把 `logOut()` 方法替换成:

```swift
    public func logOut() {
        imClient?.disconnect()
        imClient = nil
        messagingService = nil
        contactSyncService = nil
        groupSyncService = nil
        mediaUploadService = nil
        callManager = nil
        webRTCClient = nil
        credentialsStore.clear()
        // Matches Android's `SqliteDatabaseStore.stop()` scope exactly
        // (see `IMStorage.clearSessionData()`'s doc comment) — `try?`
        // because logout must still proceed (disconnect/clear credentials
        // already happened above) even if this fails, e.g. disk full.
        try? storage.clearSessionData()
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter AppEnvironmentTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AppCore/AppEnvironment.swift Tests/AppCoreTests/AppEnvironmentTests.swift
git commit -m "fix(AppCore): clear local messages/conversations and reset sync cursors on logout"
```

## Task 8: `App.MyQRCodeViewController`

**Files:**
- Create: `App/MyQRCodeViewController.swift`

No XCTest target for `App` — verified by regenerating the Xcode project and building (Step 2 below).

**Interfaces:**
- Consumes: `QRCodeContent.userQRCodeString(uid:)`(Task 4)、`Theme`(已有,`App/Theme.swift`)。
- Produces: `MyQRCodeViewController(uid: String)`。

- [ ] **Step 1: 实现**

创建 `App/MyQRCodeViewController.swift`:

```swift
// App/MyQRCodeViewController.swift
import UIKit
import CoreImage
import IMKit

final class MyQRCodeViewController: UIViewController {
    private let uid: String
    private let qrImageView = UIImageView()
    private let captionLabel = UILabel()

    init(uid: String) {
        self.uid = uid
        super.init(nibName: nil, bundle: nil)
        title = "我的二维码"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        qrImageView.image = Self.makeQRCodeImage(content: QRCodeContent.userQRCodeString(uid: uid))
    }

    private func layoutViews() {
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.text = "扫一扫上面的二维码,加我为好友"
        captionLabel.font = .systemFont(ofSize: 14)
        captionLabel.textColor = Theme.textPrimary
        captionLabel.textAlignment = .center
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(qrImageView)
        view.addSubview(captionLabel)
        NSLayoutConstraint.activate([
            qrImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            qrImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            qrImageView.widthAnchor.constraint(equalToConstant: 240),
            qrImageView.heightAnchor.constraint(equalToConstant: 240),

            captionLabel.topAnchor.constraint(equalTo: qrImageView.bottomAnchor, constant: 16),
            captionLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            captionLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    private static func makeQRCodeImage(content: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
```

- [ ] **Step 2: 重新生成 Xcode 工程并编译**

Run:
```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: `** BUILD SUCCEEDED **`. `App/*.swift` 用的是 `project.pbxproj` 显式文件列表(没有用 file-system-synchronized group),新文件需要重新生成的 pbxproj 一起提交。

- [ ] **Step 3: Commit**

```bash
git add App/MyQRCodeViewController.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): add MyQRCodeViewController"
```

## Task 9: `App.MyProfileViewController`

**Files:**
- Create: `App/MyProfileViewController.swift`

**Interfaces:**
- Consumes: `MyProfileViewModel`(Task 5,`displayName`/`avatarURL`/`myUid`/`updateDisplayName`/`updatePortrait`)、`ImageUploading.uploadImage(_:completion:)`(已有,`IMKit`)、`AvatarImageView`/`AvatarLoader`(已有,`App/AvatarImageView.swift` + `IMKit`)、`MyQRCodeViewController`(Task 8)。
- Produces: `MyProfileViewController(viewModel:imageUploading:)`。

- [ ] **Step 1: 实现**

创建 `App/MyProfileViewController.swift`:

```swift
// App/MyProfileViewController.swift
import UIKit
import Combine
import PhotosUI
import IMKit

final class MyProfileViewController: UIViewController {
    private enum Row: Int, CaseIterable {
        case displayName
        case qrCode
    }

    private let viewModel: MyProfileViewModel
    private let imageUploading: ImageUploading
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerView = UIView()
    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let changeAvatarLabel = UILabel()

    init(viewModel: MyProfileViewModel, imageUploading: ImageUploading) {
        self.viewModel = viewModel
        self.imageUploading = imageUploading
        super.init(nibName: nil, bundle: nil)
        title = "我的资料"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        bindViewModel()
    }

    private func layoutViews() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.isUserInteractionEnabled = true
        avatarImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(changeAvatarTapped)))

        changeAvatarLabel.text = "点击更换头像"
        changeAvatarLabel.font = .systemFont(ofSize: 12)
        changeAvatarLabel.textColor = .secondaryLabel
        changeAvatarLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(avatarImageView)
        headerView.addSubview(changeAvatarLabel)
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 24),
            avatarImageView.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 80),
            avatarImageView.heightAnchor.constraint(equalToConstant: 80),

            changeAvatarLabel.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 8),
            changeAvatarLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            changeAvatarLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -16),
        ])
        headerView.frame = CGRect(x: 0, y: 0, width: 0, height: 140)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.tableHeaderView = headerView
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard tableView.tableHeaderView?.frame.width != tableView.bounds.width else { return }
        headerView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 140)
        tableView.tableHeaderView = headerView
    }

    private func bindViewModel() {
        viewModel.$displayName
            .combineLatest(viewModel.$avatarURL)
            .sink { [weak self] displayName, avatarURL in
                guard let self else { return }
                self.avatarImageView.setAvatar(urlString: avatarURL, displayName: displayName)
                self.tableView.reloadRows(at: [IndexPath(row: Row.displayName.rawValue, section: 0)], with: .none)
            }
            .store(in: &cancellables)
    }

    @objc private func changeAvatarTapped() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func handlePickedAvatar(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        imageUploading.uploadImage(data) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    self?.viewModel.updatePortrait(url) { result in
                        if case .failure = result {
                            self?.presentResultAlert(title: "修改失败", message: "请稍后重试")
                        }
                    }
                case .failure:
                    self?.presentResultAlert(title: "上传失败", message: "请稍后重试")
                }
            }
        }
    }

    private func editDisplayNameTapped() {
        let alert = UIAlertController(title: "修改昵称", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] textField in
            textField.text = self?.viewModel.displayName
            textField.placeholder = "昵称"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self?.viewModel.updateDisplayName(name) { result in
                if case .failure = result {
                    self?.presentResultAlert(title: "修改失败", message: "请稍后重试")
                }
            }
        })
        present(alert, animated: true)
    }

    private func presentResultAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

extension MyProfileViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Row.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .value1, reuseIdentifier: "cell")
        switch Row(rawValue: indexPath.row)! {
        case .displayName:
            cell.textLabel?.text = "昵称"
            cell.detailTextLabel?.text = viewModel.displayName
            cell.accessoryType = .disclosureIndicator
        case .qrCode:
            cell.textLabel?.text = "我的二维码"
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row)! {
        case .displayName:
            editDisplayNameTapped()
        case .qrCode:
            navigationController?.pushViewController(MyQRCodeViewController(uid: viewModel.myUid), animated: true)
        }
    }
}

extension MyProfileViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async { self?.handlePickedAvatar(image) }
        }
    }
}
```

- [ ] **Step 2: 重新生成 Xcode 工程并编译**

Run:
```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/MyProfileViewController.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): add MyProfileViewController"
```

## Task 10: `App.MeViewController`

**Files:**
- Create: `App/MeViewController.swift`

**Interfaces:**
- Consumes: `MyProfileViewModel`(Task 5,`displayName`/`avatarURL`)、`AvatarImageView`/`AvatarLoader`(已有)。
- Produces: `MeViewController(viewModel:)`,`onProfileCardTapped: (() -> Void)?`,`onSettingsTapped: (() -> Void)?`(由 `SceneDelegate` 设置,跟 `ContactListViewController.onContactSelected` 同一套"closure wired from SceneDelegate"约定)。

- [ ] **Step 1: 实现**

创建 `App/MeViewController.swift`:

```swift
// App/MeViewController.swift
import UIKit
import Combine
import IMKit

final class MeViewController: UIViewController {
    private let viewModel: MyProfileViewModel
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerView = UIView()
    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let displayNameLabel = UILabel()

    /// Set by `SceneDelegate` — pushes `MyProfileViewController`.
    var onProfileCardTapped: (() -> Void)?

    /// Set by `SceneDelegate` — pushes `SettingsViewController`.
    var onSettingsTapped: (() -> Void)?

    init(viewModel: MyProfileViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "我的"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        bindViewModel()
    }

    private func layoutViews() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        displayNameLabel.font = .systemFont(ofSize: 17, weight: .medium)
        displayNameLabel.textColor = Theme.textPrimary
        displayNameLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.isUserInteractionEnabled = true
        headerView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(profileCardTapped)))
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(avatarImageView)
        headerView.addSubview(displayNameLabel)
        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            avatarImageView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 56),
            avatarImageView.heightAnchor.constraint(equalToConstant: 56),

            displayNameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            displayNameLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
        ])
        headerView.frame = CGRect(x: 0, y: 0, width: 0, height: 88)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.tableHeaderView = headerView
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard tableView.tableHeaderView?.frame.width != tableView.bounds.width else { return }
        headerView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 88)
        tableView.tableHeaderView = headerView
    }

    private func bindViewModel() {
        viewModel.$displayName
            .combineLatest(viewModel.$avatarURL)
            .sink { [weak self] displayName, avatarURL in
                guard let self else { return }
                self.displayNameLabel.text = displayName
                self.avatarImageView.setAvatar(urlString: avatarURL, displayName: displayName)
            }
            .store(in: &cancellables)
    }

    @objc private func profileCardTapped() {
        onProfileCardTapped?()
    }
}

extension MeViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        cell.textLabel?.text = "设置"
        cell.textLabel?.textColor = Theme.textPrimary
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSettingsTapped?()
    }
}
```

- [ ] **Step 2: 重新生成 Xcode 工程并编译**

Run:
```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/MeViewController.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): add MeViewController"
```

## Task 11: `App.ThemeViewController`

**Files:**
- Create: `App/ThemeViewController.swift`

**Interfaces:**
- Consumes: `AppCore.ThemePreferenceStore`/`ThemeMode`(Task 6)。
- Produces: `ThemeViewController(store:)`,`onModeChanged: ((ThemeMode) -> Void)?`(由 `SceneDelegate` 设置,用来在不依赖这个 VC 持有 `UIWindow` 的前提下立即应用 `overrideUserInterfaceStyle`)。

- [ ] **Step 1: 实现**

创建 `App/ThemeViewController.swift`:

```swift
// App/ThemeViewController.swift
import UIKit
import AppCore

final class ThemeViewController: UIViewController {
    private let store: ThemePreferenceStore
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private static let titles: [ThemeMode: String] = [.light: "浅色", .dark: "深色", .system: "跟随系统"]

    /// Fired immediately after the user picks a new mode, so `SceneDelegate`
    /// can apply `window.overrideUserInterfaceStyle` without this view
    /// controller needing a `UIWindow` reference of its own.
    var onModeChanged: ((ThemeMode) -> Void)?

    init(store: ThemePreferenceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "主题"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension ThemeViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { ThemeMode.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        let mode = ThemeMode.allCases[indexPath.row]
        cell.textLabel?.text = Self.titles[mode]
        cell.textLabel?.textColor = Theme.textPrimary
        cell.accessoryType = (mode == store.mode) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let mode = ThemeMode.allCases[indexPath.row]
        store.mode = mode
        tableView.reloadData()
        onModeChanged?(mode)
    }
}
```

- [ ] **Step 2: 重新生成 Xcode 工程并编译**

Run:
```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/ThemeViewController.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): add ThemeViewController"
```

## Task 12: `App.AboutViewController`

**Files:**
- Create: `App/AboutViewController.swift`

**Interfaces:**
- Consumes: `AppCore.AppConfig`(已有,`imHosts`/`imPort`/`iceServers`)。
- Produces: `AboutViewController(config:)`。

- [ ] **Step 1: 实现**

创建 `App/AboutViewController.swift`:

```swift
// App/AboutViewController.swift
import UIKit
import AppCore

final class AboutViewController: UIViewController {
    private let config: AppConfig
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    // 占位 URL,待替换为真实的功能介绍/用户协议/隐私政策页面地址 —— 同
    // `GroupInfoViewController.placeholderGroupAvatarURL` 一样用
    // example.com(RFC 2606 预留域名,不会真正解析)。
    private static let featureIntroURL = URL(string: "https://example.com/feature-intro")!
    private static let userAgreementURL = URL(string: "https://example.com/user-agreement")!
    private static let privacyPolicyURL = URL(string: "https://example.com/privacy-policy")!

    init(config: AppConfig) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
        title = "关于"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
    }

    private func layoutViews() {
        stack.axis = .vertical
        stack.spacing = Theme.standardSpacing
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "飞享"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"

        addLabel("\(appName) \(version) (\(build))", bold: true)
        addLabel("IM 服务器: \(config.imHosts):\(config.imPort)")
        for iceServer in config.iceServers {
            addLabel("ICE/STUN: \(iceServer.urlString)")
        }
        addLinkButton(title: "功能介绍", url: Self.featureIntroURL)
        addLinkButton(title: "用户协议", url: Self.userAgreementURL)
        addLinkButton(title: "隐私政策", url: Self.privacyPolicyURL)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -48),
        ])
    }

    private func addLabel(_ text: String, bold: Bool = false) {
        let label = UILabel()
        label.text = text
        label.font = bold ? .systemFont(ofSize: 18, weight: .semibold) : .systemFont(ofSize: 14)
        label.textColor = Theme.textPrimary
        label.numberOfLines = 0
        stack.addArrangedSubview(label)
    }

    private func addLinkButton(title: String, url: URL) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addAction(UIAction { [weak self] _ in self?.open(url) }, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }

    private func open(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
```

- [ ] **Step 2: 重新生成 Xcode 工程并编译**

Run:
```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/AboutViewController.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): add AboutViewController"
```

## Task 13: `App.SettingsViewController`

**Files:**
- Create: `App/SettingsViewController.swift`

**Interfaces:**
- Produces: `SettingsViewController()`,`onThemeTapped: (() -> Void)?`,`onAboutTapped: (() -> Void)?`,`onLogoutConfirmed: (() -> Void)?`(全部由 `SceneDelegate` 设置;`onLogoutConfirmed` 在用户点了确认 alert 的"退出"之后才触发,`SceneDelegate` 收到后才真正调 `AppEnvironment.logOut()`)。

- [ ] **Step 1: 实现**

创建 `App/SettingsViewController.swift`:

```swift
// App/SettingsViewController.swift
import UIKit

final class SettingsViewController: UIViewController {
    private enum Row: Int, CaseIterable {
        case theme
        case about
        case logout
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// Set by `SceneDelegate` — pushes `ThemeViewController`.
    var onThemeTapped: (() -> Void)?

    /// Set by `SceneDelegate` — pushes `AboutViewController`.
    var onAboutTapped: (() -> Void)?

    /// Set by `SceneDelegate` — fired only after the user confirms the
    /// "退出登录" alert below, never on the bare tap.
    var onLogoutConfirmed: (() -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "设置"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func logoutTapped() {
        let alert = UIAlertController(title: "退出登录", message: "确定要退出登录吗?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "退出", style: .destructive) { [weak self] _ in
            self?.onLogoutConfirmed?()
        })
        present(alert, animated: true)
    }
}

extension SettingsViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Row.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        switch Row(rawValue: indexPath.row)! {
        case .theme:
            cell.textLabel?.text = "主题"
            cell.textLabel?.textColor = Theme.textPrimary
            cell.accessoryType = .disclosureIndicator
        case .about:
            cell.textLabel?.text = "关于"
            cell.textLabel?.textColor = Theme.textPrimary
            cell.accessoryType = .disclosureIndicator
        case .logout:
            cell.textLabel?.text = "退出登录"
            cell.textLabel?.textColor = .systemRed
            cell.accessoryType = .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row)! {
        case .theme: onThemeTapped?()
        case .about: onAboutTapped?()
        case .logout: logoutTapped()
        }
    }
}
```

- [ ] **Step 2: 重新生成 Xcode 工程并编译**

Run:
```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/SettingsViewController.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): add SettingsViewController"
```

## Task 14: 接入 `SceneDelegate`(第三个 tab、主题应用、退出登录换根)

**Files:**
- Create: `App/ThemeMode+UIKit.swift`
- Modify: `App/SceneDelegate.swift`

**Interfaces:**
- Consumes: 本计划 Task 5/6/9/10/11/12/13 的全部产出。

- [ ] **Step 1: `ThemeMode` → `UIUserInterfaceStyle` 映射**

创建 `App/ThemeMode+UIKit.swift`:

```swift
// App/ThemeMode+UIKit.swift
import UIKit
import AppCore

extension ThemeMode {
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return .unspecified
        }
    }
}
```

- [ ] **Step 2: 接入第三个 tab + 主题应用 + 退出登录换根**

在 `App/SceneDelegate.swift`,给 `SceneDelegate` 新增一个存储属性(紧跟 `private var presentedCallViewController: CallViewController?` 之后):

```swift
    private let themePreferenceStore = ThemePreferenceStore()
```

`import AppCore` 已经在文件顶部存在,不需要新增 import。

在 `scene(_:willConnectTo:options:)` 里,`window.rootViewController = rootViewController()` 之后追加:

```swift
        window.overrideUserInterfaceStyle = themePreferenceStore.mode.userInterfaceStyle
```

把 `makeMainTabBarController()` 方法替换成:

```swift
    /// Three tabs: conversations (default landing tab), contacts, and
    /// "我的" (Phase 4). All three are independent `UINavigationController`s.
    private func makeMainTabBarController() -> UIViewController {
        let tabBarController = UITabBarController()

        let conversationListNav = makeConversationListNavigationController()
        conversationListNav.tabBarItem = UITabBarItem(title: "消息", image: UIImage(systemName: "message"), tag: 0)

        let contactListViewModel = ContactListViewModel(storage: environment.storage, contactSync: environment.contactSyncService)
        let contactListNav = makeContactListNavigationController(viewModel: contactListViewModel)
        contactListNav.tabBarItem = UITabBarItem(title: "联系人", image: UIImage(systemName: "person.2"), tag: 1)
        contactListViewModel.$unreadFriendRequestCount
            .sink { [weak contactListNav] count in
                contactListNav?.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil
            }
            .store(in: &cancellables)

        let myProfileViewModel = MyProfileViewModel(
            myUid: environment.imClient?.userId ?? "",
            storage: environment.storage,
            profileUpdating: environment.contactSyncService,
            contactSync: environment.contactSyncService
        )
        let meNav = makeMeNavigationController(viewModel: myProfileViewModel)
        meNav.tabBarItem = UITabBarItem(title: "我的", image: UIImage(systemName: "person.crop.circle"), tag: 2)

        tabBarController.viewControllers = [conversationListNav, contactListNav, meNav]
        return tabBarController
    }

    /// Builds the「我的」tab's nav stack and wires its 2 push destinations
    /// (`MyProfileViewController` from the profile card, `SettingsViewController`
    /// from the settings row) plus `SettingsViewController`'s own 3
    /// destinations — same "closure wired from SceneDelegate" pattern as
    /// `makeContactListNavigationController`/`wireGroupInfoNavigation`.
    private func makeMeNavigationController(viewModel: MyProfileViewModel) -> UINavigationController {
        let meViewController = MeViewController(viewModel: viewModel)
        meViewController.onProfileCardTapped = { [weak self, weak meViewController] in
            guard let self, let imageUploading = self.environment.mediaUploadService else { return }
            let profileViewController = MyProfileViewController(viewModel: viewModel, imageUploading: imageUploading)
            meViewController?.navigationController?.pushViewController(profileViewController, animated: true)
        }
        meViewController.onSettingsTapped = { [weak self, weak meViewController] in
            guard let self else { return }
            let settingsViewController = SettingsViewController()
            settingsViewController.onThemeTapped = { [weak self, weak settingsViewController] in
                guard let self else { return }
                let themeViewController = ThemeViewController(store: self.themePreferenceStore)
                themeViewController.onModeChanged = { [weak self] mode in
                    self?.window?.overrideUserInterfaceStyle = mode.userInterfaceStyle
                }
                settingsViewController?.navigationController?.pushViewController(themeViewController, animated: true)
            }
            settingsViewController.onAboutTapped = { [weak self, weak settingsViewController] in
                guard let self else { return }
                settingsViewController?.navigationController?.pushViewController(AboutViewController(config: self.environment.config), animated: true)
            }
            settingsViewController.onLogoutConfirmed = { [weak self] in
                self?.performLogout()
            }
            meViewController?.navigationController?.pushViewController(settingsViewController, animated: true)
        }
        return UINavigationController(rootViewController: meViewController)
    }

    /// Tears down the current session and switches back to the login
    /// screen — the reverse of `makeLoginViewController`'s
    /// `onLoginSucceeded`. Drops every `cancellables` subscription (the
    /// contact-list unread badge, the call-state sink) and
    /// `callKitProvider` before switching root: those were bound to view
    /// models / a `CallManager` that `environment.logOut()` is about to
    /// tear down, and `wireCallManagerIfReady()`'s `callKitProvider == nil`
    /// guard must see a clean slate so it actually rebuilds a fresh
    /// `CXProvider` against the next login's new `CallManager`.
    private func performLogout() {
        cancellables.removeAll()
        callKitProvider = nil
        environment.logOut()
        window?.rootViewController = makeLoginViewController()
    }
```

- [ ] **Step 3: 重新生成 Xcode 工程并编译**

Run:
```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 跑一遍全量 SPM 测试,确认这一路改动没改坏既有行为**

Run: `swift test`
Expected: PASS(全部模块,包括 Task 1-7 新增的测试)

- [ ] **Step 5: Commit**

```bash
git add App/ThemeMode+UIKit.swift App/SceneDelegate.swift ios-chat-pro.xcodeproj
git commit -m "feat(App): wire up the 我的 tab, theme application, and logout root switch"
```

## Task 15: 手动验证(模拟器跑一遍真实路径)

**Files:** 无代码改动,纯验证。

- [ ] **Step 1: 启动模拟器跑 App**

Run:
```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```
然后用 `/run` skill(或 `xcrun simctl install`/`launch`)把编译产物装到模拟器并启动。

- [ ] **Step 2: 验证清单**

逐项手动验证,确认行为符合设计文档(`docs/superpowers/specs/2026-06-25-phase4-me-tab-design.md`):

1. 登录后底部出现第三个 tab「我的」,点击进入资料卡(显示头像占位+昵称,昵称首次为空或 uid 占位是预期的——本地从未存过自己资料,等 `fetchUserInfo` 网络往返resolve)。
2. 点资料卡进入「我的资料」,点头像能弹出系统相册选择器(权限/取消流程不崩溃即可,服务端不可达时上传/改资料失败有提示但不崩溃)。
3. 点「昵称」弹出输入框,保存后(若服务端可达)资料卡和详情页昵称同步刷新。
4. 点「我的二维码」能看到一张可读的二维码图(可用相机/二维码识别 App 扫一下确认内容是 `wildfirechat://user/{uid}`)。
5. 「设置」→「主题」三选一,选中后**立即**(不重启)切换深色/浅色外观,跟随系统选项跟着系统设置走。
6. 「设置」→「关于」显示 App 名称/版本号、IM 服务器地址、ICE/STUN 地址、三个链接按钮(点开应该跳系统 Safari 到占位 `example.com` 页面)。
7. 「设置」→「退出登录」弹确认 alert,确认后回到登录页;重新登录后会话列表/消息历史是空的(`clearSessionData()` 生效),好友列表/群组列表通过正常同步流程重新出现(不是从本地残留数据来的)。

- [ ] **Step 3: 记录结果**

如果有任何一步行为不对,回到对应 Task 修复并重跑该 Task 的测试,而不是在这里临时打补丁。

---

## Self-Review Notes

- **Spec 覆盖检查:** 设计文档 §2(模块归属)→ Task 1-7;§3(界面清单)→ Task 8-14;§4(数据流细节,改昵称/头像/二维码/主题/关于)→ Task 3/5/6/8/9/11/12;§5(退出登录清数据)→ Task 1/7/14;§6(测试策略)→ 每个 Task 的 Step 1-4 已覆盖对应的单测,App 层手动验证收在 Task 15。没有遗漏的 spec 小节。
- **占位符检查:** 关于页 3 个链接 URL 是设计文档里用户明确认可的占位(`example.com`),已在代码注释里标注"待替换",不是遗留 TODO。
- **类型一致性检查:** `ProfileUpdating`(Task 5)/`ContactSyncService.updateDisplayName`/`updatePortrait`(Task 3)签名一致,均为 `(String, completion: @escaping (Result<Void, Error>) -> Void) -> Void`;`MyProfileViewModel.myUid`/`displayName`/`avatarURL` 在 Task 9/10/14 里引用名称一致;`ThemeMode`(Task 6)在 Task 11/14 里的 `userInterfaceStyle` 映射、`ThemePreferenceStore.mode` 读写一致。

