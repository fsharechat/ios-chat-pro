# Plan K: 好友管理 (Friend Management) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user search for another user by UID/mobile, send them a friend request, and let the recipient see pending/accepted requests on a "新的朋友" page with a single accept action — no reject, no delete-friend, no alias.

**Architecture:** Follows the existing IMStorage → IMContacts → IMKit → App layering used by Plan F/J. New `friendRequest` SQLite table + `FriendRequestStore` persist request state; new tracker/handler/service additions to `IMContacts.ContactSyncService` talk to the server over the existing `.us`/`.far`/`.fhr`/`.frp`/`.frn`/`.frus` sub-signals; three new narrow IMKit protocols (`UserSearching`, `FriendRequestSending`, `FriendRequestSyncing`) decouple the App layer from `ContactSyncService`'s concrete type, mirroring `ImageUploading`; two new IMKit view models (`SearchUserViewModel`, `NewFriendsViewModel`) plus one `ContactListViewModel` addition drive three new/modified App-layer screens.

**Tech Stack:** Swift, GRDB (SQLite), Combine, XCTest, the existing `IMClient`/`IMTransport` frame protocol, UIKit (manual layout, `UIDiffableDataSource` where the codebase already uses it).

---

## Reference: Proto Types Used

```swift
// Im_SearchUserRequest (optional fields)
keyword: String, fuzzy: Int32, page: Int32

// Im_SearchUserResult
entry: [Im_User] = []   // non-optional array

// Im_User (all optional)
uid, name, displayName, portrait, mobile, email, address, company, extra, social: String
updateDt: Int64
gender, type: Int32

// Im_AddFriendRequest (optional)
targetUid: String, reason: String

// Im_HandleFriendRequest (optional)
targetUid: String, status: Int32

// Im_GetFriendRequestResult
entry: [Im_FriendRequest] = []

// Im_FriendRequest (all optional)
fromUid, toUid, reason: String
status: Int32
updateDt: Int64
fromReadStatus, toReadStatus: Bool

// Im_Version (optional, default 0)
version: Int64
```

SubSignal raw values used: `.us = 9` (search user), `.far = 10` (add friend request), `.frn = 12` (friend request notify, PUBLISH), `.frus = 13` (friend request mark-read), `.frp = 14` (friend request pull), `.fhr = 15` (handle friend request / accept).

---

## Task 1: `StoredFriendRequest` model + v3 migration

**Files:**
- Create: `Sources/IMStorage/StoredFriendRequest.swift`
- Modify: `Sources/IMStorage/IMDatabase.swift`
- Test: `Tests/IMStorageTests/IMDatabaseTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/IMStorageTests/IMDatabaseTests.swift` (after the existing `test_openInMemory_createsAllFourTables` test):

```swift
    func test_openInMemory_createsFriendRequestTable() throws {
        let database = try IMDatabase.openInMemory()
        let exists = try database.dbQueue.read { db in
            try db.tableExists("friendRequest")
        }
        XCTAssertTrue(exists)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IMDatabaseTests/test_openInMemory_createsFriendRequestTable`
Expected: FAIL (table "friendRequest" does not exist)

- [ ] **Step 3: Create `StoredFriendRequest.swift`**

```swift
// Sources/IMStorage/StoredFriendRequest.swift
import GRDB

public struct StoredFriendRequest: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "friendRequest"

    public enum Status {
        public static let pending = 0
        public static let accepted = 1
    }

    public var fromUid: String
    public var toUid: String
    public var reason: String
    public var status: Int
    public var updateDt: Int64
    public var fromReadStatus: Bool
    public var toReadStatus: Bool

    public init(fromUid: String, toUid: String, reason: String, status: Int, updateDt: Int64, fromReadStatus: Bool, toReadStatus: Bool) {
        self.fromUid = fromUid
        self.toUid = toUid
        self.reason = reason
        self.status = status
        self.updateDt = updateDt
        self.fromReadStatus = fromReadStatus
        self.toReadStatus = toReadStatus
    }
}
```

- [ ] **Step 4: Add the v3 migration**

In `Sources/IMStorage/IMDatabase.swift`, insert this migration right after the `v2_addUserIsFriend` registration and before `return migrator`:

```swift
        migrator.registerMigration("v3_addFriendRequestTable") { db in
            try db.create(table: "friendRequest") { t in
                t.column("fromUid", .text).notNull()
                t.column("toUid", .text).notNull()
                t.column("reason", .text).notNull().defaults(to: "")
                t.column("status", .integer).notNull().defaults(to: 0)
                t.column("updateDt", .integer).notNull().defaults(to: 0)
                t.column("fromReadStatus", .boolean).notNull().defaults(to: false)
                t.column("toReadStatus", .boolean).notNull().defaults(to: false)
                t.primaryKey(["fromUid", "toUid"])
            }
        }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter IMDatabaseTests/test_openInMemory_createsFriendRequestTable`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMStorage/StoredFriendRequest.swift Sources/IMStorage/IMDatabase.swift Tests/IMStorageTests/IMDatabaseTests.swift
git commit -m "feat(storage): add friendRequest table and StoredFriendRequest model"
```

---

## Task 2: `FriendRequestStore` + IMStorage facade wiring

**Files:**
- Create: `Sources/IMStorage/FriendRequestStore.swift`
- Modify: `Sources/IMStorage/IMStorage.swift`
- Test: `Tests/IMStorageTests/FriendRequestStoreTests.swift`
- Test: `Tests/IMStorageTests/IMStorageTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/IMStorageTests/FriendRequestStoreTests.swift`:

```swift
// Tests/IMStorageTests/FriendRequestStoreTests.swift
import XCTest
import Combine
@testable import IMStorage

