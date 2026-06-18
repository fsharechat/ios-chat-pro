# Phase 1 / Plan G: Conversation List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the conversation list screen — the real "logged in" home screen, replacing Plan E's `HomeViewController` placeholder — showing all conversations sorted by pinned/recency, with avatar, display name, last-message preview, timestamp, unread badge, and draft indicator, live-updating from `IMStorage` via Combine.

**Architecture:** A new `IMKit` SwiftPM target (depending on `IMStorage`/`IMContacts`) holds the testable pieces: `ConversationListViewModel` (builds display rows from `ConversationStore`/`MessageStore`/`UserStore`, triggers profile resolution for unresolved contacts) and `AvatarLoader` (fetches+caches avatar image *data* — deliberately not `UIImage`, since this target also targets macOS for `swift test` and `UIKit` isn't available there). The actual `UIKit` screen (`ConversationListViewController`, `ConversationListCell`, `AvatarImageView`) lives in the `App` Xcode target, consistent with Plan E's established split (testable logic in an SPM package, thin UIKit glue verified by build success). `SceneDelegate` wraps the conversation list in a `UINavigationController` so tapping a row can push — to a placeholder chat screen for now, since Plan H builds the real one.

**Tech Stack:** Builds entirely on existing Plan A–F targets — no new external dependencies. Avatar loading uses plain `URLSession`, no image library.

---

**Reference facts this plan is built from** (verified by reading the actual Android client and the current `IMStorage`/`AppCore` source — not assumed):

- **Row content and sort order** (`ConversationListAdapter`/`ConversationViewHolder`, already researched): avatar, display name, right-aligned timestamp, single-line last-message preview, unread badge (capped at 99 — deferred, Phase 1 just shows the raw count), draft indicator replacing the preview when present, mute icon. Sort: **pinned (`isTop`) conversations first, then by timestamp descending** within each group — `IMStorage.ConversationStore`'s existing `conversations()`/`conversationsPublisher()` only sort by timestamp today (verified by reading `Sources/IMStorage/ConversationStore.swift`); this plan's Task 2 extends that sort, additively, with no contradicting existing test (the existing `test_conversations_ordersByTimestampDescending` test never sets `isTop`, so both rows default to `false` and the added primary sort key is a no-op for that test).
- **Last-message preview text already exists, no formatting needed**: `StoredMessage.searchableContent` (Plan C) is *already* exactly the right preview string for both content types — the literal text for `.text`, and the digest `"[图片]"` for `.image` (set unconditionally in `StoredMessage.init`, verified by reading `Sources/IMStorage/StoredMessage.swift`). No new "digest" formatter needs writing.
- **A real correctness trap, caught during planning**: `StoredConversation.lastMessageUid` is `0` for a message that's been sent but not yet acked (`MessagingService.send()`, Plan D, calls `recordIncomingMessage(..., messageUid: 0, ...)` for the local echo *before* the ack arrives) — and `MessageStore.message(uid:)` has a `guard uid != 0 else { return nil }` short-circuit (Plan D), because `messageUid == 0` is ambiguous across every pending sent message. Looking up the conversation's last message via `lastMessageUid` + `message(uid:)` would therefore show **no preview at all** for a just-sent, not-yet-acked message. This plan's `ConversationListViewModel` instead looks up the most recent message via the existing `MessageStore.messages(conversationType:target:line:limit:)` (already built in Plan D, ordered by timestamp descending) with `limit: 1` — which finds the row by its actual storage timestamp, not by a uid that might still be the `0` sentinel.
- **No group-chat preview-prefixing needed**: Android's `senderName + ":" + digest()` prefix only applies to group conversations. Phase 1 is single-chat only (`ConversationType.single` — `.group`/`.chatRoom`/`.channel` exist in the enum for forward-compatibility but are out of scope, per the migration design doc's roadmap), so this plan never needs that prefix logic.
- **Avatar/profile resolution ties into Plan F**: a conversation's `target` is a uid; resolving it to a display name/avatar URL goes through `IMStorage.UserStore` (Plan F). If a target's profile hasn't been resolved yet (`displayName == nil` — including the literal placeholder-row case `UserStore.replaceFriendList` creates, the same condition `ContactSyncService.fetchUserInfo`'s cache check already treats as "needs fetching", fixed in Plan F's final review), this plan's view model opportunistically calls `fetchUserInfo(uids:forceRefresh: false)` for those targets so the name fills in once resolved — exactly the composition Plan F's own final review anticipated for "a future contacts-list screen."
- **`ContactSyncService` (Plan F) has no protocol abstraction yet** — it's a concrete class requiring a real `IMClient` to construct, which would make `ConversationListViewModel`'s tests need a full fake-transport `IMClient` setup just to verify a `fetchUserInfo` call happened. This plan adds a minimal `ContactInfoFetching` protocol (one method, matching `fetchUserInfo`'s exact signature) and retroactively conforms `ContactSyncService` to it — the same pattern already used for `LoginAPIClientProtocol` in Plan E, for the same reason.
- **`AppEnvironment.storage`/`.contactSyncService` are already public** (Plan E/F) — `contactSyncService` is non-nil by the time `SceneDelegate.rootViewController()` would construct a conversation list (only reachable after `connectIfPossible()` returns `true`).
- **No `UINavigationController` exists yet**: `SceneDelegate` (Plan E) sets `window.rootViewController` directly to either `LoginViewController` or the placeholder `HomeViewController`, with no navigation stack. This plan introduces one (wrapping only the logged-in branch — `LoginViewController` doesn't need to push anywhere in Phase 1).
- **Explicitly deferred, matching Android features this plan does not port**: swipe-to-delete/mute/pin, long-press context menu, pull-to-refresh, a "disconnected" banner row, unread-count capping display (e.g. "99+"). All noted in this plan's self-review, not silently dropped.

---

## Task 1: Scaffold the `IMKit` SwiftPM target

**Files:**
- Modify: `Package.swift`
- Modify: `project.yml` (App target needs to import `IMKit` directly, alongside `AppCore`)
- Create: `Sources/IMKit/_Scaffold.swift`
- Create: `Tests/IMKitTests/_Scaffold.swift`

- [ ] **Step 1: Edit `Package.swift`**

Add to `products` (after `IMContacts`):

```swift
        .library(name: "IMKit", targets: ["IMKit"]),
```

Add to `targets` (after `IMContacts`'s entries):

```swift
        .target(name: "IMKit", dependencies: ["IMStorage", "IMContacts"]),
        .testTarget(name: "IMKitTests", dependencies: ["IMKit"]),
```

- [ ] **Step 2: Create placeholder source**

```bash
mkdir -p Sources/IMKit Tests/IMKitTests
echo "// IMKit placeholder, removed in Task 3" > Sources/IMKit/_Scaffold.swift
echo "// IMKitTests placeholder, removed in Task 3" > Tests/IMKitTests/_Scaffold.swift
```

- [ ] **Step 3: Add `IMKit` to the App target's dependencies in `project.yml`**

In `project.yml`, under `targets: App: dependencies:`, add (after the `AppCore` entry):

```yaml
      - package: IMCore
        product: IMKit
```

- [ ] **Step 4: Build and test**

```bash
swift build
swift test
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `swift build` → `Build complete!`; `swift test` → all previously-existing tests still pass; `xcodebuild` → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift project.yml ios-chat-pro.xcodeproj Sources/IMKit Tests/IMKitTests
git commit -m "chore: scaffold IMKit SwiftPM target"
```

---

## Task 2: `ConversationStore` pinned-first sort order

**Files:**
- Modify: `Sources/IMStorage/ConversationStore.swift`
- Modify: `Tests/IMStorageTests/ConversationStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Read `Tests/IMStorageTests/ConversationStoreTests.swift`'s current content first (it already exists from Plan C). Append this test inside the existing class:

```swift
    func test_conversations_sortsPinnedConversationsFirstRegardlessOfTimestamp() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "newer", line: 0, messageUid: 1, timestamp: 2_000, incrementUnread: false)
        try store.recordIncomingMessage(conversationType: .single, target: "olderButPinned", line: 0, messageUid: 2, timestamp: 1_000, incrementUnread: false)
        try store.setTop(true, conversationType: .single, target: "olderButPinned", line: 0)

        let conversations = try store.conversations()

        XCTAssertEqual(conversations.map { $0.target }, ["olderButPinned", "newer"])
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ConversationStoreTests`
Expected: FAIL with `error: value of type 'ConversationStore' has no member 'setTop'`

- [ ] **Step 3: Implement**

In `Sources/IMStorage/ConversationStore.swift`:

1. Change the `order` clause in BOTH `conversations()` and `conversationsPublisher()` from:

```swift
        try StoredConversation.order(Column("timestamp").desc).fetchAll(db)
```

to:

```swift
        try StoredConversation.order(Column("isTop").desc, Column("timestamp").desc).fetchAll(db)
```

2. Add a new method (e.g. after `clearUnread`):

```swift
    public func setTop(_ isTop: Bool, conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET isTop = ? WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [isTop, conversationType.rawValue, target, line]
            )
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConversationStoreTests`
Expected: all `ConversationStoreTests` pass, including the new one and the pre-existing `test_conversations_ordersByTimestampDescending` (unaffected, since neither of its two rows sets `isTop`).

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/IMStorage/ConversationStore.swift Tests/IMStorageTests/ConversationStoreTests.swift
git commit -m "feat(IMStorage): sort pinned conversations first in ConversationStore"
```

---

## Task 3: `AvatarLoader`

Fetches and caches avatar image *data* (not `UIImage` — this target also builds for `swift test` on macOS, where `UIKit`/`UIImage` don't exist; decoding to `UIImage` happens in the `App` target, Task 5).

**Files:**
- Create: `Sources/IMKit/AvatarLoader.swift`
- Create: `Tests/IMKitTests/Support/MockURLProtocol.swift` (same as the one already built in `AppCoreTests`, Plan E — `internal` types don't cross SwiftPM test targets, so each target keeps its own copy)
- Test: `Tests/IMKitTests/AvatarLoaderTests.swift`
- Modify: delete `Sources/IMKit/_Scaffold.swift`, delete `Tests/IMKitTests/_Scaffold.swift`

- [ ] **Step 1: Add the mock URLProtocol test support**

```swift
// Tests/IMKitTests/Support/MockURLProtocol.swift
import Foundation

/// Intercepts every request made through a `URLSession` configured with
/// this protocol class, so tests never touch the real network. Same
/// implementation as `AppCoreTests`' copy (Plan E) — kept separate per
/// SwiftPM test target visibility rules.
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
// Tests/IMKitTests/AvatarLoaderTests.swift
import XCTest
@testable import IMKit

final class AvatarLoaderTests: XCTestCase {
    private var loader: AvatarLoader!
    private var requestCount: Int!

    override func setUp() {
        super.setUp()
        requestCount = 0
        loader = AvatarLoader(session: MockURLProtocol.makeSession())
    }

    private func respond(statusCode: Int, data: Data) {
        MockURLProtocol.requestHandler = { [weak self] request in
            self?.requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    func test_loadAvatarData_onSuccess_returnsTheBody() async {
        respond(statusCode: 200, data: Data([0x01, 0x02, 0x03]))

        let data = await loader.loadAvatarData(from: "https://example.com/a.png")

        XCTAssertEqual(data, Data([0x01, 0x02, 0x03]))
    }

    func test_loadAvatarData_onNon200Status_returnsNil() async {
        respond(statusCode: 404, data: Data())

        let data = await loader.loadAvatarData(from: "https://example.com/missing.png")

        XCTAssertNil(data)
    }

    func test_loadAvatarData_withInvalidURLString_returnsNilWithoutNetworkCall() async {
        let data = await loader.loadAvatarData(from: "")

        XCTAssertNil(data)
        XCTAssertEqual(requestCount, 0)
    }

    func test_loadAvatarData_calledTwiceForSameURL_onlyHitsTheNetworkOnce() async {
        respond(statusCode: 200, data: Data([0x01]))

        _ = await loader.loadAvatarData(from: "https://example.com/a.png")
        _ = await loader.loadAvatarData(from: "https://example.com/a.png")

        XCTAssertEqual(requestCount, 1)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter AvatarLoaderTests`
Expected: FAIL with `error: cannot find type 'AvatarLoader' in scope`

- [ ] **Step 4: Implement**

```swift
// Sources/IMKit/AvatarLoader.swift
import Foundation

/// Fetches and in-memory-caches avatar image bytes from a URL string.
/// Returns raw `Data`, not `UIImage` — `UIKit` isn't available when this
/// target builds for `swift test` on macOS; the `App` target (Task 5)
/// decodes the bytes into an image.
public protocol AvatarLoading {
    func loadAvatarData(from urlString: String) async -> Data?
}

public final class AvatarLoader: AvatarLoading {
    private let session: URLSession
    private let cache = NSCache<NSString, NSData>()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func loadAvatarData(from urlString: String) async -> Data? {
        if let cached = cache.object(forKey: urlString as NSString) {
            return cached as Data
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

        cache.setObject(result.0 as NSData, forKey: urlString as NSString)
        return result.0
    }
}
```

- [ ] **Step 5: Remove Task 1 scaffolding**

```bash
rm -f Sources/IMKit/_Scaffold.swift Tests/IMKitTests/_Scaffold.swift
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter AvatarLoaderTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
git add Sources/IMKit/AvatarLoader.swift Tests/IMKitTests/Support/MockURLProtocol.swift Tests/IMKitTests/AvatarLoaderTests.swift
git add -u Sources/IMKit Tests/IMKitTests
git commit -m "feat(IMKit): add AvatarLoader"
```

---

## Task 4: `ConversationListViewModel`

The bulk of this plan's logic: builds display-ready rows from `IMStorage`, live-updating via Combine. See this plan's "Reference facts" for the `lastMessageUid == 0` trap and the unresolved-profile-fetch composition with Plan F.

**Files:**
- Modify: `Sources/IMStorage/MessageEnums.swift` (add `Hashable` to `ConversationType`/`MessageStatus` — see Step 0)
- Create: `Sources/IMKit/ConversationRow.swift`
- Create: `Sources/IMKit/ConversationListViewModel.swift`
- Create: `Sources/IMKit/ContactInfoFetching.swift`
- Test: `Tests/IMKitTests/ConversationListViewModelTests.swift`

- [ ] **Step 1: Add `Hashable` to `ConversationType` and `MessageStatus`**

`ConversationRow` (Step 3 below) needs to be `Hashable` for `UITableViewDiffableDataSource` (Task 7) — Swift's auto-synthesized `Hashable` requires *every* stored property to be `Hashable` too, and `ConversationType`/`MessageStatus` (`Sources/IMStorage/MessageEnums.swift`, Plan C) currently only declare `Equatable`. Swift does not retroactively synthesize `Hashable` from a different file/module, so this must be fixed at the declaration site. This is a trivially safe, additive change (a `RawRepresentable` enum with no associated values gets `Hashable` for free the moment it's declared) — it doesn't change either enum's behavior or break any existing call site.

In `Sources/IMStorage/MessageEnums.swift`, change:

```swift
public enum ConversationType: Int, Codable, Equatable {
```

to:

```swift
public enum ConversationType: Int, Codable, Equatable, Hashable {
```

and:

```swift
public enum MessageStatus: Int, Codable, Equatable {
```

to:

```swift
public enum MessageStatus: Int, Codable, Equatable, Hashable {
```

Run `swift test` once after this isolated change to confirm zero regressions before continuing (expected: all 194 pre-existing tests still pass — this change can't break anything that compiled before, since `Hashable` only adds capability).

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/IMKitTests/ConversationListViewModelTests.swift
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

final class ConversationListViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fetcher: FakeContactInfoFetcher!
    private var viewModel: ConversationListViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fetcher = FakeContactInfoFetcher()
        viewModel = ConversationListViewModel(storage: storage, contactSync: fetcher)
    }

    func test_initialState_emptyRows() {
        XCTAssertEqual(viewModel.rows, [])
    }

    func test_newConversation_appearsAsARow_withDisplayNameAndPreviewFromLastMessage() throws {
        try storage.users.upsertProfile(uid: "them", name: nil, displayName: "Alice", portrait: "https://example.com/a.png", mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hello"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)

        let expectation = expectation(description: "row appears")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(row.target, "them")
        XCTAssertEqual(row.displayName, "Alice")
        XCTAssertEqual(row.avatarURL, "https://example.com/a.png")
        XCTAssertEqual(row.previewText, "hello")
        XCTAssertEqual(row.unreadCount, 1)
    }

    func test_pendingSentMessage_stillShowsAPreview_despiteMessageUidZero() throws {
        // Reference facts: lastMessageUid is 0 for a not-yet-acked send —
        // message(uid:) would find nothing for uid 0. The view model must
        // look up the latest message by timestamp instead.
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 0, conversationType: .single, target: "them", from: "me", content: .text("not yet acked"), timestamp: 1_000, status: .sending, direction: .send))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 0, timestamp: 1_000, incrementUnread: false)

        let expectation = expectation(description: "row appears")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.first?.previewText, "not yet acked")
        XCTAssertEqual(viewModel.rows.first?.lastMessageStatus, .sending)
    }

    func test_draftPresent_showsDraftInsteadOfLastMessage() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hello"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)
        try storage.conversations.setDraft("unsent reply", conversationType: .single, target: "them", line: 0)

        // Two writes happened before this subscribes — counting emissions
        // with dropFirst(N) would be racy, since GRDB's ValueObservation
        // may coalesce rapid consecutive writes into fewer notifications
        // than writes. Wait for the expected *content* to appear instead.
        let expectation = expectation(description: "draft preview appears")
        viewModel.$rows.sink { rows in
            if rows.first?.previewText == "[草稿] unsent reply" { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.first?.previewText, "[草稿] unsent reply")
    }

    func test_unresolvedProfile_triggersAFetchUserInfoCall() throws {
        // No upsertProfile call at all for "them" — displayName is nil.
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)

        let expectation = expectation(description: "fetch triggered")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertTrue(fetcher.fetchedUids.contains("them"))
        XCTAssertEqual(fetcher.lastForceRefresh, false)
        XCTAssertEqual(viewModel.rows.first?.displayName, "them") // falls back to the uid until resolved
    }

    func test_resolvedProfileWithNoDisplayName_fallsBackToName() throws {
        try storage.users.upsertProfile(uid: "them", name: "rawname", displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 1)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 100, conversationType: .single, target: "them", from: "them", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "them", line: 0, messageUid: 100, timestamp: 1_000, incrementUnread: true)

        let expectation = expectation(description: "row appears")
        viewModel.$rows.dropFirst().sink { rows in
            if !rows.isEmpty { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.rows.first?.displayName, "rawname")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ConversationListViewModelTests`
Expected: FAIL with `error: cannot find type 'ConversationListViewModel' in scope`

- [ ] **Step 4: Implement**

```swift
// Sources/IMKit/ContactInfoFetching.swift
import IMContacts

/// Lets `ConversationListViewModel` depend on an abstraction instead of the
/// concrete `IMClient`-backed `ContactSyncService`, so its tests use a
/// plain fake instead of standing up a real `IMClient`. Same pattern as
/// `LoginAPIClientProtocol` (Plan E), for the same reason.
public protocol ContactInfoFetching {
    func fetchUserInfo(uids: [String], forceRefresh: Bool)
}

extension ContactSyncService: ContactInfoFetching {}
```

```swift
// Sources/IMKit/ConversationRow.swift
import IMStorage

public struct ConversationRow: Equatable, Hashable {
    public let conversationType: ConversationType
    public let target: String
    public let line: Int
    public let displayName: String
    public let avatarURL: String?
    public let previewText: String
    public let timestamp: Int64
    public let unreadCount: Int
    public let isTop: Bool
    public let isMuted: Bool
    public let lastMessageStatus: MessageStatus?
}
```

```swift
// Sources/IMKit/ConversationListViewModel.swift
import Foundation
import Combine
import IMStorage

/// Builds display-ready `ConversationRow`s from `IMStorage`, live-updating
/// via `ConversationStore.conversationsPublisher()`. See this plan's
/// "Reference facts" for why the last-message lookup goes through
/// `MessageStore.messages(...)` rather than `lastMessageUid`, and why an
/// unresolved contact triggers a `fetchUserInfo` call.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ConversationListViewModel {
    @Published public private(set) var rows: [ConversationRow] = []

    private let storage: IMStorage
    private let contactSync: ContactInfoFetching?
    private var cancellable: AnyCancellable?

    public init(storage: IMStorage, contactSync: ContactInfoFetching?) {
        self.storage = storage
        self.contactSync = contactSync

        cancellable = storage.conversations.conversationsPublisher()
            .replaceError(with: [])
            .sink { [weak self] conversations in self?.handleConversationsUpdate(conversations) }
    }

    private func handleConversationsUpdate(_ conversations: [StoredConversation]) {
        var unresolvedUids: [String] = []

        rows = conversations.map { conversation in
            // Accepted Phase-1 gap: a lookup failure here silently falls
            // back to "no last message"/"no profile" rather than
            // surfacing an error (no logging facility yet), same as
            // similarly-documented gaps elsewhere in this codebase.
            let lastMessage = (try? storage.messages.messages(
                conversationType: conversation.conversationType,
                target: conversation.target,
                line: conversation.line,
                limit: 1
            ))?.first
            let user = try? storage.users.user(uid: conversation.target)

            if user?.displayName == nil {
                unresolvedUids.append(conversation.target)
            }

            return ConversationRow(
                conversationType: conversation.conversationType,
                target: conversation.target,
                line: conversation.line,
                displayName: user?.displayName ?? user?.name ?? conversation.target,
                avatarURL: user?.portrait,
                previewText: conversation.draft.map { "[草稿] \($0)" } ?? lastMessage?.searchableContent ?? "",
                timestamp: conversation.timestamp,
                unreadCount: conversation.unreadCount,
                isTop: conversation.isTop,
                isMuted: conversation.isMuted,
                lastMessageStatus: lastMessage?.status
            )
        }

        if !unresolvedUids.isEmpty {
            contactSync?.fetchUserInfo(uids: unresolvedUids, forceRefresh: false)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ConversationListViewModelTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/IMStorage/MessageEnums.swift Sources/IMKit/ContactInfoFetching.swift Sources/IMKit/ConversationRow.swift Sources/IMKit/ConversationListViewModel.swift Tests/IMKitTests/ConversationListViewModelTests.swift
git commit -m "feat(IMKit): add ConversationListViewModel"
```

---

## Task 5: `AvatarImageView`

Lives in the `App` Xcode target (not `IMKit`) — `UIImage` decoding is `UIKit`-dependent, and this is otherwise thin glue with no business logic worth unit-testing, verified by build success only (same convention as `Theme`/`LoginViewController`, Plan E).

**Files:**
- Create: `App/AvatarImageView.swift`

- [ ] **Step 1: Implement**

```swift
// App/AvatarImageView.swift
import UIKit
import IMKit

/// Circular avatar view: shows a single-initial placeholder immediately,
/// then swaps in the real image once `AvatarLoader` resolves it.
/// Cell-reuse-safe: `setAvatar` generates a fresh token per call, and the
/// async load's completion checks the token is still current before
/// applying anything — a `UITableViewCell` can be reused for a different
/// row while a previous row's load is still in flight.
final class AvatarImageView: UIImageView {
    private let loader: AvatarLoading
    private var currentToken: UUID?
    private let initialsLabel = UILabel()

    init(loader: AvatarLoading) {
        self.loader = loader
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = Theme.backgroundTertiary

        initialsLabel.textAlignment = .center
        initialsLabel.textColor = Theme.textPrimary
        initialsLabel.font = .systemFont(ofSize: 16, weight: .medium)
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialsLabel)
        NSLayoutConstraint.activate([
            initialsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
    }

    func setAvatar(urlString: String?, displayName: String) {
        let token = UUID()
        currentToken = token
        image = nil
        initialsLabel.text = String(displayName.prefix(1)).uppercased()
        initialsLabel.isHidden = false

        guard let urlString else { return }
        Task {
            let data = await loader.loadAvatarData(from: urlString)
            guard self.currentToken == token, let data, let uiImage = UIImage(data: data) else { return }
            self.image = uiImage
            self.initialsLabel.isHidden = true
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/AvatarImageView.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add AvatarImageView"
```

---

## Task 6: `ConversationListCell`

**Files:**
- Create: `App/ConversationListCell.swift`

- [ ] **Step 1: Implement**

```swift
// App/ConversationListCell.swift
import UIKit
import IMKit

final class ConversationListCell: UITableViewCell {
    static let reuseIdentifier = "ConversationListCell"

    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()
    private let timestampLabel = UILabel()
    private let previewLabel = UILabel()
    private let unreadBadge = UILabel()
    private let muteIcon = UIImageView(image: UIImage(systemName: "bell.slash.fill"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = Theme.textPrimary

        timestampLabel.font = .systemFont(ofSize: 12, weight: .regular)
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.setContentHuggingPriority(.required, for: .horizontal)

        previewLabel.font = .systemFont(ofSize: 14, weight: .regular)
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 1

        unreadBadge.font = .systemFont(ofSize: 12, weight: .semibold)
        unreadBadge.textColor = Theme.textOnAccent
        unreadBadge.backgroundColor = Theme.accent
        unreadBadge.textAlignment = .center
        unreadBadge.layer.cornerRadius = 9
        unreadBadge.clipsToBounds = true
        unreadBadge.setContentHuggingPriority(.required, for: .horizontal)

        muteIcon.tintColor = .secondaryLabel
        muteIcon.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = UIStackView(arrangedSubviews: [nameLabel, timestampLabel])
        topRow.axis = .horizontal
        topRow.spacing = Theme.standardSpacing

        let bottomRow = UIStackView(arrangedSubviews: [previewLabel, muteIcon, unreadBadge])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 6
        bottomRow.alignment = .center

        let textStack = UIStackView(arrangedSubviews: [topRow, bottomRow])
        textStack.axis = .vertical
        textStack.spacing = 4

        let rowStack = UIStackView(arrangedSubviews: [avatarImageView, textStack])
        rowStack.axis = .horizontal
        rowStack.spacing = Theme.standardSpacing
        rowStack.alignment = .center
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 48),
            avatarImageView.heightAnchor.constraint(equalToConstant: 48),
            unreadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            unreadBadge.heightAnchor.constraint(equalToConstant: 18),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(with row: ConversationRow) {
        avatarImageView.setAvatar(urlString: row.avatarURL, displayName: row.displayName)
        nameLabel.text = row.displayName
        timestampLabel.text = Self.formattedTimestamp(row.timestamp)

        switch row.lastMessageStatus {
        case .sending:
            previewLabel.text = "发送中... " + row.previewText
        case .sendFailure:
            previewLabel.text = "发送失败 " + row.previewText
        default:
            previewLabel.text = row.previewText
        }

        muteIcon.isHidden = !row.isMuted
        if row.unreadCount > 0 {
            unreadBadge.text = " \(row.unreadCount) "
            unreadBadge.isHidden = false
        } else {
            unreadBadge.isHidden = true
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func formattedTimestamp(_ millis: Int64) -> String {
        formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/ConversationListCell.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add ConversationListCell"
```

---

## Task 7: `ConversationListViewController`

**Files:**
- Create: `App/ConversationListViewController.swift`

- [ ] **Step 1: Implement**

```swift
// App/ConversationListViewController.swift
import UIKit
import Combine
import IMKit

final class ConversationListViewController: UIViewController {
    private let viewModel: ConversationListViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, ConversationRow>!

    private let tableView = UITableView()

    /// Set by `SceneDelegate` (Task 9) — pushes the chat screen for the
    /// tapped row. A placeholder until Plan H builds the real one.
    var onConversationSelected: ((ConversationRow) -> Void)?

    init(viewModel: ConversationListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "消息"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutTableView()
        configureDataSource()
        bindViewModel()
    }

    private func layoutTableView() {
        tableView.register(ConversationListCell.self, forCellReuseIdentifier: ConversationListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, ConversationRow>(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ConversationListCell.reuseIdentifier, for: indexPath) as! ConversationListCell
            cell.configure(with: row)
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$rows
            .sink { [weak self] rows in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, ConversationRow>()
                snapshot.appendSections([0])
                snapshot.appendItems(rows, toSection: 0)
                self.dataSource.apply(snapshot, animatingDifferences: true)
            }
            .store(in: &cancellables)
    }
}

extension ConversationListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        onConversationSelected?(row)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/ConversationListViewController.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add ConversationListViewController"
```

---

## Task 8: Placeholder `ConversationViewController`

**Files:**
- Create: `App/ConversationViewController.swift`

- [ ] **Step 1: Implement**

```swift
// App/ConversationViewController.swift
import UIKit
import IMKit

/// Placeholder chat screen so this plan produces a complete, runnable,
/// tap-through app. Plan H replaces this with the real message thread.
final class ConversationViewController: UIViewController {
    private let row: ConversationRow

    init(row: ConversationRow) {
        self.row = row
        super.init(nibName: nil, bundle: nil)
        title = row.displayName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary

        let label = UILabel()
        label.text = "与 \(row.displayName) 的聊天界面将在 Plan H 中实现"
        label.textColor = Theme.textPrimary
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/ConversationViewController.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add placeholder ConversationViewController"
```

---

## Task 9: Wire into `SceneDelegate`, retire the `HomeViewController` placeholder

**Files:**
- Modify: `App/SceneDelegate.swift`
- Delete: `App/HomeViewController.swift` (Plan E's placeholder — this plan replaces it with the real screen; no longer referenced anywhere)

- [ ] **Step 1: Replace `App/SceneDelegate.swift`'s body**

```swift
// App/SceneDelegate.swift
import UIKit
import AppCore
import IMStorage
import IMKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var environment: AppEnvironment!

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let storage: IMStorage
        do {
            storage = try IMStorage.open(atPath: AppEnvironment.defaultDatabasePath())
        } catch {
            // Phase 1 has no DB-corruption-recovery UX yet — fail loudly
            // rather than silently falling back to an in-memory store,
            // which would silently lose the user's message history with no
            // indication anything went wrong.
            fatalError("Failed to open local database: \(error)")
        }
        environment = AppEnvironment(storage: storage)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    private func rootViewController() -> UIViewController {
        environment.connectIfPossible() ? makeConversationListNavigationController() : makeLoginViewController()
    }

    private func makeConversationListNavigationController() -> UIViewController {
        let viewModel = ConversationListViewModel(storage: environment.storage, contactSync: environment.contactSyncService)
        let listViewController = ConversationListViewController(viewModel: viewModel)
        listViewController.onConversationSelected = { [weak listViewController] row in
            listViewController?.navigationController?.pushViewController(ConversationViewController(row: row), animated: true)
        }
        return UINavigationController(rootViewController: listViewController)
    }

    private func makeLoginViewController() -> UIViewController {
        let viewModel = LoginViewModel(
            apiClient: LoginAPIClient(baseURL: environment.config.apiBaseURL),
            credentialsStore: environment.credentialsStore,
            deviceIdentifierProvider: environment.deviceIdentifierProvider
        )
        viewModel.onLoginSucceeded = { [weak self] _ in
            guard let self else { return }
            self.environment.connectIfPossible()
            self.window?.rootViewController = self.makeConversationListNavigationController()
        }
        return LoginViewController(viewModel: viewModel)
    }
}
```

- [ ] **Step 2: Delete the now-unreferenced placeholder**

```bash
rm -f App/HomeViewController.swift
```

- [ ] **Step 3: Build and confirm**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **` (the regenerated `project.pbxproj` will both add the new `App/*.swift` files from Tasks 5–8 and remove `HomeViewController.swift`'s entries — check `git status` and include it in the commit).

- [ ] **Step 4: Commit**

```bash
git add App/SceneDelegate.swift
git rm App/HomeViewController.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): show the real conversation list after login instead of the placeholder"
```

---

## Task 10: End-to-end build/test verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full `swift test` suite**

```bash
swift test
```

Expected: all tests pass (194 from Plans A–F + this plan's new `IMStorageTests`/`IMKitTests` additions).

- [ ] **Step 2: Build the App target**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Attempt the Simulator install/launch smoke test, with the known environment caveat**

```bash
xcrun simctl boot "iPhone 15" 2>/dev/null || true
APP_PATH=$(find .build/xcode/Build/Products -name "App.app" -maxdepth 2 | head -1)
xcrun simctl install "iPhone 15" "$APP_PATH"
xcrun simctl launch "iPhone 15" com.fshare.ios-chat-pro.App
```

Expected, if this environment's `simctl install` is still broken (confirmed broken across 4 independent attempts during Plan E/F's work — `boot`/`list`/`shutdown` all respond normally, but `install` hangs indefinitely with near-zero CPU usage): this step will hang. Give it a bounded wait (e.g. 2–3 minutes); if it shows no progress, kill it (`pkill -9 -f "simctl install"`), run `xcrun simctl shutdown "iPhone 15"`, and record the same conclusion as Plan E/F's self-review: `swift test` + `xcodebuild` are this environment's strongest available verification, and the actual on-screen render is unverified here, not because of a code defect. Do not spend excessive time re-litigating this if it reproduces the same hang signature (state `S`, ~0 CPU growth) already documented.

No commit for this task — it's a verification gate, not new code.

---

## Plan Self-Review Notes

- **Spec coverage:** Implements the migration design doc §7's `ConversationListViewController` row — `UITableView` + `UITableViewDiffableDataSource`, subscribed to `conversations` table changes, exactly as specified. Does **not** implement `ConversationViewController`/`ContactListViewController` (§7's other two rows) — those are Plan H and Plan I.
- **Deliberately deferred, matching Android features not ported in Phase 1** (researched, not silently dropped): swipe-to-delete/mute/pin actions, long-press context menu, pull-to-refresh, a "disconnected" connection-status banner row, unread-count display capping (e.g. "99+" — Phase 1 just shows the raw integer). None of these block a usable conversation list; all are reasonable Phase 2+ polish.
- **`IMKit` is a new package**, named and scoped exactly as the migration design doc's §4 code-organization table already anticipated ("IMKit — 对应 chat/kit:UI 组件 — 会话列表、聊天界面、联系人(ViewModel+VC)") — unlike `AppCore` (Plan E) and the protocol-layer packages (`IMMessaging`/`IMContacts`), this one was already named in the original design, just not built until now.
- **`ConversationListViewModel`'s per-row lookups are N+1** (one `messages(...)` call and one `user(uid:)` call per conversation, every time the conversations table changes) — same accepted-for-Phase-1 trade-off already reviewed and approved in Plan F for analogous patterns (`replaceFriendList`, `fetchUserInfo`'s cache filter). Conversation counts in Phase 1's target usage are small; revisit with a batched join query if this ever shows up as a real bottleneck.
- **No image caching beyond the in-process `NSCache` in `AvatarLoader`** — no disk cache, so avatars re-fetch from network on every app launch. Acceptable for Phase 1; a disk-backed cache is a natural Phase 2+ addition if avatar-loading network usage becomes a concern.
- **The placeholder `ConversationViewController` (Task 8) takes a `ConversationRow` snapshot, not a live reference** — Plan H's real implementation will need to re-derive a live view of the conversation (messages can keep arriving while the placeholder/real screen is open), not just display the static row data this plan captured at navigation time. Noted for Plan H, not a gap in this plan's own scope.
- **No placeholders:** every step above has complete, runnable code; nothing is left as "TODO" or "similar to above."

