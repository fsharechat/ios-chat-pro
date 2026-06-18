# Phase 1 / Plan F: Contact/Friend Sync Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the contact/friend-list sync protocol layer — pulling the user's friend UID list and resolving display profiles (name/portrait) — so Plan G's contact list and conversation/message-sender display can read real data out of `IMStorage` instead of an empty `user` table.

**Architecture:** A new `IMContacts` SwiftPM target (parallel to `IMMessaging`, depending on the same `IMClient`/`IMStorage`/`IMProto`/`IMTransport` quartet) holds two `MessageHandler`s — `FriendSyncHandler` (`PUB_ACK`/`FP`, the friend-UID-list pull result) and `UserInfoSyncHandler` (`PUB_ACK`/`UPUI`, the bulk user-profile pull result) — plus a `ContactSyncService` facade that registers both handlers and exposes `syncFriendList()`/`fetchUserInfo(uids:forceRefresh:)`. `AppEnvironment` (Plan E) constructs one alongside `MessagingService` and triggers `syncFriendList()` from the same `ConnectAckHandler.onSyncState` hook already used to kick off message catch-up — mirroring Android's `ConnectAckMessageHandler`, which calls `getMyFriendList(true)` and `pullMessage(...)` from the same post-CONNECT_ACK callback. `IMStorage.UserStore` (already built in Plan C, currently unused by anything) gains an `isFriend` column and a few new methods; everything else it needs already exists.

**Tech Stack:** Builds entirely on existing Plan A–E targets — no new external dependencies, no schema changes beyond one additive GRDB migration.

---

**Reference facts this plan is built from** (verified by reading the actual Android client, the real chat-server-pro server source, and the real generated `WFCMessage.pb.swift` — not assumed):