final class FriendRequestStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: FriendRequestStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = FriendRequestStore(dbQueue: database.dbQueue)
    }

    func test_upsert_thenIncomingRequestsPublisher_emitsTheRow() throws {
        let request = StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false)
        try store.upsert(request)

        let expectation = expectation(description: "row appears")
        store.incomingRequestsPublisher()
            .replaceError(with: [])
            .sink { rows in if !rows.isEmpty { expectation.fulfill() } }
            .store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        let rows = try database.dbQueue.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows, [request])
    }

    func test_upsert_sameFromAndToUid_replacesPreviousRow() throws {
        try store.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))
        try store.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi again", status: StoredFriendRequest.Status.pending, updateDt: 200, fromReadStatus: false, toReadStatus: false))

        let rows = try database.dbQueue.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.reason, "hi again")
        XCTAssertEqual(rows.first?.updateDt, 200)
    }

    func test_markAccepted_updatesStatusToAccepted() throws {
        try store.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))
        try store.markAccepted(fromUid: "u1")

        let rows = try database.dbQueue.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows.first?.status, StoredFriendRequest.Status.accepted)
    }

    func test_unreadIncomingCountPublisher_countsOnlyUnreadRows() throws {
        try store.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))
        try store.upsert(StoredFriendRequest(fromUid: "u2", toUid: "me", reason: "", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: true))

        let expectation = expectation(description: "count settles at 1")
        expectation.assertForOverFulfill = false
        store.unreadIncomingCountPublisher()
            .replaceError(with: 0)
            .sink { count in if count == 1 { expectation.fulfill() } }
            .store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }
}
```

Add to `Tests/IMStorageTests/IMStorageTests.swift` (needs `import Combine` added at the top):

```swift
    func test_friendRequests_isWiredIntoFacade() throws {
        let storage = try IMStorage.openInMemory()
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        let expectation = expectation(description: "row appears via facade")
        var cancellables: Set<AnyCancellable> = []
        storage.friendRequests.incomingRequestsPublisher()
            .replaceError(with: [])
            .sink { rows in if !rows.isEmpty { expectation.fulfill() } }
            .store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FriendRequestStoreTests`
Expected: FAIL (no such module member `FriendRequestStore`)

- [ ] **Step 3: Create `FriendRequestStore.swift`**

```swift
// Sources/IMStorage/FriendRequestStore.swift
import GRDB
import Combine

/// Friend requests are scoped to "where I am the recipient" entirely on the
/// server side — the `.frp` pull endpoint only ever returns requests sent
/// *to* the current user, mirroring how Android's own friend-request inbox
/// never shows outgoing requests. Every row in this local table therefore
/// already satisfies `toUid == myUid` by construction, so no method here
/// takes a `myUid` parameter.
public final class FriendRequestStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ request: StoredFriendRequest) throws {
        try dbQueue.write { db in
            try request.save(db)
        }
    }

    public func markAccepted(fromUid: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE friendRequest SET status = ? WHERE fromUid = ?",
                arguments: [StoredFriendRequest.Status.accepted, fromUid]
            )
        }
    }

    public func incomingRequestsPublisher() -> AnyPublisher<[StoredFriendRequest], Error> {
        ValueObservation
            .tracking { db in try StoredFriendRequest.order(Column("updateDt").desc).fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    public func unreadIncomingCountPublisher() -> AnyPublisher<Int, Error> {
        ValueObservation
            .tracking { db in try StoredFriendRequest.filter(Column("toReadStatus") == false).fetchCount(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }
}
```

- [ ] **Step 4: Wire into `IMStorage.swift`**

In `Sources/IMStorage/IMStorage.swift`, change:

```swift
    public let syncState: SyncStateStore

    private init(database: IMDatabase) {
        messages = MessageStore(dbQueue: database.dbQueue)
        conversations = ConversationStore(dbQueue: database.dbQueue)
        users = UserStore(dbQueue: database.dbQueue)
        syncState = SyncStateStore(dbQueue: database.dbQueue)
    }
```

to:

```swift
    public let syncState: SyncStateStore
    public let friendRequests: FriendRequestStore

    private init(database: IMDatabase) {
        messages = MessageStore(dbQueue: database.dbQueue)
        conversations = ConversationStore(dbQueue: database.dbQueue)
        users = UserStore(dbQueue: database.dbQueue)
        syncState = SyncStateStore(dbQueue: database.dbQueue)
        friendRequests = FriendRequestStore(dbQueue: database.dbQueue)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter FriendRequestStoreTests` and `swift test --filter IMStorageTests/test_friendRequests_isWiredIntoFacade`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMStorage/FriendRequestStore.swift Sources/IMStorage/IMStorage.swift Tests/IMStorageTests/FriendRequestStoreTests.swift Tests/IMStorageTests/IMStorageTests.swift
git commit -m "feat(storage): add FriendRequestStore and wire into IMStorage facade"
```

---

## Task 3: `UserSearchTracker`

**Files:**
- Create: `Sources/IMContacts/UserSearchTracker.swift`
- Test: `Tests/IMContactsTests/UserSearchTrackerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMContactsTests/UserSearchTrackerTests.swift
import XCTest
import IMClient
@testable import IMContacts

final class UserSearchTrackerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: UserSearchTracker!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = UserSearchTracker(scheduler: scheduler)
    }

    func test_resolve_afterTrack_invokesCompletionWithSuccess() {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .success(["u1", "u2"]))

        switch captured {
        case .success(let uids): XCTAssertEqual(uids, ["u1", "u2"])
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_resolve_withFailure_invokesCompletionWithFailure() {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .failure(.serverError(errorCode: 6)))

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_resolve_unknownWireMessageId_doesNothingNoCrash() {
        tracker.resolve(wireMessageId: 42, result: .success(["u1"])) // no track() call first
    }

    func test_timeout_firesFailureWithTimeoutError_ifNoResponseArrives() {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
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

        tracker.resolve(wireMessageId: 7, result: .success(["u1"]))
        XCTAssertEqual(completionCallCount, 1)

        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(completionCallCount, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UserSearchTrackerTests`
Expected: FAIL (no such module member `UserSearchTracker`)

- [ ] **Step 3: Create `UserSearchTracker.swift`**

```swift
// Sources/IMContacts/UserSearchTracker.swift
import IMClient

/// Correlates an outgoing `Signal.publish`/`SubSignal.us` search request to
/// its response by the wire `messageId` `IMClient.sendFrame` returned —
/// same shape as `IMMedia`'s `MinioUploadURLTracker`. The success payload
/// is the matched `[uid]` list, not the raw protobuf: `UserSearchHandler`
/// upserts each `Im_User` into `UserStore` itself before resolving this
/// tracker.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class UserSearchTracker {
    public enum TrackerError: Error, Equatable {
        case serverError(errorCode: Int32)
        case malformedResponse
        case timeout
    }

    private final class Pending {
        let completion: (Result<[String], TrackerError>) -> Void
        var timeoutToken: SchedulerToken?

        init(completion: @escaping (Result<[String], TrackerError>) -> Void) {
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, completion: @escaping (Result<[String], TrackerError>) -> Void) {
        let entry = Pending(completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failure(.timeout))
        }
        pending[wireMessageId] = entry
    }

    public func resolve(wireMessageId: UInt16, result: Result<[String], TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UserSearchTrackerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMContacts/UserSearchTracker.swift Tests/IMContactsTests/UserSearchTrackerTests.swift
git commit -m "feat(contacts): add UserSearchTracker"
```

---

## Task 4: `FriendRequestActionTracker`

**Files:**
- Create: `Sources/IMContacts/FriendRequestActionTracker.swift`
- Test: `Tests/IMContactsTests/FriendRequestActionTrackerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMContactsTests/FriendRequestActionTrackerTests.swift
import XCTest
import IMClient
@testable import IMContacts

final class FriendRequestActionTrackerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: FriendRequestActionTracker!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = FriendRequestActionTracker(scheduler: scheduler)
    }

    func test_resolve_afterTrack_invokesCompletionWithSuccess() {
        var captured: Result<Void, FriendRequestActionTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result in captured = result }

        tracker.resolve(wireMessageId: 7, result: .success(()))

        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_resolve_withFailure_invokesCompletionWithFailure() {
        var captured: Result<Void, FriendRequestActionTracker.TrackerError>?
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
        var captured: Result<Void, FriendRequestActionTracker.TrackerError>?
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

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FriendRequestActionTrackerTests`
Expected: FAIL (no such module member `FriendRequestActionTracker`)

- [ ] **Step 3: Create `FriendRequestActionTracker.swift`**

```swift
// Sources/IMContacts/FriendRequestActionTracker.swift
import IMClient

/// Correlates an outgoing `Signal.publish`/`.far` (send request) or `.fhr`
/// (accept request) call to its response by wire `messageId`. Both
/// requests get a bare "1 byte error code, no payload" response, so this
/// tracker (unlike `UserSearchTracker`/`MinioUploadURLTracker`) resolves
/// to plain `Void` on success rather than a parsed payload — and has no
/// `.malformedResponse` case, since there is no payload to fail to parse.
/// `IMClient.sendFrame`'s `nextMessageId` is a single incrementing counter
/// shared across every outgoing frame, so one tracker safely serves both
/// `.far` and `.fhr` calls without messageId collisions.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class FriendRequestActionTracker {
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

    public func resolve(wireMessageId: UInt16, result: Result<Void, TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FriendRequestActionTrackerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMContacts/FriendRequestActionTracker.swift Tests/IMContactsTests/FriendRequestActionTrackerTests.swift
git commit -m "feat(contacts): add FriendRequestActionTracker"
```

---

## Task 5: `UserSearchHandler`

**Files:**
- Create: `Sources/IMContacts/UserSearchHandler.swift`
- Test: `Tests/IMContactsTests/UserSearchHandlerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMContactsTests/UserSearchHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class UserSearchHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var scheduler: ManualScheduler!
    private var tracker: UserSearchTracker!
    private var handler: UserSearchHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        scheduler = ManualScheduler()
        tracker = UserSearchTracker(scheduler: scheduler)
        handler = UserSearchHandler(storage: storage, tracker: tracker)
    }

    private func makeUser(uid: String, displayName: String) -> Im_User {
        var user = Im_User()
        user.uid = uid
        user.displayName = displayName
        return user
    }

    private func makeFrame(errorCode: UInt8, users: [Im_User] = []) throws -> Frame {
        var result = Im_SearchUserResult()
        result.entry = users
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .us, bodyLength: UInt32(body.count), messageId: 9), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndUS() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .us))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .far))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .us))
    }

    func test_handle_successBody_upsertsEachUserAndResolvesTrackerWithUids() throws {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let frame = try makeFrame(errorCode: 0, users: [makeUser(uid: "u1", displayName: "Alice"), makeUser(uid: "u2", displayName: "Bob")])
        handler.handle(frame: frame)

        switch captured {
        case .success(let uids): XCTAssertEqual(uids, ["u1", "u2"])
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
        XCTAssertEqual(try storage.users.user(uid: "u1")?.displayName, "Alice")
        XCTAssertEqual(try storage.users.user(uid: "u2")?.displayName, "Bob")
    }

    func test_handle_upsertingMatchedUser_doesNotMarkThemAsFriend() throws {
        let frame = try makeFrame(errorCode: 0, users: [makeUser(uid: "u1", displayName: "Alice")])
        handler.handle(frame: frame)

        XCTAssertEqual(try storage.users.friends().count, 0)
    }

    func test_handle_nonZeroErrorCode_resolvesTrackerWithServerError() throws {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let frame = try makeFrame(errorCode: 6)
        handler.handle(frame: frame)

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_handle_zeroErrorCodeButMalformedBody_resolvesTrackerWithMalformedResponseImmediately() {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let body = Data([0]) + Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .us, bodyLength: UInt32(body.count), messageId: 9), body: body)
        handler.handle(frame: frame)

        switch captured {
        case .failure(.malformedResponse): break
        default: XCTFail("expected .failure(.malformedResponse), got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .us, bodyLength: 0, messageId: 9), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UserSearchHandlerTests`
Expected: FAIL (no such module member `UserSearchHandler`)

- [ ] **Step 3: Create `UserSearchHandler.swift`**

```swift
// Sources/IMContacts/UserSearchHandler.swift
import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `PUB_ACK`/`.us` search response and resolves the matching
/// `UserSearchTracker` entry. Same "1 byte error code, then protobuf" wire
/// format as every other `PUB_ACK` handler in this codebase. Every matched
/// `Im_User` is upserted into `UserStore` via `upsertProfile(...)` (never
/// touching `isFriend` — search results say nothing about friendship
/// status) before the tracker is resolved with the matched `[uid]` list.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class UserSearchHandler: MessageHandler {
    private let storage: IMStorage
    private let tracker: UserSearchTracker

    public init(storage: IMStorage, tracker: UserSearchTracker) {
        self.storage = storage
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .us
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        if errorCode == 0 {
            guard let result = try? Im_SearchUserResult(serializedBytes: frame.body.dropFirst()) else {
                tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.malformedResponse))
                return
            }
            for user in result.entry {
                // Accepted Phase-2 gap: a failed upsert for one user is
                // silently dropped (no logging facility yet), same as
                // UserInfoSyncHandler/FriendSyncHandler.
                try? storage.users.upsertProfile(
                    uid: user.uid,
                    name: user.hasName ? user.name : nil,
                    displayName: user.hasDisplayName ? user.displayName : nil,
                    portrait: user.hasPortrait ? user.portrait : nil,
                    mobile: user.hasMobile ? user.mobile : nil,
                    gender: Int(user.gender),
                    updateDt: user.updateDt
                )
            }
            tracker.resolve(wireMessageId: frame.header.messageId, result: .success(result.entry.map(\.uid)))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.serverError(errorCode: Int32(errorCode))))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UserSearchHandlerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMContacts/UserSearchHandler.swift Tests/IMContactsTests/UserSearchHandlerTests.swift
git commit -m "feat(contacts): add UserSearchHandler"
```

---

## Task 6: `FriendRequestActionHandler`

**Files:**
- Create: `Sources/IMContacts/FriendRequestActionHandler.swift`
- Test: `Tests/IMContactsTests/FriendRequestActionHandlerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMContactsTests/FriendRequestActionHandlerTests.swift
import XCTest
import IMClient
import IMTransport
@testable import IMContacts

final class FriendRequestActionHandlerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var tracker: FriendRequestActionTracker!
    private var handler: FriendRequestActionHandler!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        tracker = FriendRequestActionTracker(scheduler: scheduler)
        handler = FriendRequestActionHandler(tracker: tracker)
    }

    private func makeFrame(subSignal: SubSignal, errorCode: UInt8) -> Frame {
        Frame(header: Header(signal: .pubAck, subSignal: subSignal, bodyLength: 1, messageId: 9), body: Data([errorCode]))
    }

    func test_canHandle_matchesPubAckFARAndFHR_butNothingElse() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .far))
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .fhr))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .us))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .far))
    }

    func test_handle_farSuccessBody_resolvesTrackerWithSuccess() {
        var captured: Result<Void, FriendRequestActionTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(subSignal: .far, errorCode: 0))

        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_handle_fhrSuccessBody_resolvesTrackerWithSuccess() {
        var captured: Result<Void, FriendRequestActionTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(subSignal: .fhr, errorCode: 0))

        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }

    func test_handle_nonZeroErrorCode_resolvesTrackerWithServerError() {
        var captured: Result<Void, FriendRequestActionTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        handler.handle(frame: makeFrame(subSignal: .far, errorCode: 6))

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .far, bodyLength: 0, messageId: 9), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FriendRequestActionHandlerTests`
Expected: FAIL (no such module member `FriendRequestActionHandler`)

- [ ] **Step 3: Create `FriendRequestActionHandler.swift`**

```swift
// Sources/IMContacts/FriendRequestActionHandler.swift
import IMClient
import IMTransport

/// Parses the bare "1 byte error code, no payload" response shared by both
/// `.far` (send friend request) and `.fhr` (accept friend request) and
/// resolves the matching `FriendRequestActionTracker` entry. One handler
/// covers both sub-signals since `IMClient.sendFrame`'s `nextMessageId` is
/// a single incrementing counter shared across every outgoing frame, so a
/// `messageId` lookup alone is enough to find the right pending entry
/// regardless of which of the two requests it came from.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class FriendRequestActionHandler: MessageHandler {
    private let tracker: FriendRequestActionTracker

    public init(tracker: FriendRequestActionTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && (subSignal == .far || subSignal == .fhr)
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FriendRequestActionHandlerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMContacts/FriendRequestActionHandler.swift Tests/IMContactsTests/FriendRequestActionHandlerTests.swift
git commit -m "feat(contacts): add FriendRequestActionHandler"
```

---

## Task 7: `FriendRequestSyncHandler`

**Files:**
- Create: `Sources/IMContacts/FriendRequestSyncHandler.swift`
- Test: `Tests/IMContactsTests/FriendRequestSyncHandlerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMContactsTests/FriendRequestSyncHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class FriendRequestSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: FriendRequestSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = FriendRequestSyncHandler(storage: storage)
    }

    private func makeEntry(fromUid: String, toUid: String, updateDt: Int64) -> Im_FriendRequest {
        var entry = Im_FriendRequest()
        entry.fromUid = fromUid
        entry.toUid = toUid
        entry.reason = "hi"
        entry.status = 0
        entry.updateDt = updateDt
        entry.fromReadStatus = false
        entry.toReadStatus = false
        return entry
    }

    private func makeFrpFrame(errorCode: UInt8, entries: [Im_FriendRequest] = []) throws -> Frame {
        var result = Im_GetFriendRequestResult()
        result.entry = entries
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .frp, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    private func makeFrnFrame(headValue: Int64) -> Frame {
        var bytes = [UInt8](repeating: 0, count: 8)
        var value = headValue
        for index in stride(from: 7, through: 0, by: -1) {
            bytes[index] = UInt8(value & 0xff)
            value >>= 8
        }
        let body = Data(bytes)
        return Frame(header: Header(signal: .publish, subSignal: .frn, bodyLength: UInt32(body.count), messageId: 0), body: body)
    }

    func test_canHandle_matchesFRPPullResponseAndFRNNotify_butNothingElse() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .frp))
        XCTAssertTrue(handler.canHandle(signal: .publish, subSignal: .frn))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .frn))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .frp))
    }

    func test_handle_frpSuccessBody_upsertsEntriesAndAdvancesHeadToMaxUpdateDt() throws {
        let frame = try makeFrpFrame(errorCode: 0, entries: [
            makeEntry(fromUid: "u1", toUid: "me", updateDt: 100),
            makeEntry(fromUid: "u2", toUid: "me", updateDt: 300),
        ])

        handler.handle(frame: frame)

        let rows = try storage.dbQueueForTesting.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(Set(rows.map(\.fromUid)), ["u1", "u2"])
        XCTAssertEqual(try storage.syncState.get().friendRequestHead, 300)
    }

    func test_handle_frpEmptyResult_doesNotAdvanceHead() throws {
        var initial = try storage.syncState.get()
        initial.friendRequestHead = 50
        try storage.syncState.set(initial)

        let frame = try makeFrpFrame(errorCode: 0, entries: [])
        handler.handle(frame: frame)

        XCTAssertEqual(try storage.syncState.get().friendRequestHead, 50)
    }

    func test_handle_frpNonZeroErrorCode_doesNothingNoCrash() throws {
        let frame = try makeFrpFrame(errorCode: 1, entries: [makeEntry(fromUid: "u1", toUid: "me", updateDt: 100)])
        handler.handle(frame: frame)

        let rows = try storage.dbQueueForTesting.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows.count, 0)
    }

    func test_handle_frnNotify_writesDecodedValueMinusOneToHeadAndFiresCallback() {
        var callbackFired = false
        handler.onRemoteUpdateNotified = { callbackFired = true }

        handler.handle(frame: makeFrnFrame(headValue: 501))

        XCTAssertEqual(try? storage.syncState.get().friendRequestHead, 500)
        XCTAssertTrue(callbackFired)
    }

    func test_handle_frnNotify_shortBody_doesNothingNoCrash() {
        var callbackFired = false
        handler.onRemoteUpdateNotified = { callbackFired = true }

        let frame = Frame(header: Header(signal: .publish, subSignal: .frn, bodyLength: 3, messageId: 0), body: Data([0, 1, 2]))
        handler.handle(frame: frame) // must not crash

        XCTAssertFalse(callbackFired)
    }
}
```

This test references `storage.dbQueueForTesting` — `IMStorage` does not expose this today. Add a test-only accessor since Task 7 is the first place a test needs to read the `friendRequest` table directly through `IMStorage` rather than through `FriendRequestStore`. Add to `Sources/IMStorage/IMStorage.swift`, right after the existing `public let friendRequests: FriendRequestStore` line:

```swift
    /// Test-only escape hatch for asserting on raw table contents. Not for
    /// production use — production code always goes through one of the
    /// stores above.
    public var dbQueueForTesting: DatabaseQueue { database.dbQueue }
```

This requires keeping a reference to `database` on `IMStorage`. Change:

```swift
    private init(database: IMDatabase) {
        messages = MessageStore(dbQueue: database.dbQueue)
        conversations = ConversationStore(dbQueue: database.dbQueue)
        users = UserStore(dbQueue: database.dbQueue)
        syncState = SyncStateStore(dbQueue: database.dbQueue)
        friendRequests = FriendRequestStore(dbQueue: database.dbQueue)
    }
```

to:

```swift
    private let database: IMDatabase

    private init(database: IMDatabase) {
        self.database = database
        messages = MessageStore(dbQueue: database.dbQueue)
        conversations = ConversationStore(dbQueue: database.dbQueue)
        users = UserStore(dbQueue: database.dbQueue)
        syncState = SyncStateStore(dbQueue: database.dbQueue)
        friendRequests = FriendRequestStore(dbQueue: database.dbQueue)
    }
```

And add `import GRDB` to the top of `Sources/IMStorage/IMStorage.swift` (needed for the `DatabaseQueue` return type).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FriendRequestSyncHandlerTests`
Expected: FAIL (no such module member `FriendRequestSyncHandler`)

- [ ] **Step 3: Create `FriendRequestSyncHandler.swift`**

```swift
// Sources/IMContacts/FriendRequestSyncHandler.swift
import IMClient
import IMTransport
import IMProto
import IMStorage

/// Handles two distinct wire messages that both relate to keeping the
/// local `friendRequest` table in sync:
///
/// - `PUB_ACK`/`.frp`: the response to a `syncFriendRequests()` pull.
///   Standard "1 byte error code, then protobuf" format. Upserts every
///   entry, then advances `syncState.friendRequestHead` to the batch's max
///   `updateDt` — but only if the batch is non-empty (an empty pull result
///   carries no information about the true head, so leaving it alone is
///   the correct "do nothing" response).
/// - `PUBLISH`/`.frn`: an unprompted server push ("something about your
///   friend requests changed"), matching `NotifyMessageHandler`'s
///   `.publish`-not-`.pubAck` shape for unprompted pushes. The body is a
///   raw 8-byte big-endian `Int64`, with **no** leading error-code byte —
///   this is a `PUBLISH`, not a `PUB_ACK` response, so that convention
///   doesn't apply. Decoded via manual byte-shifting (mirroring
///   `Header.decode`'s big-endian field decoding) rather than
///   `withUnsafeBytes`, which would have alignment-UB risk on arbitrary
///   `Data` slices. The decoded value minus 1 is written directly to
///   `syncState.friendRequestHead` (matching Android's own client) — the
///   `-1` means the next `syncFriendRequests()` pull's strict
///   greater-than-style comparison on the server doesn't skip the request
///   that exactly produced this new head value. `onRemoteUpdateNotified`
///   is then invoked so the caller (`ContactSyncService`) can trigger a
///   follow-up `syncFriendRequests()` pull to fetch the actual content.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class FriendRequestSyncHandler: MessageHandler {
    public var onRemoteUpdateNotified: (() -> Void)?

    private let storage: IMStorage

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        (signal == .pubAck && subSignal == .frp) || (signal == .publish && subSignal == .frn)
    }

    public func handle(frame: Frame) {
        if frame.header.signal == .pubAck {
            handlePullResponse(frame: frame)
        } else {
            handleRemoteNotify(frame: frame)
        }
    }

    private func handlePullResponse(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_GetFriendRequestResult(serializedBytes: frame.body.dropFirst()) else { return }
        guard !result.entry.isEmpty else { return }

        let requests = result.entry.map { entry in
            StoredFriendRequest(
                fromUid: entry.fromUid,
                toUid: entry.toUid,
                reason: entry.reason,
                status: Int(entry.status),
                updateDt: entry.updateDt,
                fromReadStatus: entry.fromReadStatus,
                toReadStatus: entry.toReadStatus
            )
        }
        for request in requests {
            // Accepted Phase-2 gap: a failed upsert for one row is silently
            // dropped (no logging facility yet), same as every other
            // PUB_ACK handler in this codebase.
            try? storage.friendRequests.upsert(request)
        }

        guard let maxUpdateDt = requests.map(\.updateDt).max() else { return }
        guard var syncState = try? storage.syncState.get() else { return }
        syncState.friendRequestHead = maxUpdateDt
        try? storage.syncState.set(syncState)
    }

    private func handleRemoteNotify(frame: Frame) {
        guard frame.body.count >= 8 else { return }
        let bytes = [UInt8](frame.body.prefix(8))
        var value: Int64 = 0
        for byte in bytes {
            value = (value << 8) | Int64(byte)
        }

        guard var syncState = try? storage.syncState.get() else { return }
        syncState.friendRequestHead = value - 1
        try? storage.syncState.set(syncState)

        onRemoteUpdateNotified?()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FriendRequestSyncHandlerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMContacts/FriendRequestSyncHandler.swift Tests/IMContactsTests/FriendRequestSyncHandlerTests.swift Sources/IMStorage/IMStorage.swift
git commit -m "feat(contacts): add FriendRequestSyncHandler for FRP pull and FRN notify"
```

---

## Task 8: Extend `ContactSyncService` with search/request/sync/read methods

**Files:**
- Modify: `Sources/IMContacts/ContactSyncService.swift`
- Modify: `Tests/IMContactsTests/ContactSyncServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/IMContactsTests/ContactSyncServiceTests.swift`, change the test class's stored properties and `setUpWithError()` to inject a `ManualScheduler` (needed so the new tracker-backed methods have controllable timeouts in later tests, even though none of the tests below exercise the timeout path directly):

```swift
final class ContactSyncServiceTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var scheduler: ManualScheduler!
    private var service: ContactSyncService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        scheduler = ManualScheduler()
        service = ContactSyncService(imClient: imClient, storage: storage, scheduler: scheduler)

        imClient.connect()
        fakeTransport.simulate(.connected) // CONNECT message send completes synchronously via the fake's completion callback
    }
```

Add these tests to the same file (after the existing `test_receivingUPUIResponse_isHandledEndToEnd` test):

```swift
    func test_searchUser_sendsKeywordFuzzyOneAndPageZero() throws {
        service.searchUser(keyword: "alice") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .us)
        let request = try Im_SearchUserRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.keyword, "alice")
        XCTAssertEqual(request.fuzzy, 1)
        XCTAssertEqual(request.page, 0)
    }

    func test_sendFriendRequest_sendsTargetUidAndReason() throws {
        service.sendFriendRequest(to: "u1", reason: "hi") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .far)
        let request = try Im_AddFriendRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.targetUid, "u1")
        XCTAssertEqual(request.reason, "hi")
    }

    func test_acceptFriendRequest_sendsTargetUidAndStatusOne() throws {
        service.acceptFriendRequest(from: "u1") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .fhr)
        let request = try Im_HandleFriendRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.targetUid, "u1")
        XCTAssertEqual(request.status, 1)
    }

    func test_acceptFriendRequest_onSuccess_marksAcceptedLocallyAndRePullsFriendRequests() throws {
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        var capturedResult: Result<Void, Error>?
        service.acceptFriendRequest(from: "u1") { result in capturedResult = result }

        let acceptFrame = try decodeOnlySentFrame()
        let acceptFrameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .fhr, messageId: acceptFrame.header.messageId, body: Data([0x00]))
        fakeTransport.simulateReceivedData(acceptFrameBytes)

        switch capturedResult {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: capturedResult))")
        }
        let rows = try storage.dbQueueForTesting.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows.first?.status, StoredFriendRequest.Status.accepted)

        let followUpFrame = try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
        XCTAssertEqual(followUpFrame.header.subSignal, .frp)
    }

    func test_syncFriendRequests_sendsCurrentFriendRequestHeadAsVersion() throws {
        var state = try storage.syncState.get()
        state.friendRequestHead = 777
        try storage.syncState.set(state)

        service.syncFriendRequests()

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .frp)
        let request = try Im_Version(serializedBytes: frame.body)
        XCTAssertEqual(request.version, 777)
    }

    func test_markFriendRequestsAsRead_sendsFRUSWithNonZeroVersion() throws {
        service.markFriendRequestsAsRead()

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .frus)
        let request = try Im_Version(serializedBytes: frame.body)
        XCTAssertGreaterThan(request.version, 0)
    }

    func test_receivingFRNNotify_triggersAFollowUpFRPPull() throws {
        let frameBytes = FrameEncoder.encode(signal: .publish, subSignal: .frn, messageId: 0, body: Data([0, 0, 0, 0, 0, 0, 0, 1]))

        fakeTransport.simulateReceivedData(frameBytes)

        let frame = try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
        XCTAssertEqual(frame.header.subSignal, .frp)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ContactSyncServiceTests`
Expected: FAIL (no member `searchUser`/`sendFriendRequest`/`acceptFriendRequest`/`syncFriendRequests`/`markFriendRequestsAsRead`, and the modified `init` call doesn't compile yet)

- [ ] **Step 3: Modify `ContactSyncService.swift`**

Replace the entire file with:

```swift
// Sources/IMContacts/ContactSyncService.swift
import Foundation
import IMClient
import IMProto
import IMStorage

public enum ContactSyncServiceError: Error, Equatable {
    case requestEncodingFailed
}

/// The single entry point Plan G's UI code constructs (or, more likely,
/// `AppEnvironment` constructs once and Plan G's view models read
/// `IMStorage.UserStore` directly — this service only owns *sending*
/// requests, not data access): registers `FriendSyncHandler`/
/// `UserInfoSyncHandler`/`UserSearchHandler`/`FriendRequestActionHandler`/
/// `FriendRequestSyncHandler` with the given `IMClient`, and exposes
/// `syncFriendList()`/`fetchUserInfo(uids:forceRefresh:)`/`searchUser(...)`/
/// `sendFriendRequest(...)`/`acceptFriendRequest(...)`/
/// `syncFriendRequests()`/`markFriendRequestsAsRead()`.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ContactSyncService {
    private let imClient: IMClient
    private let storage: IMStorage
    private let userSearchTracker: UserSearchTracker
    private let friendRequestActionTracker: FriendRequestActionTracker

    public init(imClient: IMClient, storage: IMStorage, scheduler: Scheduler = DispatchQueueScheduler()) {
        self.imClient = imClient
        self.storage = storage
        userSearchTracker = UserSearchTracker(scheduler: scheduler)
        friendRequestActionTracker = FriendRequestActionTracker(scheduler: scheduler)

        imClient.register(FriendSyncHandler(storage: storage))
        imClient.register(UserInfoSyncHandler(storage: storage))
        imClient.register(UserSearchHandler(storage: storage, tracker: userSearchTracker))
        imClient.register(FriendRequestActionHandler(tracker: friendRequestActionTracker))

        let friendRequestSyncHandler = FriendRequestSyncHandler(storage: storage)
        friendRequestSyncHandler.onRemoteUpdateNotified = { [weak self] in self?.syncFriendRequests() }
        imClient.register(friendRequestSyncHandler)
    }

    /// Always a full refresh (`version: 0`) — Android's own client never
    /// does incremental friend sync either. Call once after a successful
    /// connect (wire this to `ConnectAckHandler.onSyncState`, a later
    /// task), same as Android's `ConnectAckMessageHandler`.
    public func syncFriendList() {
        var request = Im_Version()
        request.version = 0
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .fp, body: body)
    }

    /// Requests profiles for `uids` not already cached locally, unless
    /// `forceRefresh` is true (then every requested uid goes out over the
    /// wire regardless of cache state). Sends nothing if there's nothing to
    /// ask for. Mirrors Android's `getUserInfo`/`getUserInfos` cache-check.
    public func fetchUserInfo(uids: [String], forceRefresh: Bool) {
        let targetUids: [String]
        if forceRefresh {
            targetUids = uids
        } else {
            // Not just "row doesn't exist" — FriendSyncHandler's
            // replaceFriendList(uids:) creates an empty placeholder row (every
            // profile field nil) for any newly-flagged friend before their
            // profile is ever resolved. A presence-only check would treat that
            // placeholder as "already cached" and never fetch the real
            // profile. displayName == nil is the same "not yet resolved"
            // signal UserStore.friends() already sorts by elsewhere.
            // Trade-off: a genuinely-resolved user whose server profile never
            // sets display_name (only name/mobile, say) would keep matching
            // this check and get redundantly re-requested on every call —
            // accepted for Phase 1 (extra network traffic, no data
            // corruption) rather than adding a dedicated placeholder marker.
            targetUids = uids.filter { uid in
                guard let user = try? storage.users.user(uid: uid) else { return true }
                return user.displayName == nil
            }
        }
        guard !targetUids.isEmpty else { return }

        var request = Im_PullUserRequest()
        request.request = targetUids.map { uid in
            var userRequest = Im_UserRequest()
            userRequest.uid = uid
            return userRequest
        }
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .upui, body: body)
    }

    /// Searches for users by uid/mobile (or display name, depending on
    /// server-side `fuzzy` matching). Matched profiles are written into
    /// `UserStore` by `UserSearchHandler` before this completion fires;
    /// callers needing the actual profile fields read them from
    /// `IMStorage.UserStore` directly.
    public func searchUser(keyword: String, completion: @escaping (Result<[String], Error>) -> Void) {
        var request = Im_SearchUserRequest()
        request.keyword = keyword
        request.fuzzy = 1
        request.page = 0
        guard let body = try? request.serializedData() else {
            completion(.failure(ContactSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .us, body: body)
        userSearchTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    public func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_AddFriendRequest()
        request.targetUid = uid
        request.reason = reason
        guard let body = try? request.serializedData() else {
            completion(.failure(ContactSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .far, body: body)
        friendRequestActionTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    /// On success, immediately marks the local row accepted (rather than
    /// waiting for the next incremental pull) and kicks off a
    /// `syncFriendRequests()` re-pull for eventual consistency with the
    /// server's own bookkeeping (e.g. `updateDt`).
    public func acceptFriendRequest(from uid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_HandleFriendRequest()
        request.targetUid = uid
        request.status = 1 // server ignores this value but the field is still filled per its declared semantics
        guard let body = try? request.serializedData() else {
            completion(.failure(ContactSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .fhr, body: body)
        friendRequestActionTracker.track(wireMessageId: wireMessageId) { [weak self] result in
            switch result {
            case .success:
                try? self?.storage.friendRequests.markAccepted(fromUid: uid)
                completion(.success(()))
                self?.syncFriendRequests()
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Incremental pull, unlike `syncFriendList()` — sends the locally
    /// stored `friendRequestHead` (not a fixed `0`) so the server only
    /// returns requests newer than what's already synced.
    public func syncFriendRequests() {
        guard let syncState = try? storage.syncState.get() else { return }
        var request = Im_Version()
        request.version = syncState.friendRequestHead
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .frp, body: body)
    }

    /// Fire-and-forget: the server marks requests read and pushes the new
    /// head back via the same `.frn` notify `FriendRequestSyncHandler`
    /// already handles, so no completion/tracker is needed here.
    public func markFriendRequestsAsRead() {
        var request = Im_Version()
        request.version = Int64(Date().timeIntervalSince1970 * 1000)
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .frus, body: body)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ContactSyncServiceTests`
Expected: PASS (all old and new tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/IMContacts/ContactSyncService.swift Tests/IMContactsTests/ContactSyncServiceTests.swift
git commit -m "feat(contacts): extend ContactSyncService with search/request/sync/read"
```

---

## Task 9: IMKit protocols — `UserSearching`, `FriendRequestSending`, `FriendRequestSyncing`

**Files:**
- Create: `Sources/IMKit/UserSearching.swift`
- Create: `Sources/IMKit/FriendRequestSending.swift`
- Create: `Sources/IMKit/FriendRequestSyncing.swift`

No tests in this task — these are pure protocol declarations with a same-file conformance extension, exactly mirroring `Sources/IMKit/ImageUploading.swift`'s established idiom (one narrow protocol + `extension ContactSyncService: ThatProtocol {}` per file, rather than the spec's single combined `extension ContactSyncService: UserSearching, FriendRequestSending, FriendRequestSyncing {}` statement — functionally identical, just split to match this codebase's one-protocol-per-file convention). There is nothing here to unit test beyond what Task 8's `ContactSyncServiceTests` already covers; conformance itself is checked at compile time.

- [ ] **Step 1: Create `UserSearching.swift`**

```swift
// Sources/IMKit/UserSearching.swift
import IMContacts

/// Narrow interface `SearchUserViewModel` depends on instead of the
/// concrete `ContactSyncService` — same decoupling-for-testability pattern
/// as `ImageUploading`/`ContactInfoFetching`.
public protocol UserSearching: AnyObject {
    func searchUser(keyword: String, completion: @escaping (Result<[String], Error>) -> Void)
}

extension ContactSyncService: UserSearching {}
```

- [ ] **Step 2: Create `FriendRequestSending.swift`**

```swift
// Sources/IMKit/FriendRequestSending.swift
import IMContacts

/// Narrow interface `SearchUserViewModel`/`NewFriendsViewModel` depend on
/// instead of the concrete `ContactSyncService` — same decoupling pattern
/// as `ImageUploading`/`ContactInfoFetching`.
public protocol FriendRequestSending: AnyObject {
    func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void)
    func acceptFriendRequest(from uid: String, completion: @escaping (Result<Void, Error>) -> Void)
}

extension ContactSyncService: FriendRequestSending {}
```

- [ ] **Step 3: Create `FriendRequestSyncing.swift`**

```swift
// Sources/IMKit/FriendRequestSyncing.swift
import IMContacts

/// Narrow interface `NewFriendsViewModel` depends on instead of the
/// concrete `ContactSyncService` — same decoupling pattern as
/// `ImageUploading`/`ContactInfoFetching`.
public protocol FriendRequestSyncing: AnyObject {
    func syncFriendRequests()
    func markFriendRequestsAsRead()
}

extension ContactSyncService: FriendRequestSyncing {}
```

- [ ] **Step 4: Build to verify conformance compiles**

Run: `swift build`
Expected: builds cleanly — `ContactSyncService` already implements every method each protocol requires (Task 8), so these are compile-time-only conformance declarations.

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/UserSearching.swift Sources/IMKit/FriendRequestSending.swift Sources/IMKit/FriendRequestSyncing.swift
git commit -m "feat(kit): add UserSearching/FriendRequestSending/FriendRequestSyncing protocols"
```

---

## Task 10: `SearchUserViewModel`

**Files:**
- Create: `Sources/IMKit/SearchUserViewModel.swift`
- Test: `Tests/IMKitTests/SearchUserViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMKitTests/SearchUserViewModelTests.swift
import XCTest
import IMStorage
@testable import IMKit

private final class FakeUserSearching: UserSearching {
    var lastKeyword: String?
    var stubbedResult: Result<[String], Error> = .success([])

    func searchUser(keyword: String, completion: @escaping (Result<[String], Error>) -> Void) {
        lastKeyword = keyword
        completion(stubbedResult)
    }
}

private final class FakeFriendRequestSending: FriendRequestSending {
    var lastSendArgs: (uid: String, reason: String)?
    var stubbedSendResult: Result<Void, Error> = .success(())

    func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lastSendArgs = (uid, reason)
        completion(stubbedSendResult)
    }

    func acceptFriendRequest(from uid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}

final class SearchUserViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var userSearching: FakeUserSearching!
    private var friendRequestSending: FakeFriendRequestSending!
    private var viewModel: SearchUserViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        userSearching = FakeUserSearching()
        friendRequestSending = FakeFriendRequestSending()
        viewModel = SearchUserViewModel(userSearching: userSearching, friendRequestSending: friendRequestSending, storage: storage)
    }

    func test_search_emptyKeyword_clearsResultsWithoutSendingRequest() {
        userSearching.stubbedResult = .success(["u1"])
        viewModel.search(keyword: "alice") // populate results first
        XCTAssertFalse(viewModel.results.isEmpty)

        userSearching.lastKeyword = nil
        viewModel.search(keyword: "")

        XCTAssertNil(userSearching.lastKeyword, "empty keyword must not call through to searchUser")
        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func test_search_withResults_mapsMatchedUidsToContactRowsUsingCachedProfile() throws {
        try storage.users.upsertProfile(uid: "u1", name: nil, displayName: "Alice", portrait: "https://example.com/a.png", mobile: nil, gender: 0, updateDt: 0)
        userSearching.stubbedResult = .success(["u1"])

        viewModel.search(keyword: "alice")

        XCTAssertEqual(viewModel.results.count, 1)
        XCTAssertEqual(viewModel.results.first?.uid, "u1")
        XCTAssertEqual(viewModel.results.first?.displayName, "Alice")
        XCTAssertEqual(viewModel.results.first?.avatarURL, "https://example.com/a.png")
        XCTAssertEqual(viewModel.results.first?.sectionLetter, "")
    }

    func test_search_unresolvedUid_fallsBackToUidForDisplayName() throws {
        userSearching.stubbedResult = .success(["zz9"])

        viewModel.search(keyword: "zz9")

        XCTAssertEqual(viewModel.results.first?.displayName, "zz9")
    }

    func test_search_failure_clearsResults() {
        userSearching.stubbedResult = .failure(NSError(domain: "test", code: 1))

        viewModel.search(keyword: "alice")

        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func test_sendFriendRequest_delegatesToFriendRequestSending() {
        var captured: Result<Void, Error>?
        viewModel.sendFriendRequest(to: "u1", reason: "hi") { result in captured = result }

        XCTAssertEqual(friendRequestSending.lastSendArgs?.uid, "u1")
        XCTAssertEqual(friendRequestSending.lastSendArgs?.reason, "hi")
        switch captured {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SearchUserViewModelTests`
Expected: FAIL (no such module member `SearchUserViewModel`)

- [ ] **Step 3: Create `SearchUserViewModel.swift`**

```swift
// Sources/IMKit/SearchUserViewModel.swift
import Foundation
import IMStorage

/// Drives the "search for a user, then send them a friend request" screen.
/// `search(keyword:)` maps the matched uid list to `ContactRow`s by reading
/// `IMStorage.UserStore` directly — `UserSearching`'s implementation
/// (`ContactSyncService`) already wrote each matched profile into
/// `UserStore` before this view model ever sees the uid list.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class SearchUserViewModel {
    @Published public private(set) var results: [ContactRow] = []

    private let userSearching: UserSearching?
    private let friendRequestSending: FriendRequestSending?
    private let storage: IMStorage

    public init(userSearching: UserSearching?, friendRequestSending: FriendRequestSending?, storage: IMStorage) {
        self.userSearching = userSearching
        self.friendRequestSending = friendRequestSending
        self.storage = storage
    }

    /// An empty keyword clears `results` without sending a request — the
    /// caller (debounced in `SearchUserViewController`) is expected to
    /// call this on every text change, including when the user has
    /// cleared the search bar entirely.
    public func search(keyword: String) {
        guard !keyword.isEmpty else {
            results = []
            return
        }
        userSearching?.searchUser(keyword: keyword) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let uids):
                self.results = uids.map { uid in
                    let user = try? self.storage.users.user(uid: uid)
                    let displayName = user?.displayName ?? user?.name ?? uid
                    return ContactRow(uid: uid, displayName: displayName, avatarURL: user?.portrait, sectionLetter: "")
                }
            case .failure:
                self.results = []
            }
        }
    }

    public func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        friendRequestSending?.sendFriendRequest(to: uid, reason: reason, completion: completion)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SearchUserViewModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/SearchUserViewModel.swift Tests/IMKitTests/SearchUserViewModelTests.swift
git commit -m "feat(kit): add SearchUserViewModel"
```

---

## Task 11: `NewFriendsViewModel`

**Files:**
- Create: `Sources/IMKit/NewFriendsViewModel.swift`
- Test: `Tests/IMKitTests/NewFriendsViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMKitTests/NewFriendsViewModelTests.swift
import XCTest
import Combine
import IMStorage
@testable import IMKit

private final class FakeFriendRequestSyncing: FriendRequestSyncing {
    var syncFriendRequestsCallCount = 0
    var markFriendRequestsAsReadCallCount = 0

    func syncFriendRequests() { syncFriendRequestsCallCount += 1 }
    func markFriendRequestsAsRead() { markFriendRequestsAsReadCallCount += 1 }
}

private final class FakeFriendRequestSending: FriendRequestSending {
    var lastAcceptedUid: String?
    var stubbedAcceptResult: Result<Void, Error> = .success(())

    func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func acceptFriendRequest(from uid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lastAcceptedUid = uid
        completion(stubbedAcceptResult)
    }
}

final class NewFriendsViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var syncing: FakeFriendRequestSyncing!
    private var sending: FakeFriendRequestSending!
    private var viewModel: NewFriendsViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        syncing = FakeFriendRequestSyncing()
        sending = FakeFriendRequestSending()
        viewModel = NewFriendsViewModel(friendRequestSyncing: syncing, friendRequestSending: sending, storage: storage)
    }

    private func waitForNonEmptyRows() {
        guard viewModel.rows.isEmpty else { return }
        let expectation = expectation(description: "rows appear")
        expectation.assertForOverFulfill = false
        viewModel.$rows.dropFirst().sink { rows in if !rows.isEmpty { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    func test_initialState_emptyRows() {
        XCTAssertTrue(viewModel.rows.isEmpty)
    }

    func test_incomingRequest_mapsToRowWithResolvedProfile() throws {
        try storage.users.upsertProfile(uid: "u1", name: nil, displayName: "Alice", portrait: "https://example.com/a.png", mobile: nil, gender: 0, updateDt: 0)
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        waitForNonEmptyRows()

        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(row.fromUid, "u1")
        XCTAssertEqual(row.displayName, "Alice")
        XCTAssertEqual(row.avatarURL, "https://example.com/a.png")
        XCTAssertEqual(row.reason, "hi")
        XCTAssertFalse(row.isAccepted)
    }

    func test_incomingRequest_unresolvedProfile_fallsBackToUidForDisplayName() throws {
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "zz9", toUid: "me", reason: "", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        waitForNonEmptyRows()

        XCTAssertEqual(viewModel.rows.first?.displayName, "zz9")
    }

    func test_acceptedRequest_mapsToRowWithIsAcceptedTrue() throws {
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "", status: StoredFriendRequest.Status.accepted, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        waitForNonEmptyRows()

        XCTAssertTrue(viewModel.rows.first?.isAccepted ?? false)
    }

    func test_refresh_callsSyncFriendRequestsAndMarkFriendRequestsAsRead() {
        viewModel.refresh()

        XCTAssertEqual(syncing.syncFriendRequestsCallCount, 1)
        XCTAssertEqual(syncing.markFriendRequestsAsReadCallCount, 1)
    }

    func test_accept_delegatesToFriendRequestSending() {
        viewModel.accept(fromUid: "u1")

        XCTAssertEqual(sending.lastAcceptedUid, "u1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NewFriendsViewModelTests`
Expected: FAIL (no such module member `NewFriendsViewModel`)

- [ ] **Step 3: Create `NewFriendsViewModel.swift`**

```swift
// Sources/IMKit/NewFriendsViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the "新的朋友" page: a list of incoming friend requests, each
/// with an accept button (no reject, no delete-friend, no alias — out of
/// scope per Plan K's spec).
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class NewFriendsViewModel {
    public struct FriendRequestRow: Equatable, Hashable {
        public let fromUid: String
        public let displayName: String
        public let avatarURL: String?
        public let reason: String
        public let isAccepted: Bool
    }

    @Published public private(set) var rows: [FriendRequestRow] = []

    private let friendRequestSyncing: FriendRequestSyncing?
    private let friendRequestSending: FriendRequestSending?
    private let storage: IMStorage
    private var cancellable: AnyCancellable?

    public init(friendRequestSyncing: FriendRequestSyncing?, friendRequestSending: FriendRequestSending?, storage: IMStorage) {
        self.friendRequestSyncing = friendRequestSyncing
        self.friendRequestSending = friendRequestSending
        self.storage = storage

        cancellable = storage.friendRequests.incomingRequestsPublisher()
            .replaceError(with: [])
            .sink { [weak self] requests in self?.handleRequestsUpdate(requests) }
    }

    private func handleRequestsUpdate(_ requests: [StoredFriendRequest]) {
        rows = requests.map { request in
            let user = try? storage.users.user(uid: request.fromUid)
            let displayName = user?.displayName ?? user?.name ?? request.fromUid
            return FriendRequestRow(
                fromUid: request.fromUid,
                displayName: displayName,
                avatarURL: user?.portrait,
                reason: request.reason,
                isAccepted: request.status == StoredFriendRequest.Status.accepted
            )
        }
    }

    /// Call when the page appears: pulls the latest requests, then marks
    /// them read so the unread badge clears.
    public func refresh() {
        friendRequestSyncing?.syncFriendRequests()
        friendRequestSyncing?.markFriendRequestsAsRead()
    }

    public func accept(fromUid: String) {
        friendRequestSending?.acceptFriendRequest(from: fromUid) { _ in }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NewFriendsViewModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/NewFriendsViewModel.swift Tests/IMKitTests/NewFriendsViewModelTests.swift
git commit -m "feat(kit): add NewFriendsViewModel"
```

---

## Task 12: `ContactListViewModel.unreadFriendRequestCount`

**Files:**
- Modify: `Sources/IMKit/ContactListViewModel.swift`
- Modify: `Tests/IMKitTests/ContactListViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/IMKitTests/ContactListViewModelTests.swift` (after `test_nonLetterName_groupedUnderHash`):

```swift
    func test_unreadFriendRequestCount_reflectsUnreadIncomingRequests() throws {
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        let expectation = expectation(description: "count settles at 1")
        expectation.assertForOverFulfill = false
        viewModel.$unreadFriendRequestCount.sink { count in if count == 1 { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ContactListViewModelTests/test_unreadFriendRequestCount_reflectsUnreadIncomingRequests`
Expected: FAIL (no member `unreadFriendRequestCount`)

- [ ] **Step 3: Modify `ContactListViewModel.swift`**

Replace the whole file with:

```swift
import Foundation
import Combine
import IMStorage

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ContactListViewModel {
    @Published public private(set) var sections: [(letter: String, rows: [ContactRow])] = []
    @Published public private(set) var unreadFriendRequestCount: Int = 0

    private let storage: IMStorage
    private var cancellable: AnyCancellable?
    private var friendRequestCountCancellable: AnyCancellable?

    public init(storage: IMStorage) {
        self.storage = storage
        cancellable = storage.users.friendsPublisher()
            .replaceError(with: [])
            .sink { [weak self] users in self?.handleFriendsUpdate(users) }
        friendRequestCountCancellable = storage.friendRequests.unreadIncomingCountPublisher()
            .replaceError(with: 0)
            .sink { [weak self] count in self?.unreadFriendRequestCount = count }
    }

    private func handleFriendsUpdate(_ users: [StoredUser]) {
        let rows = users.map { user -> ContactRow in
            let displayName = user.displayName ?? user.name ?? user.uid
            return ContactRow(
                uid: user.uid,
                displayName: displayName,
                avatarURL: user.portrait,
                sectionLetter: PinyinIndexer.sectionLetter(for: displayName)
            )
        }

        let grouped = Dictionary(grouping: rows, by: { $0.sectionLetter })
        let sortedLetters = grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        sections = sortedLetters.map { letter in
            let sortedRows = grouped[letter]!.sorted { PinyinIndexer.sortKey(for: $0.displayName) < PinyinIndexer.sortKey(for: $1.displayName) }
            return (letter: letter, rows: sortedRows)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ContactListViewModelTests`
Expected: PASS (all old and new tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/ContactListViewModel.swift Tests/IMKitTests/ContactListViewModelTests.swift
git commit -m "feat(kit): add unreadFriendRequestCount to ContactListViewModel"
```

---

## Task 13: Wire `syncFriendRequests()` into `AppEnvironment.connectIfPossible()`

**Files:**
- Modify: `Sources/AppCore/AppEnvironment.swift`
- Test: `Tests/AppCoreTests/AppEnvironmentTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/AppCoreTests/AppEnvironmentTests.swift` (after `test_connectIfPossible_withCredentials_alsoTriggersAFriendListSync`):

```swift
    func test_connectIfPossible_withCredentials_alsoTriggersAFriendRequestSync() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))

        XCTAssertTrue(environment.connectIfPossible())

        var payload = Im_ConnectAckPayload()
        payload.msgHead = 0
        payload.friendHead = 0
        payload.friendRqHead = 0
        payload.settingHead = 0
        payload.serverTime = 0
        let body = try payload.serializedData()
        let frameBytes = FrameEncoder.encode(signal: .connectAck, subSignal: .none, messageId: 1, body: body)
        fakeTransport.simulateReceivedData(frameBytes)

        let sentSignals = fakeTransport.sentFrames.compactMap { try? FrameDecoder().feed($0).first?.header.subSignal }
        XCTAssertTrue(sentSignals.contains(.frp))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppEnvironmentTests/test_connectIfPossible_withCredentials_alsoTriggersAFriendRequestSync`
Expected: FAIL (`sentSignals` does not contain `.frp`)

- [ ] **Step 3: Modify `AppEnvironment.swift`**

In `Sources/AppCore/AppEnvironment.swift`, change:

```swift
        connectAckHandler.onSyncState = { [weak service, weak contactSync] syncState in
            service?.pullMessagesSinceLastSync(syncState: syncState)
            contactSync?.syncFriendList()
        }
```

to:

```swift
        connectAckHandler.onSyncState = { [weak service, weak contactSync] syncState in
            service?.pullMessagesSinceLastSync(syncState: syncState)
            contactSync?.syncFriendList()
            contactSync?.syncFriendRequests()
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppEnvironmentTests`
Expected: PASS (all old and new tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AppCore/AppEnvironment.swift Tests/AppCoreTests/AppEnvironmentTests.swift
git commit -m "feat(appcore): trigger friend request sync on connect"
```

---

## Task 14: `NewFriendsEntryView` + wire into `ContactListViewController`

**Files:**
- Create: `App/NewFriendsEntryView.swift`
- Modify: `App/ContactListViewController.swift`

The `App` target has no XCTest target (confirmed: no `AppTests` directory, no SPM test entry for `App` in `Package.swift` — it's an Xcode-only UI target, same as every other App-layer file in this codebase). This task is verified by Task 17's final `xcodebuild` build and a manual run in the simulator, matching the existing pattern for `ContactListViewController`/`ConversationListViewController` etc.

- [ ] **Step 1: Create `NewFriendsEntryView.swift`**

```swift
// App/NewFriendsEntryView.swift
import UIKit

/// The "新的朋友" row pinned above the A-Z contact list, WeChat-style:
/// icon + title + unread-count badge + chevron. Used as
/// `ContactListViewController`'s `tableView.tableHeaderView`, which (unlike
/// a normal Auto-Layout-managed view) UIKit only sizes from its explicit
/// `frame` — `ContactListViewController.viewDidLayoutSubviews()` re-sets
/// that frame on every layout pass to track the table's current width.
final class NewFriendsEntryView: UIView {
    var onTapped: (() -> Void)?

    private let iconBackgroundView = UIView()
    private let iconImageView = UIImageView(image: UIImage(systemName: "person.badge.plus"))
    private let titleLabel = UILabel()
    private let badgeLabel = UILabel()
    private let chevronImageView = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        iconBackgroundView.backgroundColor = Theme.accent
        iconBackgroundView.layer.cornerRadius = 8
        iconBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        iconImageView.tintColor = Theme.textOnAccent
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "新的朋友"
        titleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        badgeLabel.textColor = Theme.textOnAccent
        badgeLabel.backgroundColor = Theme.accent
        badgeLabel.textAlignment = .center
        badgeLabel.layer.cornerRadius = 9
        badgeLabel.layer.masksToBounds = true
        badgeLabel.isHidden = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        chevronImageView.tintColor = Theme.backgroundTertiary
        chevronImageView.contentMode = .scaleAspectFit
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconImageView)
        addSubview(titleLabel)
        addSubview(badgeLabel)
        addSubview(chevronImageView)

        NSLayoutConstraint.activate([
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 32),
            iconBackgroundView.heightAnchor.constraint(equalToConstant: 32),
            iconBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconBackgroundView.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 18),
            iconImageView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronImageView.widthAnchor.constraint(equalToConstant: 12),
            chevronImageView.heightAnchor.constraint(equalToConstant: 12),

            badgeLabel.trailingAnchor.constraint(equalTo: chevronImageView.leadingAnchor, constant: -8),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.heightAnchor.constraint(equalToConstant: 18),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
    }

    func setUnreadCount(_ count: Int) {
        badgeLabel.isHidden = count <= 0
        badgeLabel.text = count > 99 ? "99+" : "\(count)"
    }

    @objc private func handleTap() {
        onTapped?()
    }
}
```

- [ ] **Step 2: Modify `ContactListViewController.swift`**

Change:

```swift
final class ContactListViewController: UIViewController {
    private let viewModel: ContactListViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: ContactListDataSource!

    private let tableView = UITableView()

    /// Set by `SceneDelegate` — pushes the chat screen for the tapped contact.
    var onContactSelected: ((ContactRow) -> Void)?

    init(viewModel: ContactListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "联系人"
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
        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.sectionIndexColor = Theme.accent
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
```

to:

```swift
final class ContactListViewController: UIViewController {
    private let viewModel: ContactListViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: ContactListDataSource!

    private let tableView = UITableView()
    private let newFriendsEntryView = NewFriendsEntryView()

    /// Set by `SceneDelegate` — pushes the chat screen for the tapped contact.
    var onContactSelected: ((ContactRow) -> Void)?
    /// Set by `SceneDelegate` — pushes `NewFriendsViewController`.
    var onNewFriendsEntryTapped: (() -> Void)?

    init(viewModel: ContactListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "联系人"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutTableView()
        configureDataSource()
        bindViewModel()
        newFriendsEntryView.onTapped = { [weak self] in self?.onNewFriendsEntryTapped?() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        newFriendsEntryView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 56)
        tableView.tableHeaderView = newFriendsEntryView
    }

    private func layoutTableView() {
        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.sectionIndexColor = Theme.accent
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
```

Then change `bindViewModel()`:

```swift
    private func bindViewModel() {
        viewModel.$sections
            .sink { [weak self] sections in self?.applySnapshot(sections: sections) }
            .store(in: &cancellables)
    }
```

to:

```swift
    private func bindViewModel() {
        viewModel.$sections
            .sink { [weak self] sections in self?.applySnapshot(sections: sections) }
            .store(in: &cancellables)
        viewModel.$unreadFriendRequestCount
            .sink { [weak self] count in self?.newFriendsEntryView.setUnreadCount(count) }
            .store(in: &cancellables)
    }
```

`ContactListDataSource` and the `UITableViewDelegate` extension at the bottom of the file are unchanged.

- [ ] **Step 3: Commit**

```bash
git add App/NewFriendsEntryView.swift App/ContactListViewController.swift
git commit -m "feat(app): add NewFriendsEntryView header to contact list"
```

---

## Task 15: `FriendRequestCell` + `NewFriendsViewController`

**Files:**
- Create: `App/FriendRequestCell.swift`
- Create: `App/NewFriendsViewController.swift`

No XCTest target for `App` (see Task 14's note) — verified by Task 17's `xcodebuild` build and a manual simulator run.

- [ ] **Step 1: Create `FriendRequestCell.swift`**

```swift
// App/FriendRequestCell.swift
import UIKit
import IMKit

final class FriendRequestCell: UITableViewCell {
    static let reuseIdentifier = "FriendRequestCell"

    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()
    private let reasonLabel = UILabel()
    private let acceptButton = UIButton(type: .system)

    var onAcceptTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 16, weight: .regular)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        reasonLabel.font = .systemFont(ofSize: 13, weight: .regular)
        reasonLabel.textColor = .secondaryLabel
        reasonLabel.translatesAutoresizingMaskIntoConstraints = false

        acceptButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        acceptButton.addTarget(self, action: #selector(handleAcceptTapped), for: .touchUpInside)
        acceptButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarImageView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(reasonLabel)
        contentView.addSubview(acceptButton)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 40),
            avatarImageView.heightAnchor.constraint(equalToConstant: 40),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            avatarImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            acceptButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            acceptButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: acceptButton.leadingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: avatarImageView.topAnchor),

            reasonLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            reasonLabel.trailingAnchor.constraint(lessThanOrEqualTo: acceptButton.leadingAnchor, constant: -8),
            reasonLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
        ])
    }

    func configure(with row: NewFriendsViewModel.FriendRequestRow) {
        avatarImageView.setAvatar(urlString: row.avatarURL, displayName: row.displayName)
        nameLabel.text = row.displayName
        reasonLabel.text = row.reason.isEmpty ? "请求添加你为朋友" : row.reason
        if row.isAccepted {
            acceptButton.setTitle("已添加", for: .normal)
            acceptButton.isEnabled = false
            acceptButton.setTitleColor(.secondaryLabel, for: .normal)
        } else {
            acceptButton.setTitle("接受", for: .normal)
            acceptButton.isEnabled = true
            acceptButton.setTitleColor(Theme.accent, for: .normal)
        }
    }

    @objc private func handleAcceptTapped() {
        onAcceptTapped?()
    }
}
```

- [ ] **Step 2: Create `NewFriendsViewController.swift`**

```swift
// App/NewFriendsViewController.swift
import UIKit
import Combine
import IMKit

final class NewFriendsViewController: UIViewController {
    private let viewModel: NewFriendsViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, NewFriendsViewModel.FriendRequestRow>!

    private let tableView = UITableView()

    /// Set by `SceneDelegate` — pushes `SearchUserViewController`.
    var onAddFriendTapped: (() -> Void)?

    init(viewModel: NewFriendsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "新的朋友"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(handleAddTapped))
        layoutTableView()
        configureDataSource()
        bindViewModel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.refresh()
    }

    private func layoutTableView() {
        tableView.register(FriendRequestCell.self, forCellReuseIdentifier: FriendRequestCell.reuseIdentifier)
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
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: FriendRequestCell.reuseIdentifier, for: indexPath) as! FriendRequestCell
            cell.configure(with: row)
            cell.onAcceptTapped = { self?.viewModel.accept(fromUid: row.fromUid) }
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$rows
            .sink { [weak self] rows in self?.applySnapshot(rows: rows) }
            .store(in: &cancellables)
    }

    private func applySnapshot(rows: [NewFriendsViewModel.FriendRequestRow]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, NewFriendsViewModel.FriendRequestRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @objc private func handleAddTapped() {
        onAddFriendTapped?()
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add App/FriendRequestCell.swift App/NewFriendsViewController.swift
git commit -m "feat(app): add FriendRequestCell and NewFriendsViewController"
```

---

## Task 16: `SearchUserViewController`

**Files:**
- Create: `App/SearchUserViewController.swift`

Reuses `ContactListCell` (`App/ContactListCell.swift`) for result rows — it already has `configure(with row: ContactRow)`. No automated test target for `App` (see Task 14's note); verified by Task 17's `xcodebuild` build and a manual simulator run.

- [ ] **Step 1: Create `SearchUserViewController.swift`**

```swift
// App/SearchUserViewController.swift
import UIKit
import Combine
import IMKit

final class SearchUserViewController: UIViewController {
    private let viewModel: SearchUserViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, ContactRow>!
    private var searchGeneration = 0

    private let searchBar = UISearchBar()
    private let tableView = UITableView()

    init(viewModel: SearchUserViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "添加朋友"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        configureDataSource()
        bindViewModel()
    }

    private func layoutViews() {
        searchBar.placeholder = "搜索 UID 或手机号"
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false

        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchBar)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: row)
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$results
            .sink { [weak self] results in self?.applySnapshot(results: results) }
            .store(in: &cancellables)
    }

    private func applySnapshot(results: [ContactRow]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ContactRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(results, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func presentReasonPrompt(for row: ContactRow) {
        let alert = UIAlertController(title: "添加朋友", message: "向 \(row.displayName) 发送好友请求", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "验证消息（可选）"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "发送", style: .default) { [weak self, weak alert] _ in
            let reason = alert?.textFields?.first?.text ?? ""
            self?.sendFriendRequest(to: row.uid, reason: reason)
        })
        present(alert, animated: true)
    }

    private func sendFriendRequest(to uid: String, reason: String) {
        viewModel.sendFriendRequest(to: uid, reason: reason) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.presentResultAlert(title: "已发送", message: "好友请求已发送", dismissAfter: true)
                case .failure:
                    self?.presentResultAlert(title: "发送失败", message: "请稍后重试", dismissAfter: false)
                }
            }
        }
    }

    private func presentResultAlert(title: String, message: String, dismissAfter: Bool) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            if dismissAfter { self?.navigationController?.popViewController(animated: true) }
        })
        present(alert, animated: true)
    }
}

extension SearchUserViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchGeneration += 1
        let generation = searchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.searchGeneration == generation else { return }
            self.viewModel.search(keyword: searchText)
        }
    }
}

extension SearchUserViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        presentReasonPrompt(for: row)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add App/SearchUserViewController.swift
git commit -m "feat(app): add SearchUserViewController"
```

---

## Task 17: Wire `SceneDelegate` + final verification

**Files:**
- Modify: `App/SceneDelegate.swift` (full current content shown below; `makeContactListNavigationController()` now takes the already-constructed `ContactListViewModel` as a parameter so `makeMainTabBarController()` can subscribe to its badge count *after* assigning the real `tabBarItem` — add an `import Combine` + a `cancellables` property)

This is the final integration task: tapping "新的朋友" pushes `NewFriendsViewController`; its "+" button pushes `SearchUserViewController`; the contacts tab's badge reflects `ContactListViewModel.unreadFriendRequestCount`. The badge subscription must be set up *after* `contactListNav.tabBarItem` is assigned a real `UITabBarItem` — subscribing before that point would write the first (always-zero) emission onto a throwaway default `tabBarItem` that gets immediately discarded when the caller assigns the real one. No automated test target for `App` — verified by `swift test` (all package targets) followed by an `xcodebuild` build.

- [ ] **Step 1: Modify `App/SceneDelegate.swift`**

Replace the file's full contents with:

```swift
// App/SceneDelegate.swift
import UIKit
import Combine
import AppCore
import IMStorage
import IMKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var environment: AppEnvironment!
    private var cancellables = Set<AnyCancellable>()

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
        environment.connectIfPossible() ? makeMainTabBarController() : makeLoginViewController()
    }

    /// Two tabs: conversations (default landing tab) and contacts. Both are
    /// independent `UINavigationController`s, matching the standard
    /// WeChat-style IM navigation shape — a later phase adding a third
    /// "我的" tab is a purely additive change here.
    private func makeMainTabBarController() -> UIViewController {
        let tabBarController = UITabBarController()

        let conversationListNav = makeConversationListNavigationController()
        conversationListNav.tabBarItem = UITabBarItem(title: "消息", image: UIImage(systemName: "message"), tag: 0)

        let contactListViewModel = ContactListViewModel(storage: environment.storage)
        let contactListNav = makeContactListNavigationController(viewModel: contactListViewModel)
        contactListNav.tabBarItem = UITabBarItem(title: "联系人", image: UIImage(systemName: "person.2"), tag: 1)
        contactListViewModel.$unreadFriendRequestCount
            .sink { [weak contactListNav] count in
                contactListNav?.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil
            }
            .store(in: &cancellables)

        tabBarController.viewControllers = [conversationListNav, contactListNav]
        return tabBarController
    }

    private func makeConversationListNavigationController() -> UIViewController {
        let viewModel = ConversationListViewModel(storage: environment.storage, contactSync: environment.contactSyncService)
        let listViewController = ConversationListViewController(viewModel: viewModel)
        listViewController.onConversationSelected = { [weak self, weak listViewController] row in
            guard let self else { return }
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
                target: row.target,
                conversationType: row.conversationType,
                line: row.line
            )
            listViewController?.navigationController?.pushViewController(
                ConversationViewController(row: row, viewModel: conversationViewModel),
                animated: true
            )
        }
        return UINavigationController(rootViewController: listViewController)
    }

    /// `ConversationViewController` requires a `ConversationRow` purely for
    /// its nav-bar title/avatar — it has no backing `StoredConversation` row
    /// yet the first time you message a brand-new contact (one gets created
    /// automatically by `MessagingService.sendText`'s first send). The
    /// placeholder fields below (`previewText`/`timestamp`/etc.) are never
    /// read by `ConversationViewController`, which only uses `displayName`
    /// for its title.
    ///
    /// Takes `viewModel` as a parameter (rather than constructing it
    /// internally) so `makeMainTabBarController()` can subscribe to
    /// `viewModel.$unreadFriendRequestCount` for the tab bar badge after
    /// this method returns and the real `tabBarItem` has been assigned.
    private func makeContactListNavigationController(viewModel: ContactListViewModel) -> UINavigationController {
        let listViewController = ContactListViewController(viewModel: viewModel)
        listViewController.onContactSelected = { [weak self, weak listViewController] row in
            guard let self else { return }
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
                target: row.uid,
                conversationType: .single,
                line: 0
            )
            let conversationRow = ConversationRow(
                conversationType: .single,
                target: row.uid,
                line: 0,
                displayName: row.displayName,
                avatarURL: row.avatarURL,
                previewText: "",
                timestamp: 0,
                unreadCount: 0,
                isTop: false,
                isMuted: false,
                lastMessageStatus: nil
            )
            listViewController?.navigationController?.pushViewController(
                ConversationViewController(row: conversationRow, viewModel: conversationViewModel),
                animated: true
            )
        }
        listViewController.onNewFriendsEntryTapped = { [weak self, weak listViewController] in
            guard let self else { return }
            let newFriendsViewModel = NewFriendsViewModel(
                friendRequestSyncing: self.environment.contactSyncService,
                friendRequestSending: self.environment.contactSyncService,
                storage: self.environment.storage
            )
            let newFriendsViewController = NewFriendsViewController(viewModel: newFriendsViewModel)
            newFriendsViewController.onAddFriendTapped = { [weak self, weak newFriendsViewController] in
                guard let self else { return }
                let searchUserViewModel = SearchUserViewModel(
                    userSearching: self.environment.contactSyncService,
                    friendRequestSending: self.environment.contactSyncService,
                    storage: self.environment.storage
                )
                let searchUserViewController = SearchUserViewController(viewModel: searchUserViewModel)
                newFriendsViewController?.navigationController?.pushViewController(searchUserViewController, animated: true)
            }
            listViewController?.navigationController?.pushViewController(newFriendsViewController, animated: true)
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
            self.window?.rootViewController = self.makeMainTabBarController()
        }
        return LoginViewController(viewModel: viewModel)
    }
}
```

- [ ] **Step 2: Run the full package test suite**

Run: `swift test`
Expected: all tests pass, including every new test file from Tasks 1–13 (`StoredFriendRequestTests`, `FriendRequestStoreTests`, `UserSearchTrackerTests`, `FriendRequestActionTrackerTests`, `UserSearchHandlerTests`, `FriendRequestActionHandlerTests`, `FriendRequestSyncHandlerTests`, the extended `ContactSyncServiceTests`, `SearchUserViewModelTests`, `NewFriendsViewModelTests`, the extended `ContactListViewModelTests`, the extended `AppEnvironmentTests`).

- [ ] **Step 3: Build the App target for the simulator**

Run: `xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual simulator smoke test**

Launch the built app in the iPhone 15 simulator and walk through:
1. Contacts tab shows the "新的朋友" header row above the alphabetical sections.
2. Tap it → `NewFriendsViewController` pushes with title "新的朋友" and a "+" button.
3. Tap "+" → `SearchUserViewController` pushes with a search bar.
4. Type a UID/mobile → after ~300ms a matching row appears (requires a real server connection — if unavailable, confirm no crash and an empty list).
5. Tap a result row → reason-prompt alert appears; tapping "发送" pops back with a success alert.
6. (Server-dependent) From a second account, accept the request → contacts tab badge increments; "新的朋友" list shows the pending row with an enabled "接受" button; tapping it marks it "已添加" and the friend appears in the contacts list.

- [ ] **Step 5: Commit**

```bash
git add App/SceneDelegate.swift
git commit -m "feat(app): wire NewFriendsViewController and SearchUserViewController into navigation"
```

---