- **Wire format, verified server-side** (`chat-server-pro`'s `IMHandler.java` base class, the same file that revealed the `ReceiveMessageHandler` bug just fixed on `main`): every `PUB_ACK` response body is "1 byte error code, then the payload" — universal, not `SubSignal`-specific. Both `FP` and `UPUI` responses follow this, confirmed against the server's `FriendRequestPullHandler`/equivalent handlers. `FriendSyncHandler`/`UserInfoSyncHandler` must read and skip this byte the same way the just-fixed `ReceiveMessageHandler` and the already-correct `MessageSendAckHandler` do — non-zero error code means no parse attempt, matching Android's `errorCode == 0` gate.
- **Friend-list pull** (`ProtoService.getMyFriendList`, `FriendPullHandler.java`, already researched): request is `Signal.PUBLISH`/`SubSignal.FP` with body `Im_Version{version: 0}` serialized as protobuf (NOT the JSON used for the one-off `CONNECT` message — `FP`/`UPUI` are ordinary `PUBLISH`-signal business messages, same protobuf convention as Plan D's `MS`/`MP`). **Always a full refresh** (`version` is hardcoded to `0` on every call, never seeded from `ConnectAckPayload.friend_head`) — Android's own client never does incremental friend sync despite the head field existing in the handshake payload, so this plan doesn't either. Response: `Im_GetFriendsResult{entry: [Im_Friend]}`, `Im_Friend{uid, state, updateDt, alias}`. **Android's own `FriendPullHandler` only extracts `uid`** from each entry — `state`/`alias`/`updateDt` are read off the wire but never used by the client. This plan matches that: only `uid` membership matters for Phase 1.
- **User-info pull** (`ProtoService.getUserInfo`/`getUserInfos`, `GetUserInfoMessageHanlder.java`, already researched): request is `Signal.PUBLISH`/`SubSignal.UPUI` with body `Im_PullUserRequest{request: [Im_UserRequest{uid}]}`. Response: `Im_PullUserResult{result: [Im_UserResult{user: Im_User, code}]}`, `Im_User{uid, name, displayName, portrait, mobile, email, address, company, extra, updateDt, gender, social, type}` — `IMStorage.StoredUser` (Plan C) already only keeps the subset Phase 1 needs (`name`, `displayName`, `portrait`, `mobile`, `gender`, `updateDt`), so this plan maps onto that existing shape with no further trimming needed. **Fetched lazily, never bulk-prefetched**: Android only calls `getUserInfo`/`getUserInfos` when something (a UI cell) needs a profile that isn't already cached — receiving a fresh friend list does **not** automatically trigger a bulk profile pull. This plan's `ContactSyncService.fetchUserInfo(uids:forceRefresh:)` mirrors that: callers (Plan G's UI code) decide when to ask, only uncached (or `forceRefresh`-requested) UIDs go out over the wire.
- **Trigger timing** (`ConnectAckMessageHandler.java`, already researched): `getMyFriendList(true)` is called unconditionally, fire-and-forget, immediately after parsing `CONNECT_ACK` — the exact same callback site that also kicks off message pull. This plan wires `ContactSyncService.syncFriendList()` into `ConnectAckHandler.onSyncState` (`AppEnvironment.connectIfPossible()`, Plan E), alongside the already-wired `MessagingService.pullMessagesSinceLastSync(syncState:)` call.
- **`SubSignal.fp` (16) and `.upui` (11)** already exist in `Sources/IMTransport/SubSignal.swift` (Plan A) — no enum changes needed. `Im_Version`, `Im_GetFriendsResult`, `Im_Friend`, `Im_PullUserRequest`, `Im_UserRequest`, `Im_PullUserResult`, `Im_UserResult`, `Im_User` are all already present in `Sources/IMProto/Generated/WFCMessage.pb.swift` (Plan A generated the whole `chat-proto` file, not just the message-specific subset) — no codegen changes needed.
- **A real correctness trap, caught during planning, not left for a reviewer to find**: `UserStore`'s existing generic `upsert(_:)` does a full-row `.save()`. If `UserInfoSyncHandler` naively built a fresh `StoredUser` from a wire `Im_User` (which carries no friend-status information at all) and `.save()`d it, it would silently clobber an existing row's `isFriend = true` back to `false` for any friend whose profile gets refreshed after the initial sync. This plan's `UserStore.upsertProfile(...)` (Task 1) reads the existing row first and only overwrites the profile columns, explicitly preserving `isFriend` — `FriendSyncHandler`'s `replaceFriendList(uids:)` is the only code path allowed to change `isFriend`.

---

## Task 1: `StoredUser.isFriend` + `UserStore` additions

**Files:**
- Modify: `Sources/IMStorage/IMDatabase.swift` (new additive migration)
- Modify: `Sources/IMStorage/StoredUser.swift` (new `isFriend` field)
- Modify: `Sources/IMStorage/UserStore.swift` (new methods)
- Modify: `Tests/IMStorageTests/UserStoreTests.swift` (create if it doesn't exist yet — check first)

- [ ] **Step 1: Read the existing `Tests/IMStorageTests/UserStoreTests.swift`**

It already exists (from Plan C), with this exact structure — match it, don't replace it:

```swift
final class UserStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: UserStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = UserStore(dbQueue: database.dbQueue)
        cancellables = []
    }
    // ... existing tests (test_upsert_thenFetchByUid_returnsStoredUser, etc.) ...
}
```

- [ ] **Step 2: Append the new failing tests** (inside the existing class, after its last test)

```swift
    func test_replaceFriendList_marksListedUidsAsFriendsAndCreatesPlaceholderRows() throws {
        try store.replaceFriendList(uids: ["u1", "u2"])

        let friends = try store.friends()
        XCTAssertEqual(Set(friends.map(\.uid)), ["u1", "u2"])
        XCTAssertTrue(friends.allSatisfy(\.isFriend))
    }

    func test_replaceFriendList_calledAgainWithFewerUids_unmarksRemovedFriends() throws {
        try store.replaceFriendList(uids: ["u1", "u2"])
        try store.replaceFriendList(uids: ["u1"])

        let friends = try store.friends()
        XCTAssertEqual(friends.map(\.uid), ["u1"])

        // u2's row still exists (not deleted) but is no longer flagged as a friend.
        let u2 = try store.user(uid: "u2")
        XCTAssertNotNil(u2)
        XCTAssertFalse(u2!.isFriend)
    }

    func test_replaceFriendList_preservesExistingProfileFieldsForAlreadyKnownUser() throws {
        try store.upsertProfile(uid: "u1", name: "u1name", displayName: "Display One", portrait: "http://example.com/p.png", mobile: "13800000000", gender: 1, updateDt: 1_000)

        try store.replaceFriendList(uids: ["u1"])

        let u1 = try store.user(uid: "u1")
        XCTAssertEqual(u1?.displayName, "Display One")
        XCTAssertTrue(u1?.isFriend ?? false)
    }

    func test_upsertProfile_doesNotClobberExistingIsFriendFlag() throws {
        try store.replaceFriendList(uids: ["u1"])
        XCTAssertTrue(try store.user(uid: "u1")!.isFriend)

        try store.upsertProfile(uid: "u1", name: "u1name", displayName: "Display One", portrait: nil, mobile: nil, gender: 0, updateDt: 2_000)

        let u1 = try store.user(uid: "u1")
        XCTAssertEqual(u1?.displayName, "Display One")
        XCTAssertTrue(u1?.isFriend ?? false) // still a friend — profile update alone must not flip this
    }

    func test_upsertProfile_createsRowIfNoneExists() throws {
        try store.upsertProfile(uid: "newUser", name: "n", displayName: "New User", portrait: nil, mobile: nil, gender: 0, updateDt: 1)

        let user = try store.user(uid: "newUser")
        XCTAssertEqual(user?.displayName, "New User")
        XCTAssertFalse(user?.isFriend ?? true) // a profile-only upsert never makes someone a friend
    }

    func test_friends_excludesNonFriendProfiles() throws {
        try store.upsertProfile(uid: "stranger", name: nil, displayName: "Stranger", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try store.replaceFriendList(uids: ["friend1"])

        let friends = try store.friends()
        XCTAssertEqual(friends.map(\.uid), ["friend1"])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter UserStoreTests`
Expected: FAIL with `error: value of type 'UserStore' has no member 'replaceFriendList'` (and similar for `upsertProfile`/`friends`)

- [ ] **Step 4: Add the migration**

In `Sources/IMStorage/IMDatabase.swift`, add a new migration registration after `"v1_createSchema"` (inside `migrator`, before `return migrator`):

```swift
        migrator.registerMigration("v2_addUserIsFriend") { db in
            try db.alter(table: "user") { t in
                t.add(column: "isFriend", .boolean).notNull().defaults(to: false)
            }
        }
```

- [ ] **Step 5: Add `isFriend` to `StoredUser`**

In `Sources/IMStorage/StoredUser.swift`, replace the whole file:

```swift
import GRDB

/// Static contact-list cache. Only the fields Phase 1's contact list and
/// message sender display actually need (`name`, `displayName`, `portrait`,
/// `mobile`, `gender`, `updateDt`) — `ProtoUserInfo`'s richer profile fields
/// (`email`, `address`, `company`, `social`, `extra`, `friendAlias`,
/// `groupAlias`) are deliberately omitted (YAGNI); add them later if a
/// future phase's profile screen needs them — purely additive, no migration
/// of existing columns required.
///
/// `isFriend` (Plan F) tracks contact-list membership, populated by
/// `UserStore.replaceFriendList(uids:)` only — never touched by
/// `upsertProfile(...)`, which only ever writes the profile columns. A row
/// can exist with `isFriend == false` (e.g. someone who messaged you but
/// isn't a friend, whose profile got resolved for display purposes) or with
/// every profile field still `nil` (a friend-list UID not yet resolved via
/// `UPUI`) — both are valid, expected states, not bugs.
public struct StoredUser: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "user"

    public var uid: String
    public var name: String?
    public var displayName: String?
    public var portrait: String?
    public var mobile: String?
    public var gender: Int
    public var updateDt: Int64
    public var isFriend: Bool

    public init(uid: String, name: String?, displayName: String?, portrait: String?, mobile: String?, gender: Int, updateDt: Int64, isFriend: Bool = false) {
        self.uid = uid
        self.name = name
        self.displayName = displayName
        self.portrait = portrait
        self.mobile = mobile
        self.gender = gender
        self.updateDt = updateDt
        self.isFriend = isFriend
    }
}
```

- [ ] **Step 6: Add the new `UserStore` methods**

In `Sources/IMStorage/UserStore.swift`, add these methods (e.g. after `usersPublisher()`):

```swift
    private static let friendsOrderedSQL = "SELECT * FROM user WHERE isFriend = 1 ORDER BY displayName IS NULL, displayName"

    public func friends() throws -> [StoredUser] {
        try dbQueue.read { db in
            try StoredUser.fetchAll(db, sql: Self.friendsOrderedSQL)
        }
    }

    public func friendsPublisher() -> AnyPublisher<[StoredUser], Error> {
        ValueObservation
            .tracking { db in try StoredUser.fetchAll(db, sql: Self.friendsOrderedSQL) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    /// Replaces the entire friend-UID set: every currently-`isFriend`
    /// user not in `uids` is unflagged (not deleted — their cached profile,
    /// if any, is kept), and every uid in `uids` is flagged, creating a
    /// placeholder row (all profile fields `nil`) if none exists yet.
    /// Mirrors Android's `setFriendArr(refresh: true)` full-replace
    /// semantics — see this plan's "Reference facts".
    public func replaceFriendList(uids: [String]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE user SET isFriend = 0")
            for uid in uids {
                if var existing = try StoredUser.fetchOne(db, key: uid) {
                    existing.isFriend = true
                    try existing.save(db)
                } else {
                    try StoredUser(uid: uid, name: nil, displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true).save(db)
                }
            }
        }
    }

    /// Merges profile fields into the row for `uid`, creating it if it
    /// doesn't exist yet. Never touches `isFriend` — see this plan's
    /// "Reference facts" for why a naive whole-row upsert here would be a
    /// real bug (it would clobber friend status on every profile refresh).
    public func upsertProfile(uid: String, name: String?, displayName: String?, portrait: String?, mobile: String?, gender: Int, updateDt: Int64) throws {
        try dbQueue.write { db in
            var user = try StoredUser.fetchOne(db, key: uid) ?? StoredUser(uid: uid, name: nil, displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0)
            user.name = name
            user.displayName = displayName
            user.portrait = portrait
            user.mobile = mobile
            user.gender = gender
            user.updateDt = updateDt
            try user.save(db)
        }
    }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter UserStoreTests`
Expected: `Executed 11 tests, with 0 failures` (5 pre-existing + 6 new)

- [ ] **Step 8: Run the full suite to confirm no regressions**

Run: `swift test`
Expected: all previously-existing tests (171) plus these 6 new ones pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/IMStorage/IMDatabase.swift Sources/IMStorage/StoredUser.swift Sources/IMStorage/UserStore.swift Tests/IMStorageTests/UserStoreTests.swift
git commit -m "feat(IMStorage): add StoredUser.isFriend and friend-list-aware UserStore methods"
```

---

## Task 2: Scaffold the `IMContacts` SwiftPM target

**Files:**
- Modify: `Package.swift`
- Modify: `project.yml` (so the App target can later import `IMContacts` transitively via `AppCore`, mirroring how `IMMessaging` was added in Plan D/E)
- Create: `Sources/IMContacts/_Scaffold.swift`
- Create: `Tests/IMContactsTests/_Scaffold.swift`

- [ ] **Step 1: Edit `Package.swift`**

Add to `products` (after `AppCore`):

```swift
        .library(name: "IMContacts", targets: ["IMContacts"]),
```

Add to `targets` (after `AppCore`'s entries):

```swift
        .target(name: "IMContacts", dependencies: ["IMClient", "IMStorage", "IMProto", "IMTransport"]),
        .testTarget(name: "IMContactsTests", dependencies: ["IMContacts"]),
```

- [ ] **Step 2: Create placeholder source**

```bash
mkdir -p Sources/IMContacts Tests/IMContactsTests
echo "// IMContacts placeholder, removed in Task 3" > Sources/IMContacts/_Scaffold.swift
echo "// IMContactsTests placeholder, removed in Task 3" > Tests/IMContactsTests/_Scaffold.swift
```

- [ ] **Step 3: Add `IMContacts` to `AppCore`'s target dependencies in `Package.swift`**

`AppEnvironment` (Task 6) needs to construct `ContactSyncService`, so `AppCore`'s target dependencies must include `IMContacts`. Change:

```swift
        .target(name: "AppCore", dependencies: ["IMClient", "IMStorage", "IMMessaging"]),
```

to:

```swift
        .target(name: "AppCore", dependencies: ["IMClient", "IMStorage", "IMMessaging", "IMContacts"]),
```

- [ ] **Step 4: Build and test**

```bash
swift build
swift test
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `swift build` → `Build complete!`; `swift test` → all previously-existing tests still pass (no new tests yet — the new `IMContacts`/`IMContactsTests` targets have no real tests); `xcodebuild` → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift project.yml ios-chat-pro.xcodeproj Sources/IMContacts Tests/IMContactsTests
git commit -m "chore: scaffold IMContacts SwiftPM target"
```

---

## Task 3: `FriendSyncHandler`

**Files:**
- Create: `Sources/IMContacts/FriendSyncHandler.swift`
- Test: `Tests/IMContactsTests/FriendSyncHandlerTests.swift`
- Modify: delete `Sources/IMContacts/_Scaffold.swift`, delete `Tests/IMContactsTests/_Scaffold.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMContactsTests/FriendSyncHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class FriendSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: FriendSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = FriendSyncHandler(storage: storage)
    }

    private func makeFrame(errorCode: UInt8, uids: [String]) throws -> Frame {
        var result = Im_GetFriendsResult()
        result.entry = uids.map { uid in
            var friend = Im_Friend()
            friend.uid = uid
            return friend
        }
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .fp, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndFP() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .fp))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .upui))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .fp))
    }

    func test_handle_successBody_replacesFriendListInStorage() throws {
        let frame = try makeFrame(errorCode: 0, uids: ["u1", "u2"])

        handler.handle(frame: frame)

        let friends = try storage.users.friends()
        XCTAssertEqual(Set(friends.map(\.uid)), ["u1", "u2"])
    }

    func test_handle_nonZeroErrorCode_doesNothingNoCrash() throws {
        let frame = try makeFrame(errorCode: 1, uids: ["u1"])

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.users.friends().count, 0)
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .fp, bodyLength: 0, messageId: 1), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FriendSyncHandlerTests`
Expected: FAIL with `error: cannot find type 'FriendSyncHandler' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMContacts/FriendSyncHandler.swift
import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `PUB_ACK`/`FP` friend-list-pull response and replaces
/// `IMStorage`'s friend-flagged user set. The wire body is "1 byte error
/// code, then `Im_GetFriendsResult`" — universal to every `PUB_ACK`
/// response (see this plan's "Reference facts"). Only `Im_Friend.uid` is
/// used, matching Android's own client, which reads but never uses
/// `state`/`alias`/`updateDt`.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class FriendSyncHandler: MessageHandler {
    private let storage: IMStorage

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .fp
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_GetFriendsResult(serializedBytes: frame.body.dropFirst()) else { return }
        try? storage.users.replaceFriendList(uids: result.entry.map(\.uid))
    }
}
```

- [ ] **Step 4: Remove Task 2 scaffolding**

```bash
rm -f Sources/IMContacts/_Scaffold.swift Tests/IMContactsTests/_Scaffold.swift
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter FriendSyncHandlerTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMContacts/FriendSyncHandler.swift Tests/IMContactsTests/FriendSyncHandlerTests.swift
git add -u Sources/IMContacts Tests/IMContactsTests
git commit -m "feat(IMContacts): add FriendSyncHandler"
```

---

## Task 4: `UserInfoSyncHandler`

**Files:**
- Create: `Sources/IMContacts/UserInfoSyncHandler.swift`
- Test: `Tests/IMContactsTests/UserInfoSyncHandlerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMContactsTests/UserInfoSyncHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class UserInfoSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: UserInfoSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = UserInfoSyncHandler(storage: storage)
    }

    private func makeFrame(errorCode: UInt8, users: [Im_User]) throws -> Frame {
        var result = Im_PullUserResult()
        result.result = users.map { user in
            var userResult = Im_UserResult()
            userResult.user = user
            userResult.code = 0
            return userResult
        }
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .upui, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    private func makeWireUser(uid: String, displayName: String) -> Im_User {
        var user = Im_User()
        user.uid = uid
        user.displayName = displayName
        return user
    }

    func test_canHandle_onlyMatchesPubAckAndUPUI() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .upui))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .fp))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .upui))
    }

    func test_handle_successBody_upsertsEachUsersProfile() throws {
        let frame = try makeFrame(errorCode: 0, users: [makeWireUser(uid: "u1", displayName: "Alice"), makeWireUser(uid: "u2", displayName: "Bob")])

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.users.user(uid: "u1")?.displayName, "Alice")
        XCTAssertEqual(try storage.users.user(uid: "u2")?.displayName, "Bob")
    }

    func test_handle_doesNotClobberExistingIsFriendFlag() throws {
        try storage.users.replaceFriendList(uids: ["u1"])

        let frame = try makeFrame(errorCode: 0, users: [makeWireUser(uid: "u1", displayName: "Alice")])
        handler.handle(frame: frame)

        let u1 = try storage.users.user(uid: "u1")
        XCTAssertEqual(u1?.displayName, "Alice")
        XCTAssertTrue(u1?.isFriend ?? false)
    }

    func test_handle_nonZeroErrorCode_doesNothingNoCrash() throws {
        let frame = try makeFrame(errorCode: 1, users: [makeWireUser(uid: "u1", displayName: "Alice")])

        handler.handle(frame: frame)

        XCTAssertNil(try storage.users.user(uid: "u1"))
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .upui, bodyLength: 0, messageId: 1), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UserInfoSyncHandlerTests`
Expected: FAIL with `error: cannot find type 'UserInfoSyncHandler' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMContacts/UserInfoSyncHandler.swift
import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `PUB_ACK`/`UPUI` bulk-user-info-pull response and upserts
/// each user's profile fields into `IMStorage`. Same "1 byte error code,
/// then protobuf" wire format as `FriendSyncHandler` — see this plan's
/// "Reference facts". Uses `UserStore.upsertProfile(...)`, never the raw
/// whole-row `upsert(_:)`, so an existing `isFriend` flag is never
/// clobbered by a profile refresh.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class UserInfoSyncHandler: MessageHandler {
    private let storage: IMStorage

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .upui
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_PullUserResult(serializedBytes: frame.body.dropFirst()) else { return }
        for userResult in result.result {
            let user = userResult.user
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
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UserInfoSyncHandlerTests`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMContacts/UserInfoSyncHandler.swift Tests/IMContactsTests/UserInfoSyncHandlerTests.swift
git commit -m "feat(IMContacts): add UserInfoSyncHandler"
```

---

## Task 5: `ContactSyncService`

**Files:**
- Create: `Sources/IMContacts/ContactSyncService.swift`
- Create: `Tests/IMContactsTests/Support/FakeTransportConnection.swift` (same rationale as the duplicates in `IMMessagingTests`/`AppCoreTests` from earlier plans — `internal` types aren't visible across SwiftPM test targets)
- Test: `Tests/IMContactsTests/ContactSyncServiceTests.swift`

- [ ] **Step 1: Add the local fake transport**

```swift
// Tests/IMContactsTests/Support/FakeTransportConnection.swift
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

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/IMContactsTests/ContactSyncServiceTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class ContactSyncServiceTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var service: ContactSyncService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        service = ContactSyncService(imClient: imClient, storage: storage)

        imClient.connect()
        fakeTransport.simulate(.connected) // CONNECT message send completes synchronously via the fake's completion callback
    }

    private func decodeOnlySentFrame() throws -> Frame {
        try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
    }

    func test_syncFriendList_sendsAVersionZeroFPRequest() throws {
        service.syncFriendList()

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .fp)
        let request = try Im_Version(serializedBytes: frame.body)
        XCTAssertEqual(request.version, 0)
    }

    func test_fetchUserInfo_requestsOnlyUncachedUids() throws {
        try storage.users.upsertProfile(uid: "cached", name: nil, displayName: "Cached", portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        service.fetchUserInfo(uids: ["cached", "uncached"], forceRefresh: false)

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .upui)
        let request = try Im_PullUserRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.request.map(\.uid), ["uncached"])
    }

    func test_fetchUserInfo_withForceRefresh_requestsEveryRequestedUid() throws {
        try storage.users.upsertProfile(uid: "cached", name: nil, displayName: "Cached", portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        service.fetchUserInfo(uids: ["cached", "uncached"], forceRefresh: true)

        let frame = try decodeOnlySentFrame()
        let request = try Im_PullUserRequest(serializedBytes: frame.body)
        XCTAssertEqual(Set(request.request.map(\.uid)), ["cached", "uncached"])
    }

    func test_fetchUserInfo_withNoUncachedUidsAndNoForceRefresh_sendsNothing() throws {
        try storage.users.upsertProfile(uid: "cached", name: nil, displayName: "Cached", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        let countBefore = fakeTransport.sentFrames.count

        service.fetchUserInfo(uids: ["cached"], forceRefresh: false)

        XCTAssertEqual(fakeTransport.sentFrames.count, countBefore)
    }

    func test_receivingFPResponse_isHandledEndToEnd() throws {
        var result = Im_GetFriendsResult()
        var friend = Im_Friend()
        friend.uid = "u1"
        result.entry = [friend]
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .fp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(try storage.users.friends().map(\.uid), ["u1"])
    }

    func test_receivingUPUIResponse_isHandledEndToEnd() throws {
        var result = Im_PullUserResult()
        var userResult = Im_UserResult()
        userResult.user.uid = "u1"
        userResult.user.displayName = "Alice"
        result.result = [userResult]
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .upui, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(try storage.users.user(uid: "u1")?.displayName, "Alice")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ContactSyncServiceTests`
Expected: FAIL with `error: cannot find type 'ContactSyncService' in scope`

- [ ] **Step 4: Implement**

```swift
// Sources/IMContacts/ContactSyncService.swift
import IMClient
import IMProto
import IMStorage

/// The single entry point Plan G's UI code constructs (or, more likely,
/// `AppEnvironment` constructs once and Plan G's view models read
/// `IMStorage.UserStore` directly — this service only owns *sending*
/// requests, not data access): registers `FriendSyncHandler`/
/// `UserInfoSyncHandler` with the given `IMClient`, and exposes
/// `syncFriendList()`/`fetchUserInfo(uids:forceRefresh:)`.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ContactSyncService {
    private let imClient: IMClient
    private let storage: IMStorage

    public init(imClient: IMClient, storage: IMStorage) {
        self.imClient = imClient
        self.storage = storage

        imClient.register(FriendSyncHandler(storage: storage))
        imClient.register(UserInfoSyncHandler(storage: storage))
    }

    /// Always a full refresh (`version: 0`) — Android's own client never
    /// does incremental friend sync either; see this plan's "Reference
    /// facts". Call once after a successful connect (wire this to
    /// `ConnectAckHandler.onSyncState`, Task 6), same as Android's
    /// `ConnectAckMessageHandler`.
    public func syncFriendList() {
        var request = Im_Version()
        request.version = 0
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .fp, body: body)
    }

    /// Requests profiles for `uids` not already cached locally, unless
    /// `forceRefresh` is true (then every requested uid goes out over the
    /// wire regardless of cache state). Sends nothing if there's nothing to
    /// ask for. Mirrors Android's `getUserInfo`/`getUserInfos` cache-check —
    /// see this plan's "Reference facts".
    public func fetchUserInfo(uids: [String], forceRefresh: Bool) {
        let targetUids: [String]
        if forceRefresh {
            targetUids = uids
        } else {
            targetUids = uids.filter { (try? storage.users.user(uid: $0)) == nil }
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
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ContactSyncServiceTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 6: Run the entire suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/IMContacts/ContactSyncService.swift Tests/IMContactsTests/Support/FakeTransportConnection.swift Tests/IMContactsTests/ContactSyncServiceTests.swift
git commit -m "feat(IMContacts): add ContactSyncService facade"
```

---

## Task 6: Wire `ContactSyncService` into `AppEnvironment`

**Files:**
- Modify: `Sources/AppCore/AppEnvironment.swift`
- Modify: `Tests/AppCoreTests/AppEnvironmentTests.swift`

- [ ] **Step 1: Write the failing test**

Read `Tests/AppCoreTests/AppEnvironmentTests.swift`'s current content first (it already exists from Plan E). Add this test:

```swift
    func test_connectIfPossible_withCredentials_alsoTriggersAFriendListSync() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))

        XCTAssertTrue(environment.connectIfPossible())

        // The CONNECT frame's send is the only thing the fake transport has
        // recorded so far — connectIfPossible() itself doesn't send FP, only
        // the post-CONNECT_ACK callback does (this plan's "Reference facts":
        // friend sync triggers from the same hook as message catch-up).
        // Simulate the server's CONNECT_ACK to fire that callback.
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
        XCTAssertTrue(sentSignals.contains(.fp))
    }
```

Check `FakeTransportConnection` in `Tests/AppCoreTests/Support/FakeTransportConnection.swift` (from Plan E) already exposes `simulate(_:)`/`simulateReceivedData(_:)` — if its current shape (from Plan E Task 7) only has `startCallCount`/`sentFrames` and lacks `onEvent`/`onDataReceived`-driven simulation helpers, extend it minimally to add `simulate(_ event: IMTransportEvent)` and `simulateReceivedData(_ data: Data)`, matching the pattern already used in `IMContactsTests`' and `IMMessagingTests`' own copies of this fake (Task 5 of this plan, and Plan D Task 10).

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AppEnvironmentTests`
Expected: FAIL — either a compile error (if `FakeTransportConnection` needs the helper methods added) or `XCTAssertTrue` failing because `.fp` was never sent.

- [ ] **Step 3: Implement**

In `Sources/AppCore/AppEnvironment.swift`, add the import and wire the service in. Add near the top:

```swift
import IMContacts
```

Add a stored property (near `messagingService`):

```swift
    public private(set) var contactSyncService: ContactSyncService?
```

In `connectIfPossible()`, after the existing `messagingService = service` line and before `client.connect()`, add:

```swift
        let contactSync = ContactSyncService(imClient: client, storage: storage)
        contactSyncService = contactSync
```

Change the existing `connectAckHandler.onSyncState` closure to also trigger friend sync:

```swift
        connectAckHandler.onSyncState = { [weak service, weak contactSync] syncState in
            service?.pullMessagesSinceLastSync(syncState: syncState)
            contactSync?.syncFriendList()
        }
```

In `logOut()`, also clear the new property:

```swift
    public func logOut() {
        imClient?.disconnect()
        imClient = nil
        messagingService = nil
        contactSyncService = nil
        credentialsStore.clear()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppEnvironmentTests`
Expected: all `AppEnvironmentTests` pass, including the new one.

- [ ] **Step 5: Run the full suite and the Xcode build**

```bash
swift test
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: all tests pass; `** BUILD SUCCEEDED **`. Remember to check `git status` for a regenerated `project.pbxproj` and include it in the commit if changed (this Xcode project uses an explicit file list — see Plan E's self-review notes for why this matters).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/AppEnvironment.swift Tests/AppCoreTests/AppEnvironmentTests.swift Tests/AppCoreTests/Support/FakeTransportConnection.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(AppCore): trigger friend-list sync alongside message catch-up after connect"
```

---

## Plan Self-Review Notes

- **Spec coverage:** Implements the contact-list data-population gap discovered while researching Plan G (originally assumed Plan G's UI work would be small enough to absorb this; reading the Android client revealed friend-list pull and bulk user-info pull are their own protocol subsystem, the same kind of discovery that split Plan D out of what became Plan E). Does **not** implement friend requests (`AddFriendRequest`/`HandleFriendRequest`/`GetFriendRequestResult`/`SubSignal.frus`/`.frp`/`.frn`), blocking, group membership, or any contact mutation — Phase 1 is read-only/sync-only per the migration design doc ("不支持增删"), and this plan only builds the sync half.
- **Also fixed in passing, on `main`, before this plan started**: `ReceiveMessageHandler`'s missing error-byte skip (a real bug discovered via this same research thread, affecting already-merged Plan D code) — see the separate commit history on `main`, not part of this plan's own commits.
- **`ContactSyncService.fetchUserInfo`'s cache check is presence-based, not staleness-based** (`(try? storage.users.user(uid: $0)) == nil`) — matches Android's own `getUserInfo` behavior exactly (checked `imMemoryStore.getUserInfo(userId) == null`, not a TTL). A user's profile, once fetched, is never automatically refreshed; only an explicit `forceRefresh: true` call re-fetches. This is acceptable parity with the reference implementation, not a regression.
- **No incremental friend sync.** `friend_head`/`friend_rq_head` from `ConnectAckPayload` are parsed (already, by Plan B's `ConnectAckHandler`) but never used by this plan, matching Android's own client, which also ignores them in favor of always doing a full `version: 0` refresh. If a future phase needs incremental sync (e.g. for very large friend lists), this is the place to revisit — not a Phase 1 concern.
- **`ContactSyncService` registering two handlers in its initializer is a side effect**, same pattern and same accepted Phase-1 double-construction risk already documented for `MessagingService` (Plan D) — constructing a second `ContactSyncService` against the same `IMClient` would register duplicate handlers. Not a concern since `AppEnvironment` constructs exactly one.
- **Friend requests, blocking, and group contact features are Phase 2+ per the migration design doc's roadmap** (好友管理: 申请/通过/删除 is explicitly Phase 2 scope) — this plan's `Im_Friend.state`/`alias` fields are read off the wire (required for the protobuf parse to succeed) but never interpreted, exactly matching Android's own client.
- **No placeholders:** every step above has complete, runnable code; nothing is left as "TODO" or "similar to above."
