# Phase 2 Group Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the full group chat closed loop (create group, group messaging with @mention, member management, group info editing, quit/dismiss, system notification messages) per `docs/superpowers/specs/2026-06-22-phase2-group-chat-design.md`.

**Architecture:** Add a new `IMGroups` SPM target mirroring `IMContacts`'s tracker/handler/service pattern; extend `IMStorage` with group tables and message/conversation columns; extend `IMMessaging` for @mention encode/decode and group-notification decode; add `IMKit` protocols/ViewModels; wire UI in `App`. No protocol or server changes — all messages already exist in `chat-proto`/`chat-server-pro`.

**Tech Stack:** Swift 5.8, SwiftPM, GRDB.swift, SwiftProtobuf, Combine, UIKit, XCTest.

---

## Part A — `IMStorage`: schema, models, `GroupStore`

### Task 1: `MessageEnums` — add `GroupType`, `GroupMemberType`, `ModifyGroupInfoType`, extend `MessageContentType`

**Files:**
- Modify: `Sources/IMStorage/MessageEnums.swift`
- Test: `Tests/IMStorageTests/MessageEnumsTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMStorageTests/MessageEnumsTests.swift
import XCTest
@testable import IMStorage

final class MessageEnumsTests: XCTestCase {
    func test_groupType_rawValuesMatchProtoConstants() {
        XCTAssertEqual(GroupType.normal.rawValue, 0)
        XCTAssertEqual(GroupType.free.rawValue, 1)
        XCTAssertEqual(GroupType.restricted.rawValue, 2)
    }

    func test_groupMemberType_rawValuesMatchAndroid() {
        XCTAssertEqual(GroupMemberType.normal.rawValue, 0)
        XCTAssertEqual(GroupMemberType.manager.rawValue, 1)
        XCTAssertEqual(GroupMemberType.owner.rawValue, 2)
        XCTAssertEqual(GroupMemberType.silent.rawValue, 3)
        XCTAssertEqual(GroupMemberType.removed.rawValue, 4)
    }

    func test_modifyGroupInfoType_rawValuesMatchProto() {
        XCTAssertEqual(ModifyGroupInfoType.name.rawValue, 0)
        XCTAssertEqual(ModifyGroupInfoType.portrait.rawValue, 1)
        XCTAssertEqual(ModifyGroupInfoType.extra.rawValue, 2)
    }

    func test_messageContentType_includesGroupNotificationCases() {
        XCTAssertEqual(MessageContentType.createGroup.rawValue, 104)
        XCTAssertEqual(MessageContentType.addGroupMember.rawValue, 105)
        XCTAssertEqual(MessageContentType.kickoffGroupMember.rawValue, 106)
        XCTAssertEqual(MessageContentType.quitGroup.rawValue, 107)
        XCTAssertEqual(MessageContentType.dismissGroup.rawValue, 108)
        XCTAssertEqual(MessageContentType.changeGroupName.rawValue, 110)
        XCTAssertEqual(MessageContentType.changeGroupPortrait.rawValue, 112)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MessageEnumsTests`
Expected: FAIL — `GroupType`, `GroupMemberType`, `ModifyGroupInfoType` not found; `MessageContentType` missing the new cases.

- [ ] **Step 3: Implement**

Append to `Sources/IMStorage/MessageEnums.swift`:

```swift
/// Matches `ProtoConstants.GroupType` (`chat-server-pro`'s
/// `push-stub/.../proto/ProtoConstants.java`) — verified by reading the
/// constants directly, not guessed: `Normal=0`, `Free=1`, `Restricted=2`.
public enum GroupType: Int, Codable, Equatable {
    case normal = 0
    case free = 1
    case restricted = 2
}

/// Matches `cn.wildfirechat.model.GroupMember.GroupMemberType`. `manager`/
/// `silent` are kept for wire parity even though Phase 2's UI never reads or
/// sets them (confirmed unused in Android's own `GroupInfoActivity`) — same
/// "mirror the full enum, use a subset" convention as `MessageStatus`.
public enum GroupMemberType: Int, Codable, Equatable {
    case normal = 0
    case manager = 1
    case owner = 2
    case silent = 3
    case removed = 4
}

/// Matches `ModifyGroupInfoRequest.type`'s declared semantics. `extra` is
/// kept for wire parity though Phase 2's UI has no editor for it.
public enum ModifyGroupInfoType: Int32, Codable, Equatable {
    case name = 0
    case portrait = 1
    case extra = 2
}
```

Replace the existing `MessageContentType` enum with:

```swift
/// Subset of `cn.wildfirechat.message.core.MessageContentType` needed for
/// Phase 1 + Phase 2 group chat. The 7 group-notification raw values are
/// transcribed from `MessageContentType.java`'s
/// `ContentType_CREATE_GROUP`(104)/`ADD_GROUP_MEMBER`(105)/
/// `KICKOFF_GROUP_MEMBER`(106)/`QUIT_GROUP`(107)/`DISMISS_GROUP`(108)/
/// `CHANGE_GROUP_NAME`(110)/`CHANGE_GROUP_PORTRAIT`(112).
public enum MessageContentType: Int, Codable, Equatable {
    case text = 1
    case image = 3
    case createGroup = 104
    case addGroupMember = 105
    case kickoffGroupMember = 106
    case quitGroup = 107
    case dismissGroup = 108
    case changeGroupName = 110
    case changeGroupPortrait = 112
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MessageEnumsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/MessageEnums.swift Tests/IMStorageTests/MessageEnumsTests.swift
git commit -m "feat(storage): add group-related enums and notification content types"
```

---

### Task 2: `StoredGroup` and `StoredGroupMember` models

**Files:**
- Create: `Sources/IMStorage/StoredGroup.swift`
- Test: `Tests/IMStorageTests/StoredGroupTests.swift` (new) — deferred to Task 4 (needs the migration from Task 3 to actually persist); this task only adds the types, compiled but not yet round-tripped through a real table.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMStorageTests/StoredGroupTests.swift
import XCTest
@testable import IMStorage

final class StoredGroupTests: XCTestCase {
    func test_init_setsAllFields() {
        let group = StoredGroup(groupId: "g1", name: "Test Group", portrait: "http://x/p.png", owner: "u1", groupType: .normal, memberCount: 3, updateDt: 100, memberUpdateDt: 200)
        XCTAssertEqual(group.groupId, "g1")
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.portrait, "http://x/p.png")
        XCTAssertEqual(group.owner, "u1")
        XCTAssertEqual(group.groupType, .normal)
        XCTAssertEqual(group.memberCount, 3)
        XCTAssertEqual(group.updateDt, 100)
        XCTAssertEqual(group.memberUpdateDt, 200)
    }

    func test_groupMember_init_setsAllFields() {
        let member = StoredGroupMember(groupId: "g1", memberId: "u2", memberType: .owner, updateDt: 50)
        XCTAssertEqual(member.groupId, "g1")
        XCTAssertEqual(member.memberId, "u2")
        XCTAssertEqual(member.memberType, .owner)
        XCTAssertEqual(member.updateDt, 50)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StoredGroupTests`
Expected: FAIL — `StoredGroup`/`StoredGroupMember` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMStorage/StoredGroup.swift
import GRDB

/// One row per group the local user is a member of. Discovered passively
/// (no "list my groups" wire API exists) — created/updated by `IMGroups`'s
/// `GroupInfoSyncHandler` whenever a `.gpgi` response or a group
/// notification message arrives for this `groupId`.
public struct StoredGroup: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "groupInfo"

    public var groupId: String
    public var name: String
    public var portrait: String?
    public var owner: String?
    public var groupType: GroupType
    public var memberCount: Int
    public var updateDt: Int64
    public var memberUpdateDt: Int64

    public init(
        groupId: String,
        name: String,
        portrait: String?,
        owner: String?,
        groupType: GroupType,
        memberCount: Int,
        updateDt: Int64,
        memberUpdateDt: Int64
    ) {
        self.groupId = groupId
        self.name = name
        self.portrait = portrait
        self.owner = owner
        self.groupType = groupType
        self.memberCount = memberCount
        self.updateDt = updateDt
        self.memberUpdateDt = memberUpdateDt
    }
}

/// One row per (group, member) pair. `memberType == .removed` rows are kept
/// (not deleted) so a stale local cache can tell "never knew about this
/// member" apart from "knows they were removed" — `GroupStore.members(groupId:)`
/// filters `.removed` out for display.
public struct StoredGroupMember: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "groupMember"

    public var groupId: String
    public var memberId: String
    public var memberType: GroupMemberType
    public var updateDt: Int64

    public init(groupId: String, memberId: String, memberType: GroupMemberType, updateDt: Int64) {
        self.groupId = groupId
        self.memberId = memberId
        self.memberType = memberType
        self.updateDt = updateDt
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StoredGroupTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/StoredGroup.swift Tests/IMStorageTests/StoredGroupTests.swift
git commit -m "feat(storage): add StoredGroup and StoredGroupMember models"
```

---

### Task 3: Migration v4 — group tables + `message`/`conversation` new columns

**Files:**
- Modify: `Sources/IMStorage/IMDatabase.swift`
- Test: `Tests/IMStorageTests/IMDatabaseTests.swift` (check if exists first; create if not)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMStorageTests/IMDatabaseTests.swift
import XCTest
import GRDB
@testable import IMStorage

final class IMDatabaseMigrationTests: XCTestCase {
    func test_migration_createsGroupInfoAndGroupMemberTables() throws {
        let database = try IMDatabase.openInMemory()
        let tables = try database.dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        }
        XCTAssertTrue(tables.contains("groupInfo"))
        XCTAssertTrue(tables.contains("groupMember"))
    }

    func test_migration_addsMentionAndGroupNotificationColumnsToMessage() throws {
        let database = try IMDatabase.openInMemory()
        let columns = try database.dbQueue.read { db in
            try Set(Row.fetchAll(db, sql: "PRAGMA table_info(message)").map { $0["name"] as String })
        }
        XCTAssertTrue(columns.contains("mentionedType"))
        XCTAssertTrue(columns.contains("mentionedTargetsRaw"))
        XCTAssertTrue(columns.contains("groupNotificationOperator"))
        XCTAssertTrue(columns.contains("groupNotificationMembersRaw"))
        XCTAssertTrue(columns.contains("groupNotificationValue"))
    }

    func test_migration_addsUnreadMentionCountToConversation() throws {
        let database = try IMDatabase.openInMemory()
        let columns = try database.dbQueue.read { db in
            try Set(Row.fetchAll(db, sql: "PRAGMA table_info(conversation)").map { $0["name"] as String })
        }
        XCTAssertTrue(columns.contains("unreadMentionCount"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IMDatabaseMigrationTests`
Expected: FAIL — columns/tables don't exist yet.

- [ ] **Step 3: Implement**

In `Sources/IMStorage/IMDatabase.swift`, after the existing `migrator.registerMigration("v3_addFriendRequestTable") { ... }` block (and before `return migrator`), add:

```swift
migrator.registerMigration("v4_addGroupSupport") { db in
    try db.create(table: "groupInfo") { t in
        t.column("groupId", .text).notNull().primaryKey()
        t.column("name", .text).notNull()
        t.column("portrait", .text)
        t.column("owner", .text)
        t.column("groupType", .integer).notNull().defaults(to: 0)
        t.column("memberCount", .integer).notNull().defaults(to: 0)
        t.column("updateDt", .integer).notNull().defaults(to: 0)
        t.column("memberUpdateDt", .integer).notNull().defaults(to: 0)
    }
    try db.create(table: "groupMember") { t in
        t.column("groupId", .text).notNull()
        t.column("memberId", .text).notNull()
        t.column("memberType", .integer).notNull().defaults(to: 0)
        t.column("updateDt", .integer).notNull().defaults(to: 0)
        t.primaryKey(["groupId", "memberId"])
    }
    try db.alter(table: "message") { t in
        t.add(column: "mentionedType", .integer).notNull().defaults(to: 0)
        t.add(column: "mentionedTargetsRaw", .text)
        t.add(column: "groupNotificationOperator", .text)
        t.add(column: "groupNotificationMembersRaw", .text)
        t.add(column: "groupNotificationValue", .text)
    }
    try db.alter(table: "conversation") { t in
        t.add(column: "unreadMentionCount", .integer).notNull().defaults(to: 0)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter IMDatabaseMigrationTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/IMDatabase.swift Tests/IMStorageTests/IMDatabaseTests.swift
git commit -m "feat(storage): migrate schema for group tables and mention/notification columns"
```

---

### Task 4: `StoredMessage` — add `.groupNotification` content case + mention fields

**Files:**
- Modify: `Sources/IMStorage/StoredMessage.swift`
- Test: `Tests/IMStorageTests/StoredMessageTests.swift` (check if exists; extend or create)

- [ ] **Step 1: Write the failing test**

```swift
// Append to Tests/IMStorageTests/StoredMessageTests.swift (create file with this content if it doesn't exist yet)
import XCTest
@testable import IMStorage

final class StoredMessageContentTests: XCTestCase {
    func test_groupNotificationContent_roundTripsThroughInit() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .addGroupMember, operatorUid: "u1", memberUids: ["u2", "u3"], value: nil),
            timestamp: 1000, status: .unread, direction: .receive
        )
        XCTAssertEqual(message.contentType, .addGroupMember)
        XCTAssertEqual(message.content, .groupNotification(type: .addGroupMember, operatorUid: "u1", memberUids: ["u2", "u3"], value: nil))
        XCTAssertEqual(message.searchableContent, "[群通知]")
    }

    func test_changeGroupNameContent_storesValue() {
        let message = StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .changeGroupName, operatorUid: "u1", memberUids: [], value: "新群名"),
            timestamp: 1000, status: .unread, direction: .receive
        )
        XCTAssertEqual(message.content, .groupNotification(type: .changeGroupName, operatorUid: "u1", memberUids: [], value: "新群名"))
    }

    func test_mentionFields_defaultToEmptyAndRoundTrip() {
        let withoutMention = StoredMessage(
            localMessageId: 1, conversationType: .group, target: "g1", from: "u1",
            content: .text("hi"), timestamp: 1000, status: .unread, direction: .receive
        )
        XCTAssertEqual(withoutMention.mentionedType, 0)
        XCTAssertEqual(withoutMention.mentionedTargets, [])

        let withMention = StoredMessage(
            localMessageId: 2, conversationType: .group, target: "g1", from: "u1",
            content: .text("hi @you"), timestamp: 1000, status: .unread, direction: .receive,
            mentionedType: 1, mentionedTargets: ["u2", "u3"]
        )
        XCTAssertEqual(withMention.mentionedType, 1)
        XCTAssertEqual(withMention.mentionedTargets, ["u2", "u3"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StoredMessageContentTests`
Expected: FAIL — `.groupNotification` case and `mentionedType`/`mentionedTargets` init params don't exist.

- [ ] **Step 3: Implement**

Replace the full contents of `Sources/IMStorage/StoredMessage.swift` with:

```swift
import GRDB
import Foundation

/// Mirrors the wire-field mapping documented at the top of this file: text →
/// `searchable_content`; image → `searchable_content` digest + `data`
/// thumbnail + `remoteMediaUrl`; group notifications → decoded purely for
/// display (never re-encoded — the client never constructs `notify_content`
/// itself; see `MessageContentCodec`'s doc comment). `IMStorage` itself never
/// touches the wire `Im_MessageContent` type — `IMMessaging`'s handlers are
/// responsible for that conversion.
public enum MessageContent: Equatable {
    case text(String)
    case image(thumbnail: Data?, remoteURL: String?, localPath: String?)
    /// `type` is always one of the 7 group-notification `MessageContentType`
    /// cases. `value` carries the new group name for `.changeGroupName`,
    /// `nil` otherwise. `memberUids` carries the affected member list for
    /// `.createGroup`/`.addGroupMember`/`.kickoffGroupMember`, empty
    /// otherwise.
    case groupNotification(type: MessageContentType, operatorUid: String, memberUids: [String], value: String?)
}

public struct StoredMessage: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "message"

    public var id: Int64?
    public var localMessageId: Int64
    public var messageUid: Int64
    public var conversationType: ConversationType
    public var target: String
    public var line: Int
    public var from: String
    public var contentType: MessageContentType
    public var textContent: String?
    public var searchableContent: String?
    public var mediaRemoteURL: String?
    public var mediaLocalPath: String?
    public var mediaThumbnail: Data?
    public var timestamp: Int64
    public var status: MessageStatus
    public var direction: MessageDirection
    public var mentionedType: Int
    public var mentionedTargetsRaw: String?
    public var groupNotificationOperator: String?
    public var groupNotificationMembersRaw: String?
    public var groupNotificationValue: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Reassembles `MessageContent` from the flat storage columns.
    public var content: MessageContent {
        switch contentType {
        case .text:
            return .text(textContent ?? "")
        case .image:
            return .image(thumbnail: mediaThumbnail, remoteURL: mediaRemoteURL, localPath: mediaLocalPath)
        case .createGroup, .addGroupMember, .kickoffGroupMember, .quitGroup, .dismissGroup, .changeGroupName, .changeGroupPortrait:
            return .groupNotification(
                type: contentType,
                operatorUid: groupNotificationOperator ?? "",
                memberUids: groupNotificationMembers,
                value: groupNotificationValue
            )
        }
    }

    /// Comma-joined storage for the `repeated string mentioned_target`
    /// wire field — this codebase has no precedent for a JSON-array column,
    /// and uids never contain commas, so a simple CSV column avoids adding
    /// one. Computed, not stored: Swift's synthesized `Codable` only
    /// persists *stored* properties, so this never becomes a duplicate
    /// GRDB column.
    public var mentionedTargets: [String] {
        guard let raw = mentionedTargetsRaw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map(String.init)
    }

    public var groupNotificationMembers: [String] {
        guard let raw = groupNotificationMembersRaw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map(String.init)
    }

    public init(
        id: Int64? = nil,
        localMessageId: Int64,
        messageUid: Int64 = 0,
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        from: String,
        content: MessageContent,
        timestamp: Int64,
        status: MessageStatus,
        direction: MessageDirection,
        mentionedType: Int = 0,
        mentionedTargets: [String] = []
    ) {
        self.id = id
        self.localMessageId = localMessageId
        self.messageUid = messageUid
        self.conversationType = conversationType
        self.target = target
        self.line = line
        self.from = from
        self.timestamp = timestamp
        self.status = status
        self.direction = direction
        self.mentionedType = mentionedType
        self.mentionedTargetsRaw = mentionedTargets.isEmpty ? nil : mentionedTargets.joined(separator: ",")

        switch content {
        case .text(let text):
            contentType = .text
            textContent = text
            searchableContent = text
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
        case .image(let thumbnail, let remoteURL, let localPath):
            contentType = .image
            textContent = nil
            searchableContent = "[图片]"
            mediaRemoteURL = remoteURL
            mediaLocalPath = localPath
            mediaThumbnail = thumbnail
            groupNotificationOperator = nil
            groupNotificationMembersRaw = nil
            groupNotificationValue = nil
        case .groupNotification(let type, let operatorUid, let memberUids, let value):
            contentType = type
            textContent = nil
            searchableContent = "[群通知]"
            mediaRemoteURL = nil
            mediaLocalPath = nil
            mediaThumbnail = nil
            groupNotificationOperator = operatorUid
            groupNotificationMembersRaw = memberUids.isEmpty ? nil : memberUids.joined(separator: ",")
            groupNotificationValue = value
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StoredMessageContentTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/StoredMessage.swift Tests/IMStorageTests/StoredMessageTests.swift
git commit -m "feat(storage): add groupNotification content case and mention fields to StoredMessage"
```

---

### Task 5: `StoredConversation` — add `unreadMentionCount`

**Files:**
- Modify: `Sources/IMStorage/StoredConversation.swift`
- Modify: `Sources/IMStorage/ConversationStore.swift`
- Test: `Tests/IMStorageTests/ConversationStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/IMStorageTests/ConversationStoreTests.swift`:

```swift
    func test_recordIncomingMessage_withIncrementMentionTrue_incrementsUnreadMentionCount() throws {
        try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true, incrementMention: true)

        let conversation = try store.conversation(conversationType: .group, target: "g1")
        XCTAssertEqual(conversation?.unreadMentionCount, 1)
    }

    func test_recordIncomingMessage_withIncrementMentionFalse_doesNotChangeUnreadMentionCount() throws {
        try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true, incrementMention: false)

        XCTAssertEqual(try store.conversation(conversationType: .group, target: "g1")?.unreadMentionCount, 0)
    }

    func test_clearUnread_alsoResetsUnreadMentionCount() throws {
        try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true, incrementMention: true)

        try store.clearUnread(conversationType: .group, target: "g1", line: 0)

        XCTAssertEqual(try store.conversation(conversationType: .group, target: "g1")?.unreadMentionCount, 0)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConversationStoreTests`
Expected: FAIL — `incrementMention` param and `unreadMentionCount` property don't exist.

- [ ] **Step 3: Implement**

In `Sources/IMStorage/StoredConversation.swift`, add the field and init param:

```swift
    public var unreadCount: Int
    public var unreadMentionCount: Int
    public var isTop: Bool
```

(insert `unreadMentionCount` line right after `unreadCount`), and in `init`:

```swift
        unreadCount: Int = 0,
        unreadMentionCount: Int = 0,
        isTop: Bool = false,
```

with `self.unreadMentionCount = unreadMentionCount` added alongside `self.unreadCount = unreadCount`.

In `Sources/IMStorage/ConversationStore.swift`, update `recordIncomingMessage` and `clearUnread`:

```swift
    public func recordIncomingMessage(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        messageUid: Int64,
        timestamp: Int64,
        incrementUnread: Bool,
        incrementMention: Bool = false
    ) throws {
        try dbQueue.write { db in
            let existing = try StoredConversation
                .filter(Column("conversationType") == conversationType.rawValue)
                .filter(Column("target") == target)
                .filter(Column("line") == line)
                .fetchOne(db)

            var conversation = existing ?? StoredConversation(conversationType: conversationType, target: target, line: line)
            conversation.lastMessageUid = messageUid
            conversation.timestamp = timestamp
            if incrementUnread {
                conversation.unreadCount += 1
            }
            if incrementMention {
                conversation.unreadMentionCount += 1
            }
            try conversation.save(db)
        }
    }

    public func clearUnread(conversationType: ConversationType, target: String, line: Int = 0) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET unreadCount = 0, unreadMentionCount = 0 WHERE conversationType = ? AND target = ? AND line = ?",
                arguments: [conversationType.rawValue, target, line]
            )
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConversationStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/StoredConversation.swift Sources/IMStorage/ConversationStore.swift Tests/IMStorageTests/ConversationStoreTests.swift
git commit -m "feat(storage): add unreadMentionCount to conversations"
```

---

### Task 6: `GroupStore`

**Files:**
- Create: `Sources/IMStorage/GroupStore.swift`
- Modify: `Sources/IMStorage/IMStorage.swift`
- Test: `Tests/IMStorageTests/GroupStoreTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMStorageTests/GroupStoreTests.swift
import XCTest
import Combine
@testable import IMStorage

final class GroupStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: GroupStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = GroupStore(dbQueue: database.dbQueue)
        cancellables = []
    }

    func test_upsertGroup_thenFetch_returnsStoredGroup() throws {
        try store.upsertGroup(StoredGroup(groupId: "g1", name: "Group 1", portrait: nil, owner: "u1", groupType: .normal, memberCount: 2, updateDt: 100, memberUpdateDt: 0))

        let group = try store.group(groupId: "g1")
        XCTAssertEqual(group?.name, "Group 1")
        XCTAssertEqual(group?.owner, "u1")
    }

    func test_upsertGroup_overwritesExistingRow() throws {
        try store.upsertGroup(StoredGroup(groupId: "g1", name: "Old Name", portrait: nil, owner: "u1", groupType: .normal, memberCount: 2, updateDt: 100, memberUpdateDt: 0))
        try store.upsertGroup(StoredGroup(groupId: "g1", name: "New Name", portrait: nil, owner: "u1", groupType: .normal, memberCount: 3, updateDt: 200, memberUpdateDt: 0))

        let group = try store.group(groupId: "g1")
        XCTAssertEqual(group?.name, "New Name")
        XCTAssertEqual(group?.memberCount, 3)
    }

    func test_groupPublisher_emitsOnUpsert() throws {
        var received: [StoredGroup?] = []
        let expectation = expectation(description: "received 2 emissions")
        expectation.expectedFulfillmentCount = 2

        store.groupPublisher(groupId: "g1")
            .sink(receiveCompletion: { _ in }, receiveValue: { group in
                received.append(group)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.upsertGroup(StoredGroup(groupId: "g1", name: "Group 1", portrait: nil, owner: "u1", groupType: .normal, memberCount: 1, updateDt: 0, memberUpdateDt: 0))

        wait(for: [expectation], timeout: 2)
        XCTAssertNil(received[0])
        XCTAssertEqual(received[1]?.name, "Group 1")
    }

    func test_upsertMember_thenFetchMembers_excludesRemoved() throws {
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u1", memberType: .owner, updateDt: 1))
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u2", memberType: .normal, updateDt: 2))
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u3", memberType: .removed, updateDt: 3))

        let members = try store.members(groupId: "g1")

        XCTAssertEqual(Set(members.map(\.memberId)), ["u1", "u2"])
    }

    func test_upsertMember_overwritesExistingRowForSamePair() throws {
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u1", memberType: .normal, updateDt: 1))
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u1", memberType: .owner, updateDt: 2))

        let members = try store.members(groupId: "g1")

        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.memberType, .owner)
    }

    func test_membersPublisher_emitsOnUpsert() throws {
        var receivedCounts: [Int] = []
        let expectation = expectation(description: "received 2 emissions")
        expectation.expectedFulfillmentCount = 2

        store.membersPublisher(groupId: "g1")
            .sink(receiveCompletion: { _ in }, receiveValue: { members in
                receivedCounts.append(members.count)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u1", memberType: .owner, updateDt: 1))

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(receivedCounts, [0, 1])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GroupStoreTests`
Expected: FAIL — `GroupStore` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMStorage/GroupStore.swift
import GRDB
import Combine

/// CRUD + Combine observation for `StoredGroup`/`StoredGroupMember`.
public final class GroupStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func upsertGroup(_ group: StoredGroup) throws {
        try dbQueue.write { db in try group.save(db) }
    }

    public func group(groupId: String) throws -> StoredGroup? {
        try dbQueue.read { db in try StoredGroup.fetchOne(db, key: groupId) }
    }

    public func groupPublisher(groupId: String) -> AnyPublisher<StoredGroup?, Error> {
        ValueObservation
            .tracking { db in try StoredGroup.fetchOne(db, key: groupId) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    public func upsertMember(_ member: StoredGroupMember) throws {
        try dbQueue.write { db in try member.save(db) }
    }

    private static func activeMembersQuery(groupId: String) -> QueryInterfaceRequest<StoredGroupMember> {
        StoredGroupMember
            .filter(Column("groupId") == groupId)
            .filter(Column("memberType") != GroupMemberType.removed.rawValue)
    }

    public func members(groupId: String) throws -> [StoredGroupMember] {
        try dbQueue.read { db in try Self.activeMembersQuery(groupId: groupId).fetchAll(db) }
    }

    public func membersPublisher(groupId: String) -> AnyPublisher<[StoredGroupMember], Error> {
        ValueObservation
            .tracking { db in try Self.activeMembersQuery(groupId: groupId).fetchAll(db) }
            .publisher(in: dbQueue, scheduling: .immediate)
            .eraseToAnyPublisher()
    }
}
```

In `Sources/IMStorage/IMStorage.swift`, add the new store:

```swift
    public let friendRequests: FriendRequestStore
    public let groups: GroupStore
```

and in `init`:

```swift
        friendRequests = FriendRequestStore(dbQueue: database.dbQueue)
        groups = GroupStore(dbQueue: database.dbQueue)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GroupStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMStorage/GroupStore.swift Sources/IMStorage/IMStorage.swift Tests/IMStorageTests/GroupStoreTests.swift
git commit -m "feat(storage): add GroupStore and wire it into IMStorage"
```

---

## Part B — `IMGroups` module (new SPM target)

### Task 7: Add the `IMGroups` target to `Package.swift`

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the target**

In `Package.swift`, add to `products`:

```swift
        .library(name: "IMGroups", targets: ["IMGroups"]),
```

(insert after the `IMContacts` product line). Add to `targets`, after the `IMContacts` test target block:

```swift
        .target(name: "IMGroups", dependencies: ["IMClient", "IMStorage", "IMProto", "IMTransport"]),
        .testTarget(name: "IMGroupsTests", dependencies: ["IMGroups"]),
```

Also add `"IMGroups"` to `IMKit`'s dependency list (it currently reads `dependencies: ["IMStorage", "IMContacts", "IMMessaging", "IMMedia"]`) and to `AppCore`'s (`dependencies: ["IMClient", "IMStorage", "IMMessaging", "IMContacts", "IMMedia"]`):

```swift
        .target(name: "IMKit", dependencies: ["IMStorage", "IMContacts", "IMMessaging", "IMMedia", "IMGroups"]),
        ...
        .target(name: "AppCore", dependencies: ["IMClient", "IMStorage", "IMMessaging", "IMContacts", "IMMedia", "IMGroups"]),
```

- [ ] **Step 2: Verify the package still resolves**

Run: `swift package resolve && swift build`
Expected: builds successfully (the new target has no source files yet, so it builds an empty module — SwiftPM allows this once at least a placeholder exists; if `swift build` errors with "target has no source files", create an empty `Sources/IMGroups/.gitkeep`-adjacent placeholder by proceeding straight to Task 8, which adds the first real file).

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "feat: add IMGroups SPM target"
```

---

### Task 8: `GroupActionTracker` (Void-result tracker, mirrors `FriendRequestActionTracker`)

**Files:**
- Create: `Sources/IMGroups/GroupActionTracker.swift`
- Create: `Tests/IMGroupsTests/Support/FakeTransportConnection.swift` (needed by every test in this module from here on)
- Test: `Tests/IMGroupsTests/GroupActionTrackerTests.swift`

- [ ] **Step 1: Add the shared test fake**

```swift
// Tests/IMGroupsTests/Support/FakeTransportConnection.swift
import Foundation
import IMClient

/// Local duplicate of `IMClientTests`'s `FakeTransportConnection` — see
/// `IMContactsTests`'s copy for why each test target keeps its own.
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

- [ ] **Step 2: Write the failing test**

```swift
// Tests/IMGroupsTests/GroupActionTrackerTests.swift
import XCTest
import IMClient
@testable import IMGroups

final class GroupActionTrackerTests: XCTestCase {
    func test_track_thenResolveSuccess_invokesCompletionWithSuccess() {
        let scheduler = ManualScheduler()
        let tracker = GroupActionTracker(scheduler: scheduler)
        var result: Result<Void, GroupActionTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        tracker.resolve(wireMessageId: 1, result: .success(()))

        switch result {
        case .success: break
        default: XCTFail("expected success, got \(String(describing: result))")
        }
    }

    func test_track_thenResolveFailure_invokesCompletionWithServerError() {
        let scheduler = ManualScheduler()
        let tracker = GroupActionTracker(scheduler: scheduler)
        var result: Result<Void, GroupActionTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        tracker.resolve(wireMessageId: 1, result: .failure(.serverError(errorCode: 5)))

        XCTAssertEqual(result, .failure(.serverError(errorCode: 5)))
    }

    func test_timeoutFires_resolvesAsTimeout() {
        let scheduler = ManualScheduler()
        let tracker = GroupActionTracker(scheduler: scheduler)
        var result: Result<Void, GroupActionTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        scheduler.fireNext()

        XCTAssertEqual(result, .failure(.timeout))
    }

    func test_resolve_forUntrackedId_isNoOp() {
        let scheduler = ManualScheduler()
        let tracker = GroupActionTracker(scheduler: scheduler)
        tracker.resolve(wireMessageId: 99, result: .success(())) // must not crash
    }
}
```

(This test needs `Result<Void, GroupActionTracker.TrackerError>` to be `Equatable` for the `XCTAssertEqual` calls — `Result` is `Equatable` when both its `Success` and `Failure` types are, and `Void` is not `Equatable` by default, so `test_track_thenResolveSuccess...` uses a `switch` instead, matching `FriendRequestActionHandlerTests`'s existing convention for the same reason.)

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter GroupActionTrackerTests`
Expected: FAIL — `GroupActionTracker` not found.

- [ ] **Step 4: Implement**

```swift
// Sources/IMGroups/GroupActionTracker.swift
import IMClient

/// Correlates an outgoing group-action request (`.gam`/`.gkm`/`.gmi`/`.gq`/
/// `.gd`) to its response by wire `messageId`. Every one of these gets a
/// bare "1 byte error code, no payload" response (confirmed by reading
/// `AddGroupMember`/`KickoffGroupMember`/`ModifyGroupInfoHandler`/
/// `QuitGroupHandler`/`DismissGroupHandler` in `chat-server-pro`: none of
/// them ever write to `ackPayload`), so this tracker resolves to plain
/// `Void` on success — exact mirror of `IMContacts`'s
/// `FriendRequestActionTracker`.
public final class GroupActionTracker {
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

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter GroupActionTrackerTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMGroups/GroupActionTracker.swift Tests/IMGroupsTests/GroupActionTrackerTests.swift Tests/IMGroupsTests/Support/FakeTransportConnection.swift
git commit -m "feat(groups): add GroupActionTracker"
```

---

### Task 9: `GroupActionHandler` (parses `.gam`/`.gkm`/`.gmi`/`.gq`/`.gd` PUB_ACK)

**Files:**
- Create: `Sources/IMGroups/GroupActionHandler.swift`
- Test: `Tests/IMGroupsTests/GroupActionHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMGroupsTests/GroupActionHandlerTests.swift
import XCTest
import IMClient
import IMTransport
@testable import IMGroups

final class GroupActionHandlerTests: XCTestCase {
    private var tracker: GroupActionTracker!
    private var handler: GroupActionHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tracker = GroupActionTracker(scheduler: ManualScheduler())
        handler = GroupActionHandler(tracker: tracker)
    }

    func test_canHandle_matchesAllFiveGroupActionSubSignals() {
        for subSignal: SubSignal in [.gam, .gkm, .gmi, .gq, .gd] {
            XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: subSignal))
        }
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .gc))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .gam))
    }

    func test_handle_zeroErrorCode_resolvesSuccess() {
        var result: Result<Void, GroupActionTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result = $0 }

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gam, bodyLength: 1, messageId: 7), body: Data([0x00])))

        switch result {
        case .success: break
        default: XCTFail("expected success, got \(String(describing: result))")
        }
    }

    func test_handle_nonZeroErrorCode_resolvesServerError() {
        var result: Result<Void, GroupActionTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result = $0 }

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gkm, bodyLength: 1, messageId: 7), body: Data([0x03])))

        XCTAssertEqual(result, .failure(.serverError(errorCode: 3)))
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gq, bodyLength: 0, messageId: 7), body: Data()))
        // no tracked entry, no crash — nothing to assert beyond "didn't crash"
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GroupActionHandlerTests`
Expected: FAIL — `GroupActionHandler` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMGroups/GroupActionHandler.swift
import IMClient
import IMTransport

/// Parses the bare "1 byte error code, no payload" response shared by
/// `.gam` (add member)/`.gkm` (kick member)/`.gmi` (modify group info)/
/// `.gq` (quit group)/`.gd` (dismiss group) and resolves the matching
/// `GroupActionTracker` entry. One handler covers all five since
/// `IMClient.sendFrame`'s `nextMessageId` is a single incrementing counter
/// shared across every outgoing frame — exact mirror of `IMContacts`'s
/// `FriendRequestActionHandler`.
public final class GroupActionHandler: MessageHandler {
    private let tracker: GroupActionTracker

    public init(tracker: GroupActionTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && (subSignal == .gam || subSignal == .gkm || subSignal == .gmi || subSignal == .gq || subSignal == .gd)
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

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GroupActionHandlerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMGroups/GroupActionHandler.swift Tests/IMGroupsTests/GroupActionHandlerTests.swift
git commit -m "feat(groups): add GroupActionHandler"
```

---

### Task 10: `GroupCreateTracker` (String-result tracker, mirrors `UserSearchTracker`)

**Files:**
- Create: `Sources/IMGroups/GroupCreateTracker.swift`
- Test: `Tests/IMGroupsTests/GroupCreateTrackerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMGroupsTests/GroupCreateTrackerTests.swift
import XCTest
import IMClient
@testable import IMGroups

final class GroupCreateTrackerTests: XCTestCase {
    func test_track_thenResolveSuccess_invokesCompletionWithGroupId() {
        let scheduler = ManualScheduler()
        let tracker = GroupCreateTracker(scheduler: scheduler)
        var result: Result<String, GroupCreateTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        tracker.resolve(wireMessageId: 1, result: .success("g1"))

        XCTAssertEqual(result, .success("g1"))
    }

    func test_track_thenResolveFailure_invokesCompletionWithServerError() {
        let scheduler = ManualScheduler()
        let tracker = GroupCreateTracker(scheduler: scheduler)
        var result: Result<String, GroupCreateTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        tracker.resolve(wireMessageId: 1, result: .failure(.serverError(errorCode: 2)))

        XCTAssertEqual(result, .failure(.serverError(errorCode: 2)))
    }

    func test_timeoutFires_resolvesAsTimeout() {
        let scheduler = ManualScheduler()
        let tracker = GroupCreateTracker(scheduler: scheduler)
        var result: Result<String, GroupCreateTracker.TrackerError>?

        tracker.track(wireMessageId: 1) { result = $0 }
        scheduler.fireNext()

        XCTAssertEqual(result, .failure(.timeout))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GroupCreateTrackerTests`
Expected: FAIL — `GroupCreateTracker` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMGroups/GroupCreateTracker.swift
import IMClient

/// Correlates an outgoing `.gc` (create group) request to its response by
/// wire `messageId` — same shape as `IMContacts`'s `UserSearchTracker`. The
/// success payload is the server-assigned group id string;
/// `GroupCreateHandler` decodes it from the raw ack bytes before resolving
/// this tracker.
public final class GroupCreateTracker {
    public enum TrackerError: Error, Equatable {
        case serverError(errorCode: Int32)
        case malformedResponse
        case timeout
    }

    private final class Pending {
        let completion: (Result<String, TrackerError>) -> Void
        var timeoutToken: SchedulerToken?

        init(completion: @escaping (Result<String, TrackerError>) -> Void) {
            self.completion = completion
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, completion: @escaping (Result<String, TrackerError>) -> Void) {
        let entry = Pending(completion: completion)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.resolve(wireMessageId: wireMessageId, result: .failure(.timeout))
        }
        pending[wireMessageId] = entry
    }

    public func resolve(wireMessageId: UInt16, result: Result<String, TrackerError>) {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return }
        entry.timeoutToken?.cancel()
        entry.completion(result)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GroupCreateTrackerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMGroups/GroupCreateTracker.swift Tests/IMGroupsTests/GroupCreateTrackerTests.swift
git commit -m "feat(groups): add GroupCreateTracker"
```

---

### Task 11: `GroupCreateHandler` (parses `.gc` PUB_ACK — raw UTF-8 group id bytes)

**Files:**
- Create: `Sources/IMGroups/GroupCreateHandler.swift`
- Test: `Tests/IMGroupsTests/GroupCreateHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMGroupsTests/GroupCreateHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import Foundation
@testable import IMGroups

final class GroupCreateHandlerTests: XCTestCase {
    private var tracker: GroupCreateTracker!
    private var handler: GroupCreateHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tracker = GroupCreateTracker(scheduler: ManualScheduler())
        handler = GroupCreateHandler(tracker: tracker)
    }

    func test_canHandle_onlyMatchesPubAckAndGC() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .gc))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .gam))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .gc))
    }

    func test_handle_zeroErrorCode_resolvesWithGroupIdDecodedFromRawUTF8Bytes() {
        var result: Result<String, GroupCreateTracker.TrackerError>?
        tracker.track(wireMessageId: 1) { result = $0 }
        let body = Data([0x00]) + Data("g12345".utf8)

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gc, bodyLength: UInt32(body.count), messageId: 1), body: body))

        XCTAssertEqual(result, .success("g12345"))
    }

    func test_handle_nonZeroErrorCode_resolvesServerError() {
        var result: Result<String, GroupCreateTracker.TrackerError>?
        tracker.track(wireMessageId: 1) { result = $0 }

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gc, bodyLength: 1, messageId: 1), body: Data([0x01])))

        XCTAssertEqual(result, .failure(.serverError(errorCode: 1)))
    }

    func test_handle_zeroErrorCodeButEmptyTrailingBytes_resolvesMalformedResponse() {
        var result: Result<String, GroupCreateTracker.TrackerError>?
        tracker.track(wireMessageId: 1) { result = $0 }

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gc, bodyLength: 1, messageId: 1), body: Data([0x00])))

        XCTAssertEqual(result, .failure(.malformedResponse))
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gc, bodyLength: 0, messageId: 1), body: Data()))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GroupCreateHandlerTests`
Expected: FAIL — `GroupCreateHandler` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMGroups/GroupCreateHandler.swift
import IMClient
import IMTransport
import Foundation

/// Parses the `.gc` (create group) response and resolves the matching
/// `GroupCreateTracker` entry. **Wire format:** like every `PUB_ACK`, 1 byte
/// error code, then — only here, unlike every other group action — the
/// server-assigned group id as raw UTF-8 bytes (confirmed by reading
/// `CreateGroupHandler.java`: `byte[] data = groupInfo.getTarget().getBytes();
/// ackPayload.ensureWritable(data.length).writeBytes(data);`). Not protobuf,
/// not the fixed-width binary `MessageSendAckHandler` uses — a third
/// distinct ack shape, each handled by its own dedicated handler.
public final class GroupCreateHandler: MessageHandler {
    private let tracker: GroupCreateTracker

    public init(tracker: GroupCreateTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .gc
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        if errorCode == 0 {
            let groupIdBytes = frame.body.dropFirst()
            guard let groupId = String(data: groupIdBytes, encoding: .utf8), !groupId.isEmpty else {
                tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.malformedResponse))
                return
            }
            tracker.resolve(wireMessageId: frame.header.messageId, result: .success(groupId))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.serverError(errorCode: Int32(errorCode))))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GroupCreateHandlerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMGroups/GroupCreateHandler.swift Tests/IMGroupsTests/GroupCreateHandlerTests.swift
git commit -m "feat(groups): add GroupCreateHandler"
```

---

### Task 12: `GroupInfoSyncHandler` (parses `.gpgi` PUB_ACK — self-identifying, no tracker needed)

**Files:**
- Create: `Sources/IMGroups/GroupInfoSyncHandler.swift`
- Test: `Tests/IMGroupsTests/GroupInfoSyncHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMGroupsTests/GroupInfoSyncHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMGroups

final class GroupInfoSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: GroupInfoSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = GroupInfoSyncHandler(storage: storage)
    }

    private func makeFrame(infos: [Im_GroupInfo]) throws -> Frame {
        var result = Im_PullGroupInfoResult()
        result.info = infos
        let body = Data([0x00]) + (try result.serializedData())
        return Frame(header: Header(signal: .pubAck, subSignal: .gpgi, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndGPGI() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .gpgi))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .gpgm))
    }

    func test_handle_upsertsEachGroupBySelfIdentifyingTargetId() throws {
        var info = Im_GroupInfo()
        info.targetID = "g1"
        info.name = "Group One"
        info.owner = "u1"
        info.type = 0
        info.memberCount = 3
        info.updateDt = 100
        info.memberUpdateDt = 50

        handler.handle(frame: try makeFrame(infos: [info]))

        let group = try storage.groups.group(groupId: "g1")
        XCTAssertEqual(group?.name, "Group One")
        XCTAssertEqual(group?.owner, "u1")
        XCTAssertEqual(group?.groupType, .normal)
        XCTAssertEqual(group?.memberCount, 3)
        XCTAssertEqual(group?.updateDt, 100)
        XCTAssertEqual(group?.memberUpdateDt, 50)
    }

    func test_handle_unsetOptionalFields_decodeAsNil() throws {
        var info = Im_GroupInfo()
        info.targetID = "g1"
        info.name = "Group One"
        info.type = 1 // free — no owner

        handler.handle(frame: try makeFrame(infos: [info]))

        let group = try storage.groups.group(groupId: "g1")
        XCTAssertNil(group?.owner)
        XCTAssertNil(group?.portrait)
        XCTAssertEqual(group?.groupType, .free)
    }

    func test_handle_nonZeroErrorCode_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gpgi, bodyLength: 1, messageId: 1), body: Data([0x01])))
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gpgi, bodyLength: 0, messageId: 1), body: Data()))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GroupInfoSyncHandlerTests`
Expected: FAIL — `GroupInfoSyncHandler` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMGroups/GroupInfoSyncHandler.swift
import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `.gpgi` (pull group info) response and upserts each group
/// into `GroupStore`. Same "1 byte error code, then protobuf" wire format
/// as every other `PUB_ACK` handler. Each `Im_GroupInfo` self-identifies via
/// its own `target_id` field (unlike `.gpgm`'s member result, which doesn't
/// — see `GroupMemberSyncHandler`'s doc comment), so no request/response
/// correlation tracker is needed here — same shape as `IMContacts`'s
/// `UserInfoSyncHandler`.
public final class GroupInfoSyncHandler: MessageHandler {
    private let storage: IMStorage

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .gpgi
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_PullGroupInfoResult(serializedBytes: frame.body.dropFirst()) else { return }
        for info in result.info {
            // Accepted gap: a failed upsert for one group is silently
            // dropped (no logging facility yet), same as every other
            // best-effort handler in this codebase.
            try? storage.groups.upsertGroup(StoredGroup(
                groupId: info.targetID,
                name: info.name,
                portrait: info.hasPortrait ? info.portrait : nil,
                owner: info.hasOwner ? info.owner : nil,
                groupType: GroupType(rawValue: Int(info.type)) ?? .normal,
                memberCount: Int(info.memberCount),
                updateDt: info.updateDt,
                memberUpdateDt: info.memberUpdateDt
            ))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GroupInfoSyncHandlerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMGroups/GroupInfoSyncHandler.swift Tests/IMGroupsTests/GroupInfoSyncHandlerTests.swift
git commit -m "feat(groups): add GroupInfoSyncHandler"
```

---

### Task 13: `GroupMemberSyncTracker` (wireMessageId → groupId correlation, no completion)

**Files:**
- Create: `Sources/IMGroups/GroupMemberSyncTracker.swift`
- Test: `Tests/IMGroupsTests/GroupMemberSyncTrackerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMGroupsTests/GroupMemberSyncTrackerTests.swift
import XCTest
import IMClient
@testable import IMGroups

final class GroupMemberSyncTrackerTests: XCTestCase {
    func test_track_thenResolve_returnsTheTrackedGroupId() {
        let tracker = GroupMemberSyncTracker(scheduler: ManualScheduler())
        tracker.track(wireMessageId: 1, groupId: "g1")

        XCTAssertEqual(tracker.resolve(wireMessageId: 1), "g1")
    }

    func test_resolve_consumesTheEntry_secondResolveReturnsNil() {
        let tracker = GroupMemberSyncTracker(scheduler: ManualScheduler())
        tracker.track(wireMessageId: 1, groupId: "g1")
        _ = tracker.resolve(wireMessageId: 1)

        XCTAssertNil(tracker.resolve(wireMessageId: 1))
    }

    func test_resolve_forUntrackedId_returnsNil() {
        let tracker = GroupMemberSyncTracker(scheduler: ManualScheduler())
        XCTAssertNil(tracker.resolve(wireMessageId: 99))
    }

    func test_timeoutFires_dropsTheEntry() {
        let scheduler = ManualScheduler()
        let tracker = GroupMemberSyncTracker(scheduler: scheduler)
        tracker.track(wireMessageId: 1, groupId: "g1")

        scheduler.fireNext()

        XCTAssertNil(tracker.resolve(wireMessageId: 1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GroupMemberSyncTrackerTests`
Expected: FAIL — `GroupMemberSyncTracker` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMGroups/GroupMemberSyncTracker.swift
import IMClient

/// Correlates an outgoing `.gpgm` (pull group member) request to the
/// `groupId` it was asking about. Unlike every other tracker in this
/// codebase, there's no completion callback — `Im_PullGroupMemberResult`
/// has no `target`/group-id field of its own (confirmed by reading
/// `PullGroupMemberResult` in `FSCMessage.proto`: `repeated GroupMember
/// member = 1;`, nothing else), so `GroupMemberSyncHandler` needs *some*
/// way to know which group the returned members belong to — this tracker
/// is that correlation, not a request/response result carrier.
/// `GroupSyncService.refreshMembers` is fire-and-forget by design (see its
/// doc comment), so a timed-out entry is just dropped, never reported as a
/// failure to anyone.
public final class GroupMemberSyncTracker {
    private final class Pending {
        let groupId: String
        var timeoutToken: SchedulerToken?
        init(groupId: String) {
            self.groupId = groupId
        }
    }

    private let scheduler: Scheduler
    private var pending: [UInt16: Pending] = [:]

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    public func track(wireMessageId: UInt16, groupId: String) {
        let entry = Pending(groupId: groupId)
        entry.timeoutToken = scheduler.scheduleOnce(after: 5) { [weak self] in
            self?.pending.removeValue(forKey: wireMessageId)
        }
        pending[wireMessageId] = entry
    }

    @discardableResult
    public func resolve(wireMessageId: UInt16) -> String? {
        guard let entry = pending.removeValue(forKey: wireMessageId) else { return nil }
        entry.timeoutToken?.cancel()
        return entry.groupId
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GroupMemberSyncTrackerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMGroups/GroupMemberSyncTracker.swift Tests/IMGroupsTests/GroupMemberSyncTrackerTests.swift
git commit -m "feat(groups): add GroupMemberSyncTracker"
```

---

### Task 14: `GroupMemberSyncHandler` (parses `.gpgm` PUB_ACK, tags members via tracker)

**Files:**
- Create: `Sources/IMGroups/GroupMemberSyncHandler.swift`
- Test: `Tests/IMGroupsTests/GroupMemberSyncHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMGroupsTests/GroupMemberSyncHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMGroups

final class GroupMemberSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var tracker: GroupMemberSyncTracker!
    private var handler: GroupMemberSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        tracker = GroupMemberSyncTracker(scheduler: ManualScheduler())
        handler = GroupMemberSyncHandler(storage: storage, tracker: tracker)
    }

    private func makeFrame(members: [Im_GroupMember], messageId: UInt16, errorCode: UInt8 = 0) throws -> Frame {
        var result = Im_PullGroupMemberResult()
        result.member = members
        var body = Data([errorCode])
        if errorCode == 0 { body += try result.serializedData() }
        return Frame(header: Header(signal: .pubAck, subSignal: .gpgm, bodyLength: UInt32(body.count), messageId: messageId), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndGPGM() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .gpgm))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .gpgi))
    }

    func test_handle_tagsEachMemberWithTheTrackedGroupId() throws {
        tracker.track(wireMessageId: 5, groupId: "g1")
        var member = Im_GroupMember()
        member.memberID = "u2"
        member.type = 2 // owner
        member.updateDt = 100

        handler.handle(frame: try makeFrame(members: [member], messageId: 5))

        let members = try storage.groups.members(groupId: "g1")
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.memberId, "u2")
        XCTAssertEqual(members.first?.memberType, .owner)
        XCTAssertEqual(members.first?.updateDt, 100)
    }

    func test_handle_withoutATrackedEntry_doesNothingNoCrash() throws {
        var member = Im_GroupMember()
        member.memberID = "u2"

        handler.handle(frame: try makeFrame(members: [member], messageId: 99)) // never tracked

        XCTAssertEqual(try storage.groups.members(groupId: "g1"), [])
    }

    func test_handle_nonZeroErrorCode_stillConsumesTrackerEntryButWritesNothing() throws {
        tracker.track(wireMessageId: 5, groupId: "g1")

        handler.handle(frame: try makeFrame(members: [], messageId: 5, errorCode: 1))

        XCTAssertNil(tracker.resolve(wireMessageId: 5)) // already consumed, not left dangling
        XCTAssertEqual(try storage.groups.members(groupId: "g1"), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GroupMemberSyncHandlerTests`
Expected: FAIL — `GroupMemberSyncHandler` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMGroups/GroupMemberSyncHandler.swift
import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `.gpgm` (pull group member) response and upserts each member,
/// tagged with the `groupId` resolved from `GroupMemberSyncTracker` (see
/// that type's doc comment for why a tracker is needed here when no other
/// `PUB_ACK` handler needs one).
public final class GroupMemberSyncHandler: MessageHandler {
    private let storage: IMStorage
    private let tracker: GroupMemberSyncTracker

    public init(storage: IMStorage, tracker: GroupMemberSyncTracker) {
        self.storage = storage
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .gpgm
    }

    public func handle(frame: Frame) {
        // Resolved unconditionally (before checking the error code) so a
        // server-error response still consumes the tracked entry rather
        // than leaking it until the 5-second timeout.
        guard let groupId = tracker.resolve(wireMessageId: frame.header.messageId) else { return }
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_PullGroupMemberResult(serializedBytes: frame.body.dropFirst()) else { return }
        for member in result.member {
            try? storage.groups.upsertMember(StoredGroupMember(
                groupId: groupId,
                memberId: member.memberID,
                memberType: GroupMemberType(rawValue: Int(member.type)) ?? .normal,
                updateDt: member.updateDt
            ))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GroupMemberSyncHandlerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMGroups/GroupMemberSyncHandler.swift Tests/IMGroupsTests/GroupMemberSyncHandlerTests.swift
git commit -m "feat(groups): add GroupMemberSyncHandler"
```

---

### Task 15: `GroupSyncService` (public entry point — combines everything above)

**Files:**
- Create: `Sources/IMGroups/GroupSyncService.swift`
- Test: `Tests/IMGroupsTests/GroupSyncServiceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMGroupsTests/GroupSyncServiceTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMGroups

final class GroupSyncServiceTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var scheduler: ManualScheduler!
    private var service: GroupSyncService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        scheduler = ManualScheduler()
        service = GroupSyncService(imClient: imClient, storage: storage, scheduler: scheduler)

        imClient.connect()
        fakeTransport.simulate(.connected)
    }

    private func decodeOnlySentFrame() throws -> Frame {
        try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
    }

    func test_createGroup_sendsGroupNameAndMembersIncludingSelfAsOwner() throws {
        service.createGroup(name: "My Group", memberIds: ["u2", "u3"]) { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gc)
        let request = try Im_CreateGroupRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.group.groupInfo.name, "My Group")
        let memberIds = request.group.members.map(\.memberID)
        XCTAssertEqual(Set(memberIds), ["me", "u2", "u3"])
        let owner = request.group.members.first { $0.memberID == "me" }
        XCTAssertEqual(owner?.type, 2) // GroupMemberType.owner
    }

    func test_createGroup_onSuccess_resolvesWithServerAssignedGroupId() throws {
        var capturedResult: Result<String, Error>?
        service.createGroup(name: "My Group", memberIds: []) { capturedResult = $0 }

        let sentFrame = try decodeOnlySentFrame()
        let body = Data([0x00]) + Data("g999".utf8)
        let ackBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .gc, messageId: sentFrame.header.messageId, body: body)
        fakeTransport.simulateReceivedData(ackBytes)

        switch capturedResult {
        case .success(let groupId): XCTAssertEqual(groupId, "g999")
        default: XCTFail("expected success, got \(String(describing: capturedResult))")
        }
    }

    func test_addMembers_sendsGroupIdAndMemberList() throws {
        service.addMembers(groupId: "g1", memberIds: ["u2"]) { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gam)
        let request = try Im_AddGroupMemberRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
        XCTAssertEqual(request.addedMember.map(\.memberID), ["u2"])
    }

    func test_kickMember_sendsGroupIdAndRemovedMemberList() throws {
        service.kickMember(groupId: "g1", memberId: "u2") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gkm)
        let request = try Im_RemoveGroupMemberRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
        XCTAssertEqual(request.removedMember, ["u2"])
    }

    func test_modifyGroupInfo_sendsGroupIdTypeAndValue() throws {
        service.modifyGroupInfo(groupId: "g1", type: .name, value: "New Name") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gmi)
        let request = try Im_ModifyGroupInfoRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
        XCTAssertEqual(request.type, 0)
        XCTAssertEqual(request.value, "New Name")
    }

    func test_quitGroup_sendsGroupId() throws {
        service.quitGroup(groupId: "g1") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gq)
        let request = try Im_QuitGroupRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
    }

    func test_dismissGroup_sendsGroupId() throws {
        service.dismissGroup(groupId: "g1") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gd)
        let request = try Im_DismissGroupRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
    }

    func test_refreshGroup_sendsGPGIThenGPGM() throws {
        service.refreshGroup(targetId: "g1")

        let decoder = FrameDecoder()
        let frames = fakeTransport.sentFrames.flatMap { decoder.feed($0) }
        XCTAssertEqual(frames.map(\.header.subSignal), [.gpgi, .gpgm])
        let gpgiRequest = try Im_PullUserRequest(serializedBytes: frames[0].body)
        XCTAssertEqual(gpgiRequest.request.map(\.uid), ["g1"])
        let gpgmRequest = try Im_PullGroupMemberRequest(serializedBytes: frames[1].body)
        XCTAssertEqual(gpgmRequest.target, "g1")
        XCTAssertEqual(gpgmRequest.head, 0)
    }

    func test_refreshMembers_usesStoredMemberUpdateDtAsHead() throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "G1", portrait: nil, owner: nil, groupType: .normal, memberCount: 1, updateDt: 0, memberUpdateDt: 777))

        service.refreshMembers(targetId: "g1")

        let frame = try decodeOnlySentFrame()
        let request = try Im_PullGroupMemberRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.head, 777)
    }

    func test_receivingGPGMResponse_isHandledEndToEnd() throws {
        service.refreshMembers(targetId: "g1")
        let sentFrame = try decodeOnlySentFrame()

        var result = Im_PullGroupMemberResult()
        var member = Im_GroupMember()
        member.memberID = "u2"
        member.type = 0
        result.member = [member]
        let body = Data([0x00]) + (try result.serializedData())
        let ackBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .gpgm, messageId: sentFrame.header.messageId, body: body)

        fakeTransport.simulateReceivedData(ackBytes)

        XCTAssertEqual(try storage.groups.members(groupId: "g1").map(\.memberId), ["u2"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GroupSyncServiceTests`
Expected: FAIL — `GroupSyncService` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMGroups/GroupSyncService.swift
import Foundation
import IMClient
import IMProto
import IMStorage

public enum GroupSyncServiceError: Error, Equatable {
    case requestEncodingFailed
}

/// The single entry point `IMKit`'s `GroupActing`/`GroupSyncing` conformance
/// wraps: registers every group `MessageHandler` with the given `IMClient`,
/// and exposes `createGroup`/`addMembers`/`kickMember`/`modifyGroupInfo`/
/// `quitGroup`/`dismissGroup`/`refreshGroup`/`refreshMembers`. Mirrors
/// `IMContacts`'s `ContactSyncService` shape exactly.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class GroupSyncService {
    private let imClient: IMClient
    private let storage: IMStorage
    private let actionTracker: GroupActionTracker
    private let createTracker: GroupCreateTracker
    private let memberSyncTracker: GroupMemberSyncTracker

    public init(imClient: IMClient, storage: IMStorage, scheduler: Scheduler = DispatchQueueScheduler()) {
        self.imClient = imClient
        self.storage = storage
        actionTracker = GroupActionTracker(scheduler: scheduler)
        createTracker = GroupCreateTracker(scheduler: scheduler)
        memberSyncTracker = GroupMemberSyncTracker(scheduler: scheduler)

        imClient.register(GroupCreateHandler(tracker: createTracker))
        imClient.register(GroupActionHandler(tracker: actionTracker))
        imClient.register(GroupInfoSyncHandler(storage: storage))
        imClient.register(GroupMemberSyncHandler(storage: storage, tracker: memberSyncTracker))
    }

    /// Always creates a `GroupType.normal` group — Phase 2's UI has no
    /// group-type picker (out of scope per the design doc). The creator
    /// must be explicitly included in `group.members` as `.owner`: unlike
    /// e.g. Android's own assumptions, `chat-server-pro`'s
    /// `MemoryMessagesStore.createGroup` does **not** auto-add the creator
    /// (verified by reading it) — omitting this would create a group the
    /// creator isn't even a member of.
    public func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void) {
        var groupInfo = Im_GroupInfo()
        groupInfo.name = name
        groupInfo.type = Int32(GroupType.normal.rawValue)

        var ownerMember = Im_GroupMember()
        ownerMember.memberID = imClient.userId
        ownerMember.type = Int32(GroupMemberType.owner.rawValue)

        var group = Im_Group()
        group.groupInfo = groupInfo
        group.members = [ownerMember] + memberIds.map { uid in
            var member = Im_GroupMember()
            member.memberID = uid
            member.type = Int32(GroupMemberType.normal.rawValue)
            return member
        }

        var request = Im_CreateGroupRequest()
        request.group = group
        guard let body = try? request.serializedData() else {
            completion(.failure(GroupSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gc, body: body)
        createTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    public func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_AddGroupMemberRequest()
        request.groupID = groupId
        request.addedMember = memberIds.map { uid in
            var member = Im_GroupMember()
            member.memberID = uid
            member.type = Int32(GroupMemberType.normal.rawValue)
            return member
        }
        sendActionRequest(request, subSignal: .gam, completion: completion)
    }

    public func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_RemoveGroupMemberRequest()
        request.groupID = groupId
        request.removedMember = [memberId]
        sendActionRequest(request, subSignal: .gkm, completion: completion)
    }

    public func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_ModifyGroupInfoRequest()
        request.groupID = groupId
        request.type = type.rawValue
        request.value = value
        sendActionRequest(request, subSignal: .gmi, completion: completion)
    }

    public func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_QuitGroupRequest()
        request.groupID = groupId
        sendActionRequest(request, subSignal: .gq, completion: completion)
    }

    public func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_DismissGroupRequest()
        request.groupID = groupId
        sendActionRequest(request, subSignal: .gd, completion: completion)
    }

    private func sendActionRequest<M: SwiftProtobufMessage>(_ request: M, subSignal: SubSignal, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let body = try? request.serializedData() else {
            completion(.failure(GroupSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: subSignal, body: body)
        actionTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    /// Pulls fresh group info, then fresh member info. Fire-and-forget —
    /// callers observe `IMStorage.groups`'s Combine publishers for the
    /// result rather than receiving a completion here, since both
    /// underlying handlers (`GroupInfoSyncHandler`/`GroupMemberSyncHandler`)
    /// write straight to `GroupStore`.
    public func refreshGroup(targetId: String) {
        var userRequest = Im_UserRequest()
        userRequest.uid = targetId
        var request = Im_PullUserRequest()
        request.request = [userRequest]
        if let body = try? request.serializedData() {
            imClient.sendFrame(signal: .publish, subSignal: .gpgi, body: body)
        }
        refreshMembers(targetId: targetId)
    }

    /// Incremental pull: sends the locally stored `memberUpdateDt` as
    /// `head` so the server only returns members changed since the last
    /// sync, same incremental-pull shape as `IMContacts`'s
    /// `syncFriendRequests()`.
    public func refreshMembers(targetId: String) {
        let head = (try? storage.groups.group(groupId: targetId))?.memberUpdateDt ?? 0
        var request = Im_PullGroupMemberRequest()
        request.target = targetId
        request.head = head
        guard let body = try? request.serializedData() else { return }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gpgm, body: body)
        memberSyncTracker.track(wireMessageId: wireMessageId, groupId: targetId)
    }
}
```

**Note:** `sendActionRequest`'s generic constraint must reference the actual protocol `SwiftProtobufMessage` conforms to in this codebase's vendored/generated protobuf code (`SwiftProtobuf.Message` from the `SwiftProtobuf` package — add `import SwiftProtobuf` and use `SwiftProtobuf.Message` as the constraint, matching how the generated `Im_*` types already conform to it). If this generic helper doesn't compile cleanly against the exact `SwiftProtobuf.Message` API, inline the four-line `serializedData()`/`sendFrame`/`track` body directly into `addMembers`/`kickMember`/`modifyGroupInfo`/`quitGroup`/`dismissGroup` instead (same code duplicated 5×) — prefer that over fighting the generic constraint, since none of this codebase's other services use a shared generic helper for this (`ContactSyncService` repeats the same 4 lines per method).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GroupSyncServiceTests`
Expected: PASS

- [ ] **Step 5: Run the full `IMGroups` test suite**

Run: `swift test --filter IMGroupsTests`
Expected: PASS (all tasks 8–15)

- [ ] **Step 6: Commit**

```bash
git add Sources/IMGroups/GroupSyncService.swift Tests/IMGroupsTests/GroupSyncServiceTests.swift
git commit -m "feat(groups): add GroupSyncService"
```

---

## Part C — `IMMessaging`: @mention + group-notification decode

### Task 16: `MessageContentCodec` — encode mention fields, decode group-notification kinds

**Files:**
- Modify: `Sources/IMMessaging/MessageContentCodec.swift`
- Modify: `Tests/IMMessagingTests/MessageContentCodecTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/IMMessagingTests/MessageContentCodecTests.swift`:

```swift
    func test_encode_text_withMention_setsMentionedTypeAndTargets() {
        let wire = MessageContentCodec.encode(.text("hi"), mentionedType: 1, mentionedTargets: ["u2", "u3"])

        XCTAssertEqual(wire.mentionedType, 1)
        XCTAssertEqual(wire.mentionedTarget, ["u2", "u3"])
    }

    func test_encode_text_withoutMention_leavesMentionedFieldsUnset() {
        let wire = MessageContentCodec.encode(.text("hi"))

        XCTAssertFalse(wire.hasMentionedType)
        XCTAssertEqual(wire.mentionedTarget, [])
    }

    func test_decode_createGroup_parsesOperatorNameAndMembers() throws {
        var wire = Im_MessageContent()
        wire.type = 104
        wire.data = Data("""
        {"g":"g1","o":"u1","n":"My Group","ms":["u2","u3"]}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .createGroup, operatorUid: "u1", memberUids: ["u2", "u3"], value: "My Group"))
    }

    func test_decode_addGroupMember_parsesOperatorAndMembers() throws {
        var wire = Im_MessageContent()
        wire.type = 105
        wire.data = Data("""
        {"g":"g1","o":"u1","ms":["u2"]}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .addGroupMember, operatorUid: "u1", memberUids: ["u2"], value: nil))
    }

    func test_decode_kickoffGroupMember_parsesOperatorAndMembers() throws {
        var wire = Im_MessageContent()
        wire.type = 106
        wire.data = Data("""
        {"g":"g1","o":"u1","ms":["u2"]}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .kickoffGroupMember, operatorUid: "u1", memberUids: ["u2"], value: nil))
    }

    func test_decode_quitGroup_neverParsesContentField_leavesOperatorEmpty() throws {
        // The "m" field on the server's fallback encoder is unreliable (Java
        // overload-resolution quirk — see the design doc's flagged risk), so
        // quitGroup is decoded without reading `content` at all; the caller
        // (ReceiveMessageHandler) fills in the operator from `fromUser`.
        var wire = Im_MessageContent()
        wire.type = 107
        wire.content = "anything"

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .quitGroup, operatorUid: "", memberUids: [], value: nil))
    }

    func test_decode_dismissGroup_parsesOperator() throws {
        var wire = Im_MessageContent()
        wire.type = 108
        wire.data = Data("""
        {"g":"g1","o":"u1"}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .dismissGroup, operatorUid: "u1", memberUids: [], value: nil))
    }

    func test_decode_changeGroupName_parsesOperatorAndNewName() throws {
        var wire = Im_MessageContent()
        wire.type = 110
        wire.data = Data("""
        {"g":"g1","o":"u1","n":"New Name"}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .changeGroupName, operatorUid: "u1", memberUids: [], value: "New Name"))
    }

    func test_decode_changeGroupPortrait_parsesOperator() throws {
        var wire = Im_MessageContent()
        wire.type = 112
        wire.data = Data("""
        {"g":"g1","o":"u1"}
        """.utf8)

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .changeGroupPortrait, operatorUid: "u1", memberUids: [], value: nil))
    }

    func test_decode_groupNotification_malformedOrMissingData_fallsBackToEmptyOperator() throws {
        var wire = Im_MessageContent()
        wire.type = 105 // no `data` set at all

        let content = try MessageContentCodec.decode(wire)

        XCTAssertEqual(content, .groupNotification(type: .addGroupMember, operatorUid: "", memberUids: [], value: nil))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MessageContentCodecTests`
Expected: FAIL — `encode` doesn't accept `mentionedType`/`mentionedTargets`; `decode` doesn't handle types 104–112.

- [ ] **Step 3: Implement**

Replace the full contents of `Sources/IMMessaging/MessageContentCodec.swift` with:

```swift
import IMProto
import IMStorage
import Foundation

/// Converts between the wire `Im_MessageContent` protobuf type and
/// `IMStorage.MessageContent`. Field mapping verified against
/// `chat-proto`'s `MessageContent` message and the Android
/// `TextMessageContent`/`ImageMessageContent`/`MediaMessageContent`
/// `encode()`/`decode()` methods:
/// - text: body goes in `searchableContent`, not `content`.
/// - image: `searchableContent` holds a `"[图片]"` digest, `data` holds the
///   thumbnail bytes, `remoteMediaUrl` holds the uploaded image URL.
///   `localPath` is never a wire field — always `nil` on decode.
/// - group notifications: **decode-only.** The client never constructs
///   `notify_content` when sending a group action request (every group
///   action `Handler` in `chat-server-pro` auto-generates it server-side
///   via `GroupNotificationBinaryContent` when the client omits it — see
///   the design doc §2), so `encode(_:)` is never called with a
///   `.groupNotification` case in practice; `decode(_:)` is the only
///   direction that matters for these 7 types.
public enum MessageContentCodec {
    public enum DecodeError: Error, Equatable {
        case unsupportedContentType(Int32)
    }

    /// Server-generated JSON shape for group-notification `data` payloads
    /// (`GroupNotificationBinaryContent`'s Gson fields): `g`=groupId,
    /// `o`=operator uid, `n`=name (createGroup's group name /
    /// changeGroupName's new name), `ms`=affected member uid list. All
    /// optional and independently absent depending on notification kind.
    private struct GroupNotificationWireContent: Decodable {
        let g: String?
        let o: String?
        let n: String?
        let ms: [String]?
    }

    public static func encode(_ content: MessageContent, mentionedType: Int32 = 0, mentionedTargets: [String] = []) -> Im_MessageContent {
        var wire = Im_MessageContent()
        switch content {
        case .text(let text):
            wire.type = 1
            wire.searchableContent = text
        case .image(let thumbnail, let remoteURL, _):
            wire.type = 3
            wire.searchableContent = "[图片]"
            if let thumbnail {
                wire.data = thumbnail
            }
            if let remoteURL {
                wire.remoteMediaURL = remoteURL
            }
        case .groupNotification(let type, _, _, _):
            // Never sent in practice (see this type's doc comment) — set
            // `type` for completeness rather than leave the wire message
            // at its default (text=0-equivalent) value if this is ever
            // called.
            wire.type = Int32(type.rawValue)
        }
        if mentionedType != 0 {
            wire.mentionedType = mentionedType
        }
        if !mentionedTargets.isEmpty {
            wire.mentionedTarget = mentionedTargets
        }
        return wire
    }

    public static func decode(_ wire: Im_MessageContent) throws -> MessageContent {
        switch wire.type {
        case 1:
            return .text(wire.hasSearchableContent ? wire.searchableContent : "")
        case 3:
            return .image(
                thumbnail: wire.hasData ? wire.data : nil,
                remoteURL: wire.hasRemoteMediaURL ? wire.remoteMediaURL : nil,
                localPath: nil
            )
        case 104:
            return decodeGroupNotification(type: .createGroup, wire: wire)
        case 105:
            return decodeGroupNotification(type: .addGroupMember, wire: wire)
        case 106:
            return decodeGroupNotification(type: .kickoffGroupMember, wire: wire)
        case 107:
            return decodeGroupNotification(type: .quitGroup, wire: wire)
        case 108:
            return decodeGroupNotification(type: .dismissGroup, wire: wire)
        case 110:
            return decodeGroupNotification(type: .changeGroupName, wire: wire)
        case 112:
            return decodeGroupNotification(type: .changeGroupPortrait, wire: wire)
        default:
            throw DecodeError.unsupportedContentType(wire.type)
        }
    }

    private static func decodeGroupNotification(type: MessageContentType, wire: Im_MessageContent) -> MessageContent {
        // quitGroup's `m`/content field is unreliable server-side (a Java
        // overload-resolution quirk in `GroupNotificationBinaryContent`
        // picks a different constructor than intended) — never parsed.
        // `ReceiveMessageHandler` fills in `operatorUid` from the wire
        // message's `fromUser` instead.
        guard type != .quitGroup,
              wire.hasData,
              let parsed = try? JSONDecoder().decode(GroupNotificationWireContent.self, from: wire.data)
        else {
            return .groupNotification(type: type, operatorUid: "", memberUids: [], value: nil)
        }

        switch type {
        case .createGroup:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: parsed.ms ?? [], value: parsed.n)
        case .addGroupMember, .kickoffGroupMember:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: parsed.ms ?? [], value: nil)
        case .changeGroupName:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: [], value: parsed.n)
        case .dismissGroup, .changeGroupPortrait:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: [], value: nil)
        case .text, .image, .quitGroup:
            return .groupNotification(type: type, operatorUid: parsed.o ?? "", memberUids: [], value: nil) // unreachable
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MessageContentCodecTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMMessaging/MessageContentCodec.swift Tests/IMMessagingTests/MessageContentCodecTests.swift
git commit -m "feat(messaging): encode mention fields, decode group notification content"
```

---

### Task 17: `ReceiveMessageHandler` — persist mention fields, increment `unreadMentionCount`, fire `onGroupNotificationMessage`

**Files:**
- Modify: `Sources/IMMessaging/ReceiveMessageHandler.swift`
- Modify: `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift` (inside the `ReceiveMessageHandlerTests` class — also update `makeWireMessage` to accept mention params, shown in Step 3's note below):

```swift
    func test_handle_groupMessageMentioningMe_incrementsUnreadMentionCount() throws {
        var message = makeWireMessage(uid: 300, from: "them", target: "g1", text: "hi @me")
        message.conversation.type = 1 // group
        message.content.mentionedType = 1
        message.content.mentionedTarget = ["me"]
        let frame = try makePullResultFrame(messages: [message], head: 300)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .group, target: "g1")
        XCTAssertEqual(conversation?.unreadMentionCount, 1)
        XCTAssertEqual(try storage.messages.message(uid: 300)?.mentionedTargets, ["me"])
    }

    func test_handle_groupMessageMentioningAll_incrementsUnreadMentionCount() throws {
        var message = makeWireMessage(uid: 301, from: "them", target: "g1", text: "hi everyone")
        message.conversation.type = 1 // group
        message.content.mentionedType = 2
        let frame = try makePullResultFrame(messages: [message], head: 301)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .group, target: "g1")
        XCTAssertEqual(conversation?.unreadMentionCount, 1)
    }

    func test_handle_groupMessageMentioningSomeoneElse_doesNotIncrementUnreadMentionCount() throws {
        var message = makeWireMessage(uid: 302, from: "them", target: "g1", text: "hi @other")
        message.conversation.type = 1
        message.content.mentionedType = 1
        message.content.mentionedTarget = ["someone-else"]
        let frame = try makePullResultFrame(messages: [message], head: 302)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .group, target: "g1")
        XCTAssertEqual(conversation?.unreadMentionCount, 0)
    }

    func test_handle_groupNotificationMessage_firesOnGroupNotificationMessageWithGroupId() throws {
        var capturedGroupId: String?
        handler.onGroupNotificationMessage = { capturedGroupId = $0 }

        var message = Im_Message()
        message.messageID = 400
        message.fromUser = "them"
        message.conversation.type = 1 // group
        message.conversation.target = "g1"
        var wireContent = Im_MessageContent()
        wireContent.type = 105 // addGroupMember
        wireContent.data = Data("""
        {"g":"g1","o":"them","ms":["me"]}
        """.utf8)
        message.content = wireContent
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 400)

        handler.handle(frame: frame)

        XCTAssertEqual(capturedGroupId, "g1")
    }

    func test_handle_groupNotificationWithEmptyOperatorInPayload_fallsBackToFromUser() throws {
        var message = Im_Message()
        message.messageID = 401
        message.fromUser = "them"
        message.conversation.type = 1
        message.conversation.target = "g1"
        var wireContent = Im_MessageContent()
        wireContent.type = 107 // quitGroup — never carries a reliable operator in its payload
        message.content = wireContent
        message.serverTimestamp = 1_000
        let frame = try makePullResultFrame(messages: [message], head: 401)

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.messages.message(uid: 401)?.content, .groupNotification(type: .quitGroup, operatorUid: "them", memberUids: [], value: nil))
    }

    func test_handle_singleChatMessage_neverIncrementsUnreadMentionCountEvenIfMentionedTypeSet() throws {
        var message = makeWireMessage(uid: 303, from: "them", target: "them", text: "hi")
        message.content.mentionedType = 2 // shouldn't happen in practice for single chat, but must not crash/miscount
        let frame = try makePullResultFrame(messages: [message], head: 303)

        handler.handle(frame: frame)

        let conversation = try storage.conversations.conversation(conversationType: .single, target: "them")
        XCTAssertEqual(conversation?.unreadMentionCount, 0)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReceiveMessageHandlerTests`
Expected: FAIL — `onGroupNotificationMessage` doesn't exist; mention/unreadMentionCount not wired.

- [ ] **Step 3: Implement**

Replace the full contents of `Sources/IMMessaging/ReceiveMessageHandler.swift` with:

```swift
import Foundation
import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses a `PUB_ACK`/`MP` pulled-message batch, persists new messages,
/// updates the affected conversations, and advances the local sync state.
///
/// **Wire format:** like every `PUB_ACK` response, the body is 1 byte error
/// code followed by the `Im_PullMessageResult` protobuf.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ReceiveMessageHandler: MessageHandler {
    private let storage: IMStorage
    private let myUserId: () -> String

    /// Fired after persisting any message whose decoded content is
    /// `.groupNotification`, with the conversation `target` (the group id)
    /// — the app wires this to `GroupSyncService.refreshGroup(targetId:)`
    /// so a group neither tracked locally nor yet refreshed gets its
    /// metadata/member list populated the first time any notification for
    /// it arrives. Not fired for ordinary text/image messages.
    public var onGroupNotificationMessage: ((String) -> Void)?

    public init(storage: IMStorage, myUserId: @escaping () -> String) {
        self.storage = storage
        self.myUserId = myUserId
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .mp
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_PullMessageResult(serializedBytes: frame.body.dropFirst()) else { return }
        for wireMessage in result.message {
            persist(wireMessage)
        }
        advanceSyncHead(to: result.head)
    }

    private func persist(_ wireMessage: Im_Message) {
        guard wireMessage.messageID != 0 else { return }
        if (try? storage.messages.message(uid: wireMessage.messageID)) != nil {
            return // already have it via server uid — pull windows can overlap
        }

        let direction: MessageDirection = wireMessage.fromUser == myUserId() ? .send : .receive

        if direction == .send, wireMessage.localMessageID != 0,
           (try? storage.messages.message(localMessageId: wireMessage.localMessageID)) != nil {
            try? storage.messages.updateMessageUid(localMessageId: wireMessage.localMessageID, messageUid: wireMessage.messageID)
            try? storage.messages.updateStatus(localMessageId: wireMessage.localMessageID, status: .sent)
            return
        }

        guard var content = try? MessageContentCodec.decode(wireMessage.content) else { return }
        // The server's group-notification fallback payload sometimes omits
        // (or, for quitGroup, never reliably carries) the operator uid —
        // `fromUser` is always the true actor regardless, so it's used
        // whenever the decoded payload came back empty.
        if case .groupNotification(let type, let operatorUid, let memberUids, let value) = content, operatorUid.isEmpty {
            content = .groupNotification(type: type, operatorUid: wireMessage.fromUser, memberUids: memberUids, value: value)
        }

        let conversationType = ConversationType(rawValue: Int(wireMessage.conversation.type)) ?? .single
        let target = wireMessage.conversation.target
        let line = Int(wireMessage.conversation.line)
        let mentionedType = Int(wireMessage.content.mentionedType)
        let mentionedTargets = wireMessage.content.mentionedTarget
        let isMentioned = conversationType == .group && direction == .receive
            && (mentionedType == 2 || (mentionedType == 1 && mentionedTargets.contains(myUserId())))

        do {
            try storage.messages.insert(StoredMessage(
                localMessageId: wireMessage.localMessageID,
                messageUid: wireMessage.messageID,
                conversationType: conversationType,
                target: target,
                line: line,
                from: wireMessage.fromUser,
                content: content,
                timestamp: wireMessage.serverTimestamp,
                status: direction == .send ? .sent : .unread,
                direction: direction,
                mentionedType: mentionedType,
                mentionedTargets: mentionedTargets
            ))
            try storage.conversations.recordIncomingMessage(
                conversationType: conversationType,
                target: target,
                line: line,
                messageUid: wireMessage.messageID,
                timestamp: wireMessage.serverTimestamp,
                incrementUnread: direction == .receive,
                incrementMention: isMentioned
            )
            if case .groupNotification = content {
                onGroupNotificationMessage?(target)
            }
        } catch {
            // Best-effort: one malformed/unexpected row shouldn't abort the rest of the batch.
        }
    }

    private func advanceSyncHead(to head: Int64) {
        guard let current = try? storage.syncState.get(), head > current.msgHead else { return }
        try? storage.syncState.set(StoredSyncState(
            msgHead: head,
            friendHead: current.friendHead,
            friendRequestHead: current.friendRequestHead,
            settingHead: current.settingHead
        ))
    }
}
```

**Note on `makeWireMessage` in the test file:** the existing helper already sets `message.content = MessageContentCodec.encode(.text(text))`, which leaves `mentionedType`/`mentionedTarget` unset — tests above mutate `message.content.mentionedType`/`mentionedTarget` directly after calling `makeWireMessage`, so no change to the helper itself is needed.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReceiveMessageHandlerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMMessaging/ReceiveMessageHandler.swift Tests/IMMessagingTests/ReceiveMessageHandlerTests.swift
git commit -m "feat(messaging): persist mentions, increment unreadMentionCount, notify on group notifications"
```

---

### Task 18: `MessagingService` — mention params on `sendText`, expose `onGroupNotificationMessage`

**Files:**
- Modify: `Sources/IMMessaging/MessagingService.swift`
- Modify: `Tests/IMMessagingTests/MessagingServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/IMMessagingTests/MessagingServiceTests.swift` (check the existing fixture setup for `service`/`storage`/`fakeTransport` names and reuse them, matching the file's established pattern):

```swift
    func test_sendText_withMention_encodesMentionedTypeAndTargetsOnTheWireMessage() throws {
        try service.sendText(to: "g1", conversationType: .group, text: "hi @u2", mentionedType: 1, mentionedTargets: ["u2"])

        let frame = try decodeOnlySentFrame()
        let wireMessage = try Im_Message(serializedBytes: frame.body)
        XCTAssertEqual(wireMessage.content.mentionedType, 1)
        XCTAssertEqual(wireMessage.content.mentionedTarget, ["u2"])
    }

    func test_sendText_withMention_alsoPersistsMentionFieldsLocally() throws {
        try service.sendText(to: "g1", conversationType: .group, text: "hi @u2", mentionedType: 1, mentionedTargets: ["u2"])

        let stored = try storage.messages.messages(conversationType: .group, target: "g1").first
        XCTAssertEqual(stored?.mentionedType, 1)
        XCTAssertEqual(stored?.mentionedTargets, ["u2"])
    }

    func test_onGroupNotificationMessage_forwardsToTheInternalReceiveMessageHandler() throws {
        var capturedGroupId: String?
        service.onGroupNotificationMessage = { capturedGroupId = $0 }

        var wireMessage = Im_Message()
        wireMessage.messageID = 500
        wireMessage.fromUser = "them"
        wireMessage.conversation.type = 1
        wireMessage.conversation.target = "g1"
        var wireContent = Im_MessageContent()
        wireContent.type = 108 // dismissGroup
        wireContent.data = Data("""
        {"g":"g1","o":"them"}
        """.utf8)
        wireMessage.content = wireContent
        wireMessage.serverTimestamp = 1_000

        var result = Im_PullMessageResult()
        result.message = [wireMessage]
        result.head = 500
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .mp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(capturedGroupId, "g1")
    }
```

(If the existing test file's `decodeOnlySentFrame()`/`fakeTransport`/`storage`/`service` names differ slightly, match whatever names `MessagingServiceTests.swift` already uses — read the file first if unsure before pasting this in verbatim.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MessagingServiceTests`
Expected: FAIL — `sendText` doesn't accept `mentionedType`/`mentionedTargets`; `onGroupNotificationMessage` doesn't exist on `MessagingService`.

- [ ] **Step 3: Implement**

In `Sources/IMMessaging/MessagingService.swift`:

Change the stored handler from a local `let` to a stored property so its closure is externally settable:

```swift
    private let imClient: IMClient
    private let storage: IMStorage
    private let tracker: OutgoingMessageTracker
    private let idGenerator: LocalMessageIdGenerator
    private let nowMillis: () -> Int64
    private let receiveMessageHandler: ReceiveMessageHandler

    /// Forwards to the internal `ReceiveMessageHandler`'s own closure of the
    /// same name — see that type's doc comment. Exposed here because
    /// `AppEnvironment` only has a handle on `MessagingService`, not on the
    /// handler instances it registers internally.
    public var onGroupNotificationMessage: ((String) -> Void)? {
        get { receiveMessageHandler.onGroupNotificationMessage }
        set { receiveMessageHandler.onGroupNotificationMessage = newValue }
    }

    public init(
        imClient: IMClient,
        storage: IMStorage,
        scheduler: Scheduler = DispatchQueueScheduler(),
        idGenerator: LocalMessageIdGenerator = LocalMessageIdGenerator(),
        nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.imClient = imClient
        self.storage = storage
        tracker = OutgoingMessageTracker(scheduler: scheduler)
        self.idGenerator = idGenerator
        self.nowMillis = nowMillis

        imClient.register(MessageSendAckHandler(tracker: tracker))
        let receiveHandler = ReceiveMessageHandler(storage: storage, myUserId: { [weak imClient] in imClient?.userId ?? "" })
        receiveMessageHandler = receiveHandler
        imClient.register(receiveHandler)
        let notifyHandler = NotifyMessageHandler()
        notifyHandler.onNotify = { [weak self] head, type in self?.pullMessages(from: head, type: type) }
        imClient.register(notifyHandler)
    }
```

Change `sendText` and the private `send`/`sendWireMessage` methods:

```swift
    public func sendText(to target: String, conversationType: ConversationType = .single, line: Int = 0, text: String, mentionedType: Int32 = 0, mentionedTargets: [String] = []) throws {
        try send(to: target, conversationType: conversationType, line: line, content: .text(text), mentionedType: mentionedType, mentionedTargets: mentionedTargets)
    }

    public func sendImage(to target: String, conversationType: ConversationType = .single, line: Int = 0, thumbnail: Data?, remoteURL: String) throws {
        try send(to: target, conversationType: conversationType, line: line, content: .image(thumbnail: thumbnail, remoteURL: remoteURL, localPath: nil), mentionedType: 0, mentionedTargets: [])
    }

    private func send(to target: String, conversationType: ConversationType, line: Int, content: MessageContent, mentionedType: Int32, mentionedTargets: [String]) throws {
        let localMessageId = idGenerator.next()
        let timestamp = nowMillis()

        let echo = try storage.messages.insert(StoredMessage(
            localMessageId: localMessageId,
            conversationType: conversationType,
            target: target,
            line: line,
            from: imClient.userId,
            content: content,
            timestamp: timestamp,
            status: .sending,
            direction: .send,
            mentionedType: Int(mentionedType),
            mentionedTargets: mentionedTargets
        ))
        try storage.conversations.recordIncomingMessage(
            conversationType: conversationType, target: target, line: line,
            messageUid: 0, timestamp: timestamp, incrementUnread: false
        )

        try sendWireMessage(localMessageId: echo.localMessageId, conversationType: conversationType, target: target, line: line, content: content, mentionedType: mentionedType, mentionedTargets: mentionedTargets)
    }

    public func resend(localMessageId: Int64) throws {
        guard let message = try storage.messages.message(localMessageId: localMessageId), message.status == .sendFailure else { return }
        try storage.messages.updateStatus(localMessageId: localMessageId, status: .sending)
        try sendWireMessage(localMessageId: localMessageId, conversationType: message.conversationType, target: message.target, line: message.line, content: message.content, mentionedType: Int32(message.mentionedType), mentionedTargets: message.mentionedTargets)
    }

    private func sendWireMessage(localMessageId: Int64, conversationType: ConversationType, target: String, line: Int, content: MessageContent, mentionedType: Int32, mentionedTargets: [String]) throws {
        var wireMessage = Im_Message()
        wireMessage.conversation.type = Int32(conversationType.rawValue)
        wireMessage.conversation.target = target
        wireMessage.conversation.line = Int32(line)
        wireMessage.fromUser = imClient.userId
        wireMessage.content = MessageContentCodec.encode(content, mentionedType: mentionedType, mentionedTargets: mentionedTargets)
        wireMessage.localMessageID = localMessageId

        let body = try wireMessage.serializedData()
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .ms, body: body)
        tracker.track(wireMessageId: wireMessageId, localMessageId: localMessageId) { [weak self] localId, result in
            guard let self else { return }
            switch result {
            case .acked(let messageUid, _):
                try? self.storage.messages.updateMessageUid(localMessageId: localId, messageUid: messageUid)
                try? self.storage.messages.updateStatus(localMessageId: localId, status: .sent)
            case .failed:
                try? self.storage.messages.updateStatus(localMessageId: localId, status: .sendFailure)
            }
        }
    }
```

(`pullMessagesSinceLastSync`/`pullMessages` are unchanged — leave them as-is.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MessagingServiceTests`
Expected: PASS

- [ ] **Step 5: Run the full `IMMessaging` test suite**

Run: `swift test --filter IMMessagingTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IMMessaging/MessagingService.swift Tests/IMMessagingTests/MessagingServiceTests.swift
git commit -m "feat(messaging): support sending @mentions and expose onGroupNotificationMessage"
```

---

## Part D — `IMKit`: protocols and ViewModels

### Task 19: `MessageSending` protocol — add mention params

**Files:**
- Modify: `Sources/IMKit/MessageSending.swift`
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift` (extend; see Task 22, which changes `ConversationViewModel.sendText`'s call site — this task just needs the protocol to compile against `MessagingService`'s new signature from Task 18)

- [ ] **Step 1: Update the protocol**

```swift
// Sources/IMKit/MessageSending.swift
import Foundation
import IMStorage
import IMMessaging

/// Narrow interface `ConversationViewModel` depends on instead of the
/// concrete `MessagingService` — same decoupling-for-testability pattern as
/// `ContactInfoFetching`/`ContactSyncService`.
public protocol MessageSending: AnyObject {
    func sendText(to target: String, conversationType: ConversationType, line: Int, text: String, mentionedType: Int32, mentionedTargets: [String]) throws
    func sendImage(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String) throws
    func resend(localMessageId: Int64) throws
}

extension MessagingService: MessageSending {}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build --target IMKit`
Expected: builds (this only compiles cleanly once `MessagingService.sendText` matches this exact signature, which Task 18 already added — if this is run before Task 18, it will fail with a protocol-conformance error, which is expected and resolves once both tasks are done).

- [ ] **Step 3: Commit**

```bash
git add Sources/IMKit/MessageSending.swift
git commit -m "feat(kit): add mention params to MessageSending protocol"
```

---

### Task 20: `GroupActing`/`GroupSyncing` protocols

**Files:**
- Create: `Sources/IMKit/GroupActing.swift`
- Create: `Sources/IMKit/GroupSyncing.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/IMKit/GroupActing.swift
import Foundation
import IMStorage
import IMGroups

/// Narrow interface `CreateGroupViewModel`/`GroupInfoViewModel` depend on
/// instead of the concrete `GroupSyncService` — same decoupling-for-
/// testability pattern as `FriendRequestSending`/`UserSearching`.
public protocol GroupActing: AnyObject {
    func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void)
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void)
    func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void)
    func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void)
    func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void)
    func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void)
}

extension GroupSyncService: GroupActing {}
```

```swift
// Sources/IMKit/GroupSyncing.swift
import IMGroups

/// Narrow interface `CreateGroupViewModel`/`GroupInfoViewModel` depend on
/// instead of the concrete `GroupSyncService`.
public protocol GroupSyncing: AnyObject {
    func refreshGroup(targetId: String)
    func refreshMembers(targetId: String)
}

extension GroupSyncService: GroupSyncing {}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build --target IMKit`
Expected: builds (both extensions are no-op conformances — `GroupSyncService`'s methods from Task 15 already match these signatures exactly).

- [ ] **Step 3: Commit**

```bash
git add Sources/IMKit/GroupActing.swift Sources/IMKit/GroupSyncing.swift
git commit -m "feat(kit): add GroupActing/GroupSyncing protocols"
```

---

### Task 21: `ConversationRow`/`ConversationListViewModel` — group display name/avatar, mention prompt, sender-prefixed preview

**Files:**
- Modify: `Sources/IMKit/ConversationRow.swift`
- Modify: `Sources/IMKit/ConversationListViewModel.swift`
- Test: `Tests/IMKitTests/ConversationListViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/IMKitTests/ConversationListViewModelTests.swift`. This file's `viewModel` is constructed once in `setUpWithError`, *before* any test inserts its data — every existing test in the file therefore waits for an async emission via `viewModel.$rows.dropFirst().sink { ... }.store(in: &cancellables)` + `wait(for:timeout:)` rather than reading `viewModel.rows` synchronously right after a write (see e.g. `test_newConversation_appearsAsARow...`). The tests below must follow the exact same pattern — reading `viewModel.rows` synchronously after the writes below would be flaky (the `ValueObservation` publisher's change notification is asynchronous after the first subscribe):

```swift
    func test_groupConversation_resolvesDisplayNameAndAvatarFromGroupStoreNotUserStore() throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "Group One", portrait: "http://x/g.png", owner: "u1", groupType: .normal, memberCount: 2, updateDt: 0, memberUpdateDt: 0))
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", messageUid: 1, timestamp: 1_000, incrementUnread: false)

        let row = try waitForRow(target: "g1")

        XCTAssertEqual(row.displayName, "Group One")
        XCTAssertEqual(row.avatarURL, "http://x/g.png")
    }

    func test_groupConversation_previewTextIsPrefixedWithSenderDisplayName() throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "Group One", portrait: nil, owner: "u1", groupType: .normal, memberCount: 2, updateDt: 0, memberUpdateDt: 0))
        try storage.users.upsertProfile(uid: "sender1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "sender1", content: .text("hello"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", messageUid: 1, timestamp: 1_000, incrementUnread: true)

        let row = try waitForRow(target: "g1")

        XCTAssertEqual(row.previewText, "Alice: hello")
    }

    func test_groupConversation_withUnreadMention_setsHasUnreadMentionTrue() throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "Group One", portrait: nil, owner: "u1", groupType: .normal, memberCount: 2, updateDt: 0, memberUpdateDt: 0))
        try storage.conversations.recordIncomingMessage(conversationType: .group, target: "g1", messageUid: 1, timestamp: 1_000, incrementUnread: true, incrementMention: true)

        let row = try waitForRow(target: "g1")

        XCTAssertTrue(row.hasUnreadMention)
    }

    func test_singleConversation_previewTextHasNoSenderPrefix() throws {
        try storage.users.upsertProfile(uid: "u2", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .single, target: "u2", from: "u2", content: .text("hello"), timestamp: 1_000, status: .unread, direction: .receive))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "u2", messageUid: 1, timestamp: 1_000, incrementUnread: true)

        let row = try waitForRow(target: "u2")

        XCTAssertEqual(row.previewText, "hello")
        XCTAssertFalse(row.hasUnreadMention)
    }
```

Add this helper to the test class (mirrors the file's existing wait-for-async-emission pattern, just additionally filtering by `target` since these tests don't assume the row is the only one):

```swift
    private func waitForRow(target: String) throws -> ConversationRow {
        let expectation = expectation(description: "row for \(target) appears")
        expectation.assertForOverFulfill = false
        viewModel.$rows.dropFirst().sink { rows in
            if rows.contains(where: { $0.target == target }) { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
        return try XCTUnwrap(viewModel.rows.first { $0.target == target })
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConversationListViewModelTests`
Expected: FAIL — `hasUnreadMention` doesn't exist on `ConversationRow`; group rows currently resolve against `UserStore`, not `GroupStore`.

- [ ] **Step 3: Implement**

In `Sources/IMKit/ConversationRow.swift`, add the field:

```swift
    public let unreadCount: Int
    public let hasUnreadMention: Bool
    public let isTop: Bool
```

(and the matching `init` parameter `hasUnreadMention: Bool,` plus `self.hasUnreadMention = hasUnreadMention`).

Replace `Sources/IMKit/ConversationListViewModel.swift`'s `handleConversationsUpdate` with:

```swift
    private func handleConversationsUpdate(_ conversations: [StoredConversation]) {
        var unresolvedUids: [String] = []

        rows = conversations.map { conversation in
            let lastMessage = (try? storage.messages.messages(
                conversationType: conversation.conversationType,
                target: conversation.target,
                line: conversation.line,
                limit: 1
            ))?.first

            if conversation.conversationType == .group {
                return makeGroupRow(conversation: conversation, lastMessage: lastMessage)
            }

            let user = try? storage.users.user(uid: conversation.target)
            if user?.displayName == nil && user?.name == nil {
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
                hasUnreadMention: conversation.unreadMentionCount > 0,
                isTop: conversation.isTop,
                isMuted: conversation.isMuted,
                lastMessageStatus: lastMessage?.status
            )
        }

        if !unresolvedUids.isEmpty {
            contactSync?.fetchUserInfo(uids: unresolvedUids, forceRefresh: false)
        }
    }

    /// Group rows resolve their name/avatar from `GroupStore`, not
    /// `UserStore` — a group is not a user. The preview text is prefixed
    /// with the last message's sender's display name (per the design
    /// doc's "{sender}: {digest}" format), unlike single chat, which shows
    /// the digest alone.
    private func makeGroupRow(conversation: StoredConversation, lastMessage: StoredMessage?) -> ConversationRow {
        let group = try? storage.groups.group(groupId: conversation.target)
        let previewText: String
        if let draft = conversation.draft {
            previewText = "[草稿] \(draft)"
        } else if let lastMessage {
            let sender = try? storage.users.user(uid: lastMessage.from)
            let senderName = sender?.displayName ?? sender?.name ?? lastMessage.from
            previewText = "\(senderName): \(lastMessage.searchableContent ?? "")"
        } else {
            previewText = ""
        }
        return ConversationRow(
            conversationType: .group,
            target: conversation.target,
            line: conversation.line,
            displayName: group?.name ?? conversation.target,
            avatarURL: group?.portrait,
            previewText: previewText,
            timestamp: conversation.timestamp,
            unreadCount: conversation.unreadCount,
            hasUnreadMention: conversation.unreadMentionCount > 0,
            isTop: conversation.isTop,
            isMuted: conversation.isMuted,
            lastMessageStatus: lastMessage?.status
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConversationListViewModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/ConversationRow.swift Sources/IMKit/ConversationListViewModel.swift Tests/IMKitTests/ConversationListViewModelTests.swift
git commit -m "feat(kit): resolve group conversations via GroupStore, add unread-mention prompt"
```

---

### Task 22: `ChatMessageRow`/`ConversationViewModel` — sender name/avatar, system-tip rows, @mention sending

This is the largest single task in the plan — it touches `ChatMessageRow.swift` (new `.systemTip` case, sender fields) and `ConversationViewModel.swift` (its row-building moves from a `static` function to an instance method so it can resolve sender names and render system-tip text). Read both files fresh before starting (they were last read in full during planning) since they're being substantially restructured, not just appended to.

**Files:**
- Modify: `Sources/IMKit/ChatMessageRow.swift`
- Modify: `Sources/IMKit/ConversationViewModel.swift`
- Test: `Tests/IMKitTests/ConversationViewModelTests.swift`

**Two existing things in `Tests/IMKitTests/ConversationViewModelTests.swift` must be fixed, not duplicated, as part of Step 3:**
1. The file already declares a `private final class FakeMessageSending: MessageSending` with the *old* `sendText(to:conversationType:line:text:)` signature (no mention params). Once Task 19 changes the `MessageSending` protocol, this fake stops compiling — update its `sendText` method signature to match (add `mentionedType: Int32, mentionedTargets: [String]` params, capturing them into two new `private(set) var` properties), rather than declaring a second same-named fake.
2. `setUpWithError()`'s existing line `viewModel = ConversationViewModel(storage: storage, messageSending: sending, imageUploading: uploading, target: "them", pageSize: 3)` needs `currentUserId: "me"` added — this task makes that parameter required.

- [ ] **Step 1: Write the failing test**

Append to `Tests/IMKitTests/ConversationViewModelTests.swift` (the file's existing `waitForFirstNonEmptyRows()` helper isn't needed for the tests below — each one inserts its `StoredMessage` *before* constructing its own fresh `ConversationViewModel` via `makeGroupViewModel`, so GRDB's `.immediate`-scheduling publisher delivers the already-present row synchronously on the very first subscribe, with no async wait needed; this differs from the shared `viewModel` in `setUpWithError`, which is constructed empty before any test-specific data exists):

```swift
    func test_groupTextMessage_received_populatesSenderDisplayNameAndAvatar() throws {
        try storage.users.upsertProfile(uid: "sender1", name: nil, displayName: "Alice", portrait: "http://x/a.png", mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "sender1", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .message(let message) = row else { return XCTFail("expected .message") }
        XCTAssertEqual(message.senderDisplayName, "Alice")
        XCTAssertEqual(message.senderAvatarURL, "http://x/a.png")
    }

    func test_groupTextMessage_sentByMe_hasNilSenderFields() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "me", content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .message(let message) = row else { return XCTFail("expected .message") }
        XCTAssertNil(message.senderDisplayName)
    }

    func test_singleChatTextMessage_neverHasSenderFields() throws {
        try storage.messages.insert(StoredMessage(localMessageId: 1, messageUid: 1, conversationType: .single, target: "u2", from: "u2", content: .text("hi"), timestamp: 1_000, status: .unread, direction: .receive))
        let viewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, target: "u2", conversationType: .single, currentUserId: "me")

        let row = try waitForFirstRow(viewModel)

        guard case .message(let message) = row else { return XCTFail("expected .message") }
        XCTAssertNil(message.senderDisplayName)
    }

    func test_groupNotificationMessage_rendersAsSystemTipWithChineseText() throws {
        try storage.users.upsertProfile(uid: "u1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .createGroup, operatorUid: "u1", memberUids: [], value: nil),
            timestamp: 1_000, status: .unread, direction: .receive
        ))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .systemTip(let tip) = row else { return XCTFail("expected .systemTip") }
        XCTAssertEqual(tip.text, "Alice创建了群组")
    }

    func test_groupNotificationMessage_operatorIsMe_substitutesNin() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "me",
            content: .groupNotification(type: .quitGroup, operatorUid: "me", memberUids: [], value: nil),
            timestamp: 1_000, status: .sent, direction: .send
        ))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .systemTip(let tip) = row else { return XCTFail("expected .systemTip") }
        XCTAssertEqual(tip.text, "您退出了群组")
    }

    func test_groupNotificationMessage_changeGroupName_includesNewNameInQuotes() throws {
        try storage.users.upsertProfile(uid: "u1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .changeGroupName, operatorUid: "u1", memberUids: [], value: "新群名"),
            timestamp: 1_000, status: .unread, direction: .receive
        ))
        let viewModel = makeGroupViewModel(target: "g1")

        let row = try waitForFirstRow(viewModel)

        guard case .systemTip(let tip) = row else { return XCTFail("expected .systemTip") }
        XCTAssertEqual(tip.text, "Alice修改群名为「新群名」")
    }

    func test_retry_onSystemTipRow_isNoOp() throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, messageUid: 1, conversationType: .group, target: "g1", from: "u1",
            content: .groupNotification(type: .dismissGroup, operatorUid: "u1", memberUids: [], value: nil),
            timestamp: 1_000, status: .unread, direction: .receive
        ))
        let viewModel = makeGroupViewModel(target: "g1")
        let row = try waitForFirstRow(viewModel)

        viewModel.retry(row: row) // must not crash
    }

    func test_sendText_withMentionParams_forwardsThemToMessageSending() throws {
        // Uses the file's existing `sending` fixture (the updated
        // `FakeMessageSending` from this task's Step 3) rather than
        // constructing a separate one.
        viewModel.sendText("hi @u2", mentionedType: 1, mentionedTargets: ["u2"])

        XCTAssertEqual(sending.lastMentionedType, 1)
        XCTAssertEqual(sending.lastMentionedTargets, ["u2"])
    }

    func test_groupMemberCandidatesForMention_returnsActiveMembersWithDisplayNames() throws {
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u2", memberType: .normal, updateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u3", memberType: .removed, updateDt: 0))
        try storage.users.upsertProfile(uid: "u2", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        let viewModel = makeGroupViewModel(target: "g1")

        let candidates = viewModel.groupMemberCandidatesForMention()

        XCTAssertEqual(candidates.map(\.uid), ["u2"])
        XCTAssertEqual(candidates.map(\.displayName), ["Bob"])
    }

    func test_groupMemberCandidatesForMention_onSingleChat_returnsEmpty() throws {
        let viewModel = ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, target: "u2", conversationType: .single, currentUserId: "me")

        XCTAssertEqual(viewModel.groupMemberCandidatesForMention().count, 0)
    }

    private func makeGroupViewModel(target: String) -> ConversationViewModel {
        ConversationViewModel(storage: storage, messageSending: nil, imageUploading: nil, target: target, conversationType: .group, currentUserId: "me")
    }

    private func waitForFirstRow(_ viewModel: ConversationViewModel) throws -> ChatMessageRow {
        try XCTUnwrap(viewModel.rows.first)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConversationViewModelTests`
Expected: FAIL — `ConversationViewModel` has no `currentUserId` param, `ChatMessageRow` has no `.systemTip` case, `groupMemberCandidatesForMention()` doesn't exist.

- [ ] **Step 3: Implement**

First, fix the two existing things flagged above. In `Tests/IMKitTests/ConversationViewModelTests.swift`, change `FakeMessageSending`'s `sendText` to:

```swift
private final class FakeMessageSending: MessageSending {
    private(set) var sentTexts: [(target: String, text: String)] = []
    private(set) var sentImages: [(target: String, thumbnail: Data?, remoteURL: String)] = []
    private(set) var resentLocalMessageIds: [Int64] = []
    private(set) var lastMentionedType: Int32?
    private(set) var lastMentionedTargets: [String]?

    func sendText(to target: String, conversationType: ConversationType, line: Int, text: String, mentionedType: Int32, mentionedTargets: [String]) throws {
        sentTexts.append((target, text))
        lastMentionedType = mentionedType
        lastMentionedTargets = mentionedTargets
    }

    func sendImage(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String) throws {
        sentImages.append((target, thumbnail, remoteURL))
    }

    func resend(localMessageId: Int64) throws {
        resentLocalMessageIds.append(localMessageId)
    }
}
```

and change `setUpWithError()`'s `viewModel` construction line to:

```swift
        viewModel = ConversationViewModel(storage: storage, messageSending: sending, imageUploading: uploading, target: "them", pageSize: 3, currentUserId: "me")
```

Now replace the full contents of `Sources/IMKit/ChatMessageRow.swift` with:

```swift
import Foundation
import IMStorage

public struct PendingImageUpload: Equatable, Hashable {
    public enum State: Equatable, Hashable {
        case uploading
        case failed
    }

    public let id: UUID
    public let thumbnail: Data
    public let fullImageData: Data
    public var state: State

    public init(id: UUID, thumbnail: Data, fullImageData: Data, state: State) {
        self.id = id
        self.thumbnail = thumbnail
        self.fullImageData = fullImageData
        self.state = state
    }
}

/// Flattened, `Hashable` presentation of a `StoredMessage`. `senderDisplayName`/
/// `senderAvatarURL` are non-nil only for a group-chat message I received
/// (never for single chat, never for my own outgoing messages — there's no
/// sender row to show for either case).
public struct StoredMessageRow: Equatable, Hashable {
    public let storageId: Int64
    public let localMessageId: Int64
    public let isOutgoing: Bool
    public let status: MessageStatus
    public let timestamp: Int64
    public let text: String?
    public let imageThumbnail: Data?
    public let imageRemoteURL: String?
    public let senderDisplayName: String?
    public let senderAvatarURL: String?

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
        senderAvatarURL: String? = nil
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
    }
}

/// A non-bubble row rendered centered, no sender — a group system
/// notification (create/add/kick/quit/dismiss/rename/re-portrait), with its
/// Chinese wording already resolved by `ConversationViewModel`.
public struct SystemTipRow: Equatable, Hashable {
    public let storageId: Int64
    public let text: String
    public let timestamp: Int64

    public init(storageId: Int64, text: String, timestamp: Int64) {
        self.storageId = storageId
        self.text = text
        self.timestamp = timestamp
    }
}

/// A single row in the chat message list: a real, persisted message; an
/// in-flight image upload placeholder; or a group system-notification tip.
public enum ChatMessageRow: Equatable, Hashable {
    case message(StoredMessageRow)
    case pendingImage(PendingImageUpload)
    case systemTip(SystemTipRow)
}

extension ChatMessageRow {
    /// `nil` for `.pendingImage` — it was never persisted, so it has no
    /// storage identity to compare against. Used by `ConversationViewModel`
    /// to detect which previously-live rows fell out of the sliding
    /// "latest pageSize" window and need migrating into `olderRows`.
    var storageId: Int64? {
        switch self {
        case .message(let row): return row.storageId
        case .systemTip(let row): return row.storageId
        case .pendingImage: return nil
        }
    }

    var timestamp: Int64? {
        switch self {
        case .message(let row): return row.timestamp
        case .systemTip(let row): return row.timestamp
        case .pendingImage: return nil
        }
    }
}
```

Replace the full contents of `Sources/IMKit/ConversationViewModel.swift` with:

```swift
import Foundation
import Combine
import IMStorage

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ConversationViewModel {
    @Published public private(set) var rows: [ChatMessageRow] = []
    @Published public private(set) var canLoadMore: Bool = true

    private let storage: IMStorage
    private let messageSending: MessageSending?
    private let imageUploading: ImageUploading?
    private let target: String
    private let conversationType: ConversationType
    private let line: Int
    private let pageSize: Int
    private let currentUserId: String

    /// Older history loaded via `loadMore`, strictly before `liveRows`.
    /// One-shot (not reactive) — see `liveRows`'s doc comment for the full
    /// eviction/migration contract, unchanged from Phase 1 except that both
    /// arrays now hold `ChatMessageRow` (so a `.systemTip` row can appear in
    /// the same paging window as ordinary messages) instead of
    /// `StoredMessageRow`.
    private var olderRows: [ChatMessageRow] = []
    private var liveRows: [ChatMessageRow] = []
    private var pendingImages: [PendingImageUpload] = []
    private var cancellable: AnyCancellable?

    public init(
        storage: IMStorage,
        messageSending: MessageSending?,
        imageUploading: ImageUploading?,
        target: String,
        conversationType: ConversationType = .single,
        line: Int = 0,
        pageSize: Int = 30,
        currentUserId: String
    ) {
        self.storage = storage
        self.messageSending = messageSending
        self.imageUploading = imageUploading
        self.target = target
        self.conversationType = conversationType
        self.line = line
        self.pageSize = pageSize
        self.currentUserId = currentUserId

        cancellable = storage.messages
            .messagesPublisher(conversationType: conversationType, target: target, line: line, limit: pageSize)
            .replaceError(with: [])
            .sink { [weak self] messages in self?.handleMessagesUpdate(messages) }
    }

    public func sendText(_ text: String, mentionedType: Int = 0, mentionedTargets: [String] = []) {
        try? messageSending?.sendText(to: target, conversationType: conversationType, line: line, text: text, mentionedType: Int32(mentionedType), mentionedTargets: mentionedTargets)
    }

    public func sendImage(fullImageData: Data, thumbnail: Data) {
        let pending = PendingImageUpload(id: UUID(), thumbnail: thumbnail, fullImageData: fullImageData, state: .uploading)
        pendingImages.append(pending)
        publishRows()
        startUpload(pending)
    }

    /// Candidate members for the composer's "@" picker — empty for a
    /// non-group conversation. Excludes `.removed` members (same filter
    /// `GroupStore.members(groupId:)` already applies).
    public func groupMemberCandidatesForMention() -> [(uid: String, displayName: String)] {
        guard conversationType == .group else { return [] }
        let members = (try? storage.groups.members(groupId: target)) ?? []
        return members.map { member in
            let user = try? storage.users.user(uid: member.memberId)
            return (uid: member.memberId, displayName: user?.displayName ?? user?.name ?? member.memberId)
        }
    }

    public func retry(row: ChatMessageRow) {
        switch row {
        case .pendingImage(let pending):
            guard let index = pendingImages.firstIndex(where: { $0.id == pending.id }) else { return }
            pendingImages[index].state = .uploading
            publishRows()
            startUpload(pendingImages[index])
        case .message(let message):
            guard message.status == .sendFailure else { return }
            try? messageSending?.resend(localMessageId: message.localMessageId)
        case .systemTip:
            break // never retryable — there's nothing to resend
        }
    }

    public func loadMore() {
        guard canLoadMore, let oldest = (olderRows.first ?? liveRows.first),
              let oldestTimestamp = oldest.timestamp, let oldestId = oldest.storageId else { return }
        let older = (try? storage.messages.olderMessages(
            conversationType: conversationType, target: target, line: line,
            beforeTimestamp: oldestTimestamp, beforeId: oldestId, limit: pageSize
        )) ?? []
        if older.count < pageSize { canLoadMore = false }
        guard !older.isEmpty else { return }
        olderRows.insert(contentsOf: older.map(makeRow), at: 0)
        publishRows()
    }

    private func startUpload(_ pending: PendingImageUpload) {
        imageUploading?.uploadImage(pending.fullImageData) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let remoteURL):
                try? self.messageSending?.sendImage(to: self.target, conversationType: self.conversationType, line: self.line, thumbnail: pending.thumbnail, remoteURL: remoteURL)
                self.pendingImages.removeAll { $0.id == pending.id }
            case .failure:
                if let index = self.pendingImages.firstIndex(where: { $0.id == pending.id }) {
                    self.pendingImages[index].state = .failed
                }
            }
            self.publishRows()
        }
    }

    private func handleMessagesUpdate(_ messages: [StoredMessage]) {
        let newLiveRows = messages.map(makeRow)
        let newStorageIds = Set(newLiveRows.compactMap(\.storageId))
        if !olderRows.isEmpty {
            let evicted = liveRows.filter { row in
                guard let id = row.storageId else { return false }
                return !newStorageIds.contains(id)
            }
            if !evicted.isEmpty {
                olderRows.append(contentsOf: evicted)
                olderRows.sort { lhs, rhs in
                    let lhsTime = lhs.timestamp ?? 0
                    let rhsTime = rhs.timestamp ?? 0
                    return lhsTime == rhsTime ? (lhs.storageId ?? 0) < (rhs.storageId ?? 0) : lhsTime < rhsTime
                }
            }
        }
        liveRows = newLiveRows
        publishRows()
    }

    private func publishRows() {
        rows = olderRows + liveRows + pendingImages.map { .pendingImage($0) }
    }

    private func makeRow(_ message: StoredMessage) -> ChatMessageRow {
        switch message.content {
        case .text(let text):
            return .message(buildStoredMessageRow(message, text: text, imageThumbnail: nil, imageRemoteURL: nil))
        case .image(let thumbnail, let remoteURL, _):
            return .message(buildStoredMessageRow(message, text: nil, imageThumbnail: thumbnail, imageRemoteURL: remoteURL))
        case .groupNotification(let type, let operatorUid, let memberUids, let value):
            return .systemTip(SystemTipRow(
                storageId: message.id ?? -1,
                text: renderSystemTipText(type: type, operatorUid: operatorUid, memberUids: memberUids, value: value),
                timestamp: message.timestamp
            ))
        }
    }

    private func buildStoredMessageRow(_ message: StoredMessage, text: String?, imageThumbnail: Data?, imageRemoteURL: String?) -> StoredMessageRow {
        var senderDisplayName: String?
        var senderAvatarURL: String?
        if conversationType == .group, message.direction == .receive {
            let user = try? storage.users.user(uid: message.from)
            senderDisplayName = user?.displayName ?? user?.name ?? message.from
            senderAvatarURL = user?.portrait
        }
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
            senderAvatarURL: senderAvatarURL
        )
    }

    /// `uid == currentUserId` renders as "您" — matches every Android
    /// group-notification template, which substitutes the first-person
    /// pronoun for the acting user's own actions.
    private func resolveDisplayName(_ uid: String) -> String {
        guard uid != currentUserId else { return "您" }
        guard let user = try? storage.users.user(uid: uid) else { return uid }
        return user.displayName ?? user.name ?? uid
    }

    /// Wording transcribed verbatim from the design doc's wire-format
    /// table (itself transcribed from Android's `*NotificationContent
    /// .formatNotification()` methods).
    private func renderSystemTipText(type: MessageContentType, operatorUid: String, memberUids: [String], value: String?) -> String {
        let operatorName = resolveDisplayName(operatorUid)
        switch type {
        case .createGroup:
            return "\(operatorName)创建了群组"
        case .addGroupMember:
            let names = memberUids.map(resolveDisplayName).joined(separator: "、")
            return "\(operatorName)邀请\(names)加入了群组"
        case .kickoffGroupMember:
            let names = memberUids.map(resolveDisplayName).joined(separator: "、")
            return "\(operatorName)将\(names)移出了群组"
        case .quitGroup:
            return "\(operatorName)退出了群组"
        case .dismissGroup:
            return "\(operatorName)解散了群组"
        case .changeGroupName:
            return "\(operatorName)修改群名为「\(value ?? "")」"
        case .changeGroupPortrait:
            return "\(operatorName)修改了群头像"
        case .text, .image:
            return "" // unreachable: makeRow only calls this for .groupNotification content
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConversationViewModelTests`
Expected: PASS

- [ ] **Step 5: Run the full `IMKitTests` suite to catch any other call site broken by the `currentUserId` param or the `ChatMessageRow` case change**

Run: `swift test --filter IMKitTests`
Expected: PASS — fix any other test file constructing `ConversationViewModel` without `currentUserId`, or switching over `ChatMessageRow` without the new `.systemTip` case, before moving on.

- [ ] **Step 6: Commit**

```bash
git add Sources/IMKit/ChatMessageRow.swift Sources/IMKit/ConversationViewModel.swift Tests/IMKitTests/ConversationViewModelTests.swift
git commit -m "feat(kit): render group sender names and system-tip rows in ConversationViewModel"
```

---

### Task 23: `CreateGroupViewModel`

**Files:**
- Create: `Sources/IMKit/CreateGroupViewModel.swift`
- Test: `Tests/IMKitTests/CreateGroupViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMKitTests/CreateGroupViewModelTests.swift
import XCTest
import IMStorage
@testable import IMKit

final class CreateGroupViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fakeActing: FakeGroupActing!
    private var fakeSyncing: FakeGroupSyncing!
    private var viewModel: CreateGroupViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        try storage.users.replaceFriendList(uids: ["u2", "u3"])
        try storage.users.upsertProfile(uid: "u2", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        try storage.users.upsertProfile(uid: "u3", name: nil, displayName: "Carol", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        fakeActing = FakeGroupActing()
        fakeSyncing = FakeGroupSyncing()
        viewModel = CreateGroupViewModel(storage: storage, groupActing: fakeActing, groupSyncing: fakeSyncing)
    }

    func test_init_populatesRowsFromFriendsList() {
        XCTAssertEqual(viewModel.rows.map(\.contact.displayName).sorted(), ["Bob", "Carol"])
        XCTAssertTrue(viewModel.rows.allSatisfy { !$0.isSelected })
    }

    func test_toggleSelection_flipsIsSelectedAndSelectedCount() {
        let uid = viewModel.rows[0].contact.uid

        viewModel.toggleSelection(uid: uid)

        XCTAssertTrue(viewModel.rows.first { $0.contact.uid == uid }!.isSelected)
        XCTAssertEqual(viewModel.selectedCount, 1)

        viewModel.toggleSelection(uid: uid)

        XCTAssertFalse(viewModel.rows.first { $0.contact.uid == uid }!.isSelected)
        XCTAssertEqual(viewModel.selectedCount, 0)
    }

    func test_createGroup_passesOnlySelectedMemberIdsToGroupActing() {
        viewModel.toggleSelection(uid: "u2")

        viewModel.createGroup(name: "My Group") { _ in }

        XCTAssertEqual(fakeActing.lastName, "My Group")
        XCTAssertEqual(fakeActing.lastMemberIds, ["u2"])
    }

    func test_createGroup_onSuccess_triggersRefreshGroupWithReturnedId() {
        fakeActing.resultToReturn = .success("g999")

        viewModel.createGroup(name: "My Group") { _ in }

        XCTAssertEqual(fakeSyncing.lastRefreshedGroupId, "g999")
    }

    func test_createGroup_onFailure_doesNotTriggerRefresh() {
        fakeActing.resultToReturn = .failure(NSError(domain: "test", code: 1))

        viewModel.createGroup(name: "My Group") { _ in }

        XCTAssertNil(fakeSyncing.lastRefreshedGroupId)
    }
}

final class FakeGroupActing: GroupActing {
    var resultToReturn: Result<String, Error> = .success("g1")
    private(set) var lastName: String?
    private(set) var lastMemberIds: [String]?

    func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void) {
        lastName = name
        lastMemberIds = memberIds
        completion(resultToReturn)
    }
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {}
    func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
    func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {}
}

final class FakeGroupSyncing: GroupSyncing {
    private(set) var lastRefreshedGroupId: String?
    func refreshGroup(targetId: String) { lastRefreshedGroupId = targetId }
    func refreshMembers(targetId: String) {}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CreateGroupViewModelTests`
Expected: FAIL — `CreateGroupViewModel` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/IMKit/CreateGroupViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the create-group screen: a multi-select friend list (reusing the
/// same `ContactRow` shape as the contacts tab) plus a name field. On
/// success, immediately triggers a `GroupSyncing.refreshGroup` for the
/// server-assigned id — group metadata/membership is only ever populated by
/// that passive-discovery pull (see the design doc §4), never by this
/// view-model writing to `GroupStore` directly.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class CreateGroupViewModel {
    public struct SelectableRow: Equatable, Hashable {
        public let contact: ContactRow
        public var isSelected: Bool
    }

    @Published public private(set) var rows: [SelectableRow] = []
    @Published public private(set) var selectedCount: Int = 0

    private let groupActing: GroupActing?
    private let groupSyncing: GroupSyncing?
    private var cancellable: AnyCancellable?

    public init(storage: IMStorage, groupActing: GroupActing?, groupSyncing: GroupSyncing?) {
        self.groupActing = groupActing
        self.groupSyncing = groupSyncing

        cancellable = storage.users.friendsPublisher()
            .replaceError(with: [])
            .sink { [weak self] users in self?.handleFriendsUpdate(users) }
    }

    private func handleFriendsUpdate(_ users: [StoredUser]) {
        let selectedUids = Set(rows.filter(\.isSelected).map(\.contact.uid))
        rows = users.map { user in
            let displayName = user.displayName ?? user.name ?? user.uid
            let contact = ContactRow(uid: user.uid, displayName: displayName, avatarURL: user.portrait, sectionLetter: PinyinIndexer.sectionLetter(for: displayName))
            return SelectableRow(contact: contact, isSelected: selectedUids.contains(user.uid))
        }
        selectedCount = rows.filter(\.isSelected).count
    }

    public func toggleSelection(uid: String) {
        guard let index = rows.firstIndex(where: { $0.contact.uid == uid }) else { return }
        rows[index].isSelected.toggle()
        selectedCount = rows.filter(\.isSelected).count
    }

    public func createGroup(name: String, completion: @escaping (Result<String, Error>) -> Void) {
        let memberIds = rows.filter(\.isSelected).map(\.contact.uid)
        groupActing?.createGroup(name: name, memberIds: memberIds) { [weak self] result in
            if case .success(let groupId) = result {
                self?.groupSyncing?.refreshGroup(targetId: groupId)
            }
            completion(result)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CreateGroupViewModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IMKit/CreateGroupViewModel.swift Tests/IMKitTests/CreateGroupViewModelTests.swift
git commit -m "feat(kit): add CreateGroupViewModel"
```

---

### Task 24: `GroupInfoViewModel` — member list + permission matrix

**Files:**
- Create: `Sources/IMKit/GroupInfoViewModel.swift`
- Test: `Tests/IMKitTests/GroupInfoViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMKitTests/GroupInfoViewModelTests.swift
import XCTest
import IMStorage
@testable import IMKit

final class GroupInfoViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fakeActing: FakeGroupActing!
    private var fakeSyncing: FakeGroupSyncing!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fakeActing = FakeGroupActing()
        fakeSyncing = FakeGroupSyncing()
    }

    private func seedGroup(type: GroupType, owner: String = "owner1") throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "G1", portrait: nil, owner: owner, groupType: type, memberCount: 2, updateDt: 0, memberUpdateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: owner, memberType: .owner, updateDt: 0))
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "member1", memberType: .normal, updateDt: 0))
    }

    private func makeViewModel(currentUserId: String) -> GroupInfoViewModel {
        GroupInfoViewModel(groupId: "g1", groupActing: fakeActing, groupSyncing: fakeSyncing, storage: storage, currentUserId: currentUserId)
    }

    // --- Permission matrix: the authoritative source is the design doc's
    // verified table (Restricted/Normal/Free × add/kick/modify/dismiss).
    // Each row below is one cell of that table, owner and non-owner both
    // checked where they differ.

    func test_restrictedGroup_ownerCanDoEverythingExceptQuit() throws {
        try seedGroup(type: .restricted, owner: "me")
        let viewModel = makeViewModel(currentUserId: "me")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertTrue(viewModel.canKickMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
        XCTAssertTrue(viewModel.canDismiss)
    }

    func test_restrictedGroup_nonOwnerCanDoNothingButQuit() throws {
        try seedGroup(type: .restricted, owner: "owner1")
        let viewModel = makeViewModel(currentUserId: "member1")

        XCTAssertFalse(viewModel.canAddMembers)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertFalse(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canDismiss)
    }

    func test_normalGroup_nonOwnerCanAddAndModifyButNotKickOrDismiss() throws {
        try seedGroup(type: .normal, owner: "owner1")
        let viewModel = makeViewModel(currentUserId: "member1")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canDismiss)
    }

    func test_normalGroup_ownerCanDoEverything() throws {
        try seedGroup(type: .normal, owner: "me")
        let viewModel = makeViewModel(currentUserId: "me")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertTrue(viewModel.canKickMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
        XCTAssertTrue(viewModel.canDismiss)
    }

    func test_freeGroup_nobodyCanKickOrDismissEvenTheOwner() throws {
        try seedGroup(type: .free, owner: "me")
        let viewModel = makeViewModel(currentUserId: "me")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canDismiss)
    }

    func test_freeGroup_nonOwnerCanAddAndModify() throws {
        try seedGroup(type: .free, owner: "owner1")
        let viewModel = makeViewModel(currentUserId: "member1")

        XCTAssertTrue(viewModel.canAddMembers)
        XCTAssertTrue(viewModel.canModifyInfo)
    }

    func test_noGroupLoadedYet_allPermissionsFalse() {
        let viewModel = makeViewModel(currentUserId: "me")

        XCTAssertFalse(viewModel.canAddMembers)
        XCTAssertFalse(viewModel.canKickMembers)
        XCTAssertFalse(viewModel.canModifyInfo)
        XCTAssertFalse(viewModel.canDismiss)
    }

    // --- Member list

    func test_members_excludesRemovedAndMarksOwner() throws {
        try seedGroup(type: .normal, owner: "owner1")
        try storage.groups.upsertMember(StoredGroupMember(groupId: "g1", memberId: "removedUser", memberType: .removed, updateDt: 0))
        try storage.users.upsertProfile(uid: "owner1", name: nil, displayName: "Owner", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        let viewModel = makeViewModel(currentUserId: "owner1")

        XCTAssertEqual(Set(viewModel.members.map(\.uid)), ["owner1", "member1"])
        XCTAssertEqual(viewModel.members.first { $0.uid == "owner1" }?.isOwner, true)
        XCTAssertEqual(viewModel.members.first { $0.uid == "member1" }?.isOwner, false)
        XCTAssertEqual(viewModel.members.first { $0.uid == "owner1" }?.displayName, "Owner")
    }

    // --- Actions delegate to GroupActing/GroupSyncing

    func test_addMembers_callsGroupActingThenRefreshesMembers() throws {
        try seedGroup(type: .normal)
        let viewModel = makeViewModel(currentUserId: "owner1")

        viewModel.addMembers(["newUser"]) { _ in }

        XCTAssertEqual(fakeActing.lastMemberIds, ["newUser"])
    }

    func test_refresh_callsGroupSyncingRefreshGroup() {
        let viewModel = makeViewModel(currentUserId: "me")

        viewModel.refresh()

        XCTAssertEqual(fakeSyncing.lastRefreshedGroupId, "g1")
    }
}
```

(`FakeGroupActing`/`FakeGroupSyncing` are the same fakes added in Task 23's test file — both are `internal`, visible within the same test target, so no duplicate definitions needed. `addMembers`/`kickMember` etc. on the fakes currently no-op without capturing args other than what Task 23 already added to `FakeGroupActing`; extend `FakeGroupActing.addMembers` to capture `lastMemberIds` the same way `createGroup` does, since `test_addMembers_callsGroupActingThenRefreshesMembers` above asserts on it.)

- [ ] **Step 2: Update `FakeGroupActing.addMembers`**

In `Tests/IMKitTests/CreateGroupViewModelTests.swift`, change:

```swift
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {}
```

to:

```swift
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        lastMemberIds = memberIds
        completion(.success(()))
    }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter GroupInfoViewModelTests`
Expected: FAIL — `GroupInfoViewModel` not found.

- [ ] **Step 4: Implement**

```swift
// Sources/IMKit/GroupInfoViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the group-info screen: member list, and the 4 permission-gated
/// actions (add/kick/modify-info/dismiss) plus quit (always allowed). The
/// permission matrix below is verified against the real server-side
/// `Handler`/`MemoryMessagesStore` permission-check code (see the design
/// doc §4) — not guessed:
///
/// |              | Restricted   | Normal      | Free       |
/// |--------------|--------------|-------------|------------|
/// | add member   | owner only   | any member  | any member |
/// | kick member  | owner only   | owner only  | nobody     |
/// | modify info  | owner only   | any member  | any member |
/// | dismiss      | owner only   | owner only  | nobody     |
/// | quit         | any member   | any member  | any member |
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class GroupInfoViewModel {
    public struct MemberRow: Equatable, Hashable {
        public let uid: String
        public let displayName: String
        public let avatarURL: String?
        public let isOwner: Bool
    }

    @Published public private(set) var group: StoredGroup?
    @Published public private(set) var members: [MemberRow] = []
    @Published public private(set) var canAddMembers: Bool = false
    @Published public private(set) var canKickMembers: Bool = false
    @Published public private(set) var canModifyInfo: Bool = false
    @Published public private(set) var canDismiss: Bool = false

    private let groupId: String
    private let groupActing: GroupActing?
    private let groupSyncing: GroupSyncing?
    private let storage: IMStorage
    private let currentUserId: String
    private var groupCancellable: AnyCancellable?
    private var membersCancellable: AnyCancellable?

    public init(groupId: String, groupActing: GroupActing?, groupSyncing: GroupSyncing?, storage: IMStorage, currentUserId: String) {
        self.groupId = groupId
        self.groupActing = groupActing
        self.groupSyncing = groupSyncing
        self.storage = storage
        self.currentUserId = currentUserId

        groupCancellable = storage.groups.groupPublisher(groupId: groupId)
            .replaceError(with: nil)
            .sink { [weak self] group in self?.handleGroupUpdate(group) }
        membersCancellable = storage.groups.membersPublisher(groupId: groupId)
            .replaceError(with: [])
            .sink { [weak self] members in self?.handleMembersUpdate(members) }
    }

    /// Call when the page appears: pulls fresh group info + member list.
    public func refresh() {
        groupSyncing?.refreshGroup(targetId: groupId)
    }

    public func addMembers(_ uids: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.addMembers(groupId: groupId, memberIds: uids) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshMembers(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func kickMember(_ uid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.kickMember(groupId: groupId, memberId: uid) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshMembers(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func renameGroup(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.modifyGroupInfo(groupId: groupId, type: .name, value: name) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshGroup(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func updatePortrait(url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.modifyGroupInfo(groupId: groupId, type: .portrait, value: url) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshGroup(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func quitGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.quitGroup(groupId: groupId, completion: completion)
    }

    public func dismissGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.dismissGroup(groupId: groupId, completion: completion)
    }

    private func handleGroupUpdate(_ group: StoredGroup?) {
        self.group = group
        recomputePermissions()
    }

    private func handleMembersUpdate(_ storedMembers: [StoredGroupMember]) {
        members = storedMembers.map { member in
            let user = try? storage.users.user(uid: member.memberId)
            return MemberRow(
                uid: member.memberId,
                displayName: user?.displayName ?? user?.name ?? member.memberId,
                avatarURL: user?.portrait,
                isOwner: member.memberType == .owner
            )
        }
    }

    private func recomputePermissions() {
        guard let group else {
            canAddMembers = false
            canKickMembers = false
            canModifyInfo = false
            canDismiss = false
            return
        }
        let isOwner = group.owner == currentUserId
        switch group.groupType {
        case .restricted:
            canAddMembers = isOwner
            canKickMembers = isOwner
            canModifyInfo = isOwner
            canDismiss = isOwner
        case .normal:
            canAddMembers = true
            canKickMembers = isOwner
            canModifyInfo = true
            canDismiss = isOwner
        case .free:
            canAddMembers = true
            canKickMembers = false
            canModifyInfo = true
            canDismiss = false
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter GroupInfoViewModelTests`
Expected: PASS

- [ ] **Step 6: Run the full `IMKitTests` suite**

Run: `swift test --filter IMKitTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/IMKit/GroupInfoViewModel.swift Tests/IMKitTests/GroupInfoViewModelTests.swift Tests/IMKitTests/CreateGroupViewModelTests.swift
git commit -m "feat(kit): add GroupInfoViewModel with verified permission matrix"
```

---

## Part E — `App`: UI and navigation

The `App` target has no test target in this codebase (confirmed: no `AppTests` directory exists) — the approved design doc's §8 testing strategy explicitly keeps it that way ("UI 层不写 snapshot/UI test，沿用项目现状"). Each task below substitutes "build, then manually verify in the simulator" for the red/green unit-test cycle used everywhere else in this plan.

### Task 25: `AppEnvironment` — construct `GroupSyncService`, wire `onGroupNotificationMessage`

**Files:**
- Modify: `Sources/AppCore/AppEnvironment.swift`

- [ ] **Step 1: Implement**

Add the import and stored property:

```swift
import IMGroups
```

```swift
    public private(set) var contactSyncService: ContactSyncService?
    public private(set) var groupSyncService: GroupSyncService?
    public private(set) var mediaUploadService: MediaUploadService?
```

In `connectIfPossible()`, after constructing `contactSync` and before `client.register(connectAckHandler)`, add:

```swift
        let groupSync = GroupSyncService(imClient: client, storage: storage)
        service.onGroupNotificationMessage = { [weak groupSync] groupId in groupSync?.refreshGroup(targetId: groupId) }
```

and in the final assignment block:

```swift
        imClient = client
        messagingService = service
        contactSyncService = contactSync
        groupSyncService = groupSync
        mediaUploadService = MediaUploadService(imClient: client)
        client.connect()
        return true
```

and in `logOut()`:

```swift
        imClient?.disconnect()
        imClient = nil
        messagingService = nil
        contactSyncService = nil
        groupSyncService = nil
        mediaUploadService = nil
        credentialsStore.clear()
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppCore/AppEnvironment.swift
git commit -m "feat(app): construct GroupSyncService and wire group-notification refresh"
```

---

### Task 26: `MessageInputBar` — @mention trigger and mention-aware send

**Files:**
- Modify: `App/MessageInputBar.swift`

- [ ] **Step 1: Implement**

Replace the full contents of `App/MessageInputBar.swift` with:

```swift
import UIKit

final class MessageInputBar: UIView {
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let imageButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private var textViewHeightConstraint: NSLayoutConstraint!

    private var mentionedType: Int32 = 0
    private var mentionedTargets: [String] = []

    var onSendText: ((_ text: String, _ mentionedType: Int32, _ mentionedTargets: [String]) -> Void)?
    var onPickImage: (() -> Void)?
    /// Fired the moment the user types a trailing "@" — the app presents a
    /// member picker and calls `insertMention(uid:displayName:)` with the
    /// result.
    var onMentionTriggered: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        imageButton.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        imageButton.tintColor = Theme.accent
        imageButton.addTarget(self, action: #selector(imageTapped), for: .touchUpInside)
        imageButton.translatesAutoresizingMaskIntoConstraints = false

        textView.font = .systemFont(ofSize: 16)
        textView.backgroundColor = Theme.backgroundTertiary
        textView.layer.cornerRadius = Theme.cardCornerRadius
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.text = "发消息..."
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        sendButton.setTitle("发送", for: .normal)
        sendButton.tintColor = Theme.accent
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageButton)
        addSubview(textView)
        textView.addSubview(placeholderLabel)
        addSubview(sendButton)

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)

        NSLayoutConstraint.activate([
            imageButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            imageButton.widthAnchor.constraint(equalToConstant: 28),
            imageButton.heightAnchor.constraint(equalToConstant: 28),

            textView.leadingAnchor.constraint(equalTo: imageButton.trailingAnchor, constant: 8),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            textViewHeightConstraint,

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 8),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.topAnchor, constant: 18),

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
        ])
    }

    /// Called by the host view controller once the user picks a member (or
    /// "所有人") from the mention picker presented in response to
    /// `onMentionTriggered`. `uid == nil` means "mention all".
    func insertMention(uid: String?, displayName: String) {
        textView.text += "@\(displayName) "
        if let uid {
            if mentionedType != 2 {
                mentionedType = 1
                mentionedTargets.append(uid)
            }
        } else {
            mentionedType = 2
            mentionedTargets = []
        }
        textViewDidChange(textView)
    }

    @objc private func imageTapped() { onPickImage?() }

    @objc private func sendTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSendText?(text, mentionedType, mentionedTargets)
        textView.text = ""
        mentionedType = 0
        mentionedTargets = []
        placeholderLabel.isHidden = false
        updateHeight()
    }

    private func updateHeight() {
        let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        let cappedHeight = min(max(size.height, 36), 120)
        textView.isScrollEnabled = size.height > 120
        textViewHeightConstraint.constant = cappedHeight
    }
}

extension MessageInputBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateHeight()
        if textView.text.hasSuffix("@") {
            onMentionTriggered?()
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme <App scheme> build` (or open in Xcode and build) — check the project's actual scheme name first if unsure; `swift build` alone doesn't cover the `App` UIKit target.
Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add App/MessageInputBar.swift
git commit -m "feat(app): add @mention trigger and mention-aware send to MessageInputBar"
```

---

### Task 27: `MentionPickerViewController` (new)

**Files:**
- Create: `App/MentionPickerViewController.swift`

- [ ] **Step 1: Implement**

```swift
// App/MentionPickerViewController.swift
import UIKit

/// Presented when the composer detects a trailing "@". `uid == nil` in the
/// callback means the user picked "所有人" (mention all).
final class MentionPickerViewController: UIViewController {
    private let members: [(uid: String, displayName: String)]
    private let tableView = UITableView()

    var onPicked: ((_ uid: String?, _ displayName: String) -> Void)?

    init(members: [(uid: String, displayName: String)]) {
        self.members = members
        super.init(nibName: nil, bundle: nil)
        title = "选择提醒的人"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func cancelTapped() { dismiss(animated: true) }
}

extension MentionPickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        members.count + 1 // +1 for "所有人"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.backgroundColor = Theme.backgroundSecondary
        cell.textLabel?.textColor = Theme.textPrimary
        cell.textLabel?.text = indexPath.row == 0 ? "所有人" : members[indexPath.row - 1].displayName
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            onPicked?(nil, "所有人")
        } else {
            let member = members[indexPath.row - 1]
            onPicked?(member.uid, member.displayName)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: build the `App` target.
Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add App/MentionPickerViewController.swift
git commit -m "feat(app): add MentionPickerViewController"
```

---

### Task 28: `ConversationViewController` — wire mention picker, sender row, system-tip cell, nav-title tap

**Files:**
- Create: `App/SystemTipMessageCell.swift`
- Modify: `App/TextMessageCell.swift`
- Modify: `App/ImageMessageCell.swift`
- Modify: `App/ConversationViewController.swift`

- [ ] **Step 1: Create `SystemTipMessageCell`**

```swift
// App/SystemTipMessageCell.swift
import UIKit
import IMKit

final class SystemTipMessageCell: UITableViewCell {
    static let reuseIdentifier = "SystemTipMessageCell"

    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.textPrimary.withAlphaComponent(0.6)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),
        ])
    }

    func configure(with row: SystemTipRow) {
        label.text = row.text
    }
}
```

- [ ] **Step 2: Add sender avatar+name row to `TextMessageCell` and `ImageMessageCell`**

In `App/TextMessageCell.swift`, add two new subviews and wire them only when `row.senderDisplayName != nil`:

```swift
    private let senderAvatarImageView = AvatarImageView(loader: AvatarLoader())
    private let senderNameLabel = UILabel()
```

In `layoutViews()`, configure and constrain them above `bubbleColumn` inside `rowStack`'s parent (`contentView`) — they sit on their own row, only visible for incoming group messages:

```swift
        senderAvatarImageView.translatesAutoresizingMaskIntoConstraints = false
        senderNameLabel.font = .systemFont(ofSize: 12)
        senderNameLabel.textColor = Theme.textPrimary.withAlphaComponent(0.6)
        senderNameLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(senderAvatarImageView)
        contentView.addSubview(senderNameLabel)

        NSLayoutConstraint.activate([
            senderAvatarImageView.widthAnchor.constraint(equalToConstant: 28),
            senderAvatarImageView.heightAnchor.constraint(equalToConstant: 28),
            senderAvatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            senderAvatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),

            senderNameLabel.leadingAnchor.constraint(equalTo: senderAvatarImageView.trailingAnchor, constant: 6),
            senderNameLabel.centerYAnchor.constraint(equalTo: senderAvatarImageView.centerYAnchor),

            rowStack.topAnchor.constraint(equalTo: senderAvatarImageView.bottomAnchor, constant: 2),
        ])
```

Remove the old `rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4)` line from the existing constraint block (replaced by the one above, which now anchors below the sender row instead of directly below `contentView.topAnchor`).

In `configure(with:)`, add at the top:

```swift
        let showsSender = row.senderDisplayName != nil
        senderAvatarImageView.isHidden = !showsSender
        senderNameLabel.isHidden = !showsSender
        if showsSender {
            senderNameLabel.text = row.senderDisplayName
            senderAvatarImageView.setAvatar(urlString: row.senderAvatarURL, displayName: row.senderDisplayName ?? "")
        }
```

Apply the identical change to `App/ImageMessageCell.swift` (read it first — it currently takes an `ImageBubbleData` struct, not `StoredMessageRow`, directly; check whether `ImageBubbleData` already carries `senderDisplayName`/`senderAvatarURL` or needs those two fields added to it, then mirror the same `senderAvatarImageView`/`senderNameLabel` treatment described above for `TextMessageCell`).

- [ ] **Step 3: Wire the mention picker, system-tip cell, and nav-title tap in `ConversationViewController`**

In `App/ConversationViewController.swift`:

Register the new cell in `layoutViews()`:

```swift
        tableView.register(SystemTipMessageCell.self, forCellReuseIdentifier: SystemTipMessageCell.reuseIdentifier)
```

Add a `.systemTip` case to `configureDataSource()`'s switch:

```swift
            case .systemTip(let tip):
                let cell = tableView.dequeueReusableCell(withIdentifier: SystemTipMessageCell.reuseIdentifier, for: indexPath) as! SystemTipMessageCell
                cell.configure(with: tip)
                return cell
```

Update `bindInputBar()` and add the mention-picker presentation:

```swift
    private func bindInputBar() {
        inputBar.onSendText = { [weak self] text, mentionedType, mentionedTargets in
            self?.viewModel.sendText(text, mentionedType: Int(mentionedType), mentionedTargets: mentionedTargets)
        }
        inputBar.onPickImage = { [weak self] in self?.presentImagePicker() }
        inputBar.onMentionTriggered = { [weak self] in self?.presentMentionPicker() }
    }

    private func presentMentionPicker() {
        guard row.conversationType == .group else { return }
        let picker = MentionPickerViewController(members: viewModel.groupMemberCandidatesForMention())
        picker.onPicked = { [weak self] uid, displayName in
            self?.inputBar.insertMention(uid: uid, displayName: displayName)
            self?.dismiss(animated: true)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }
```

For the nav-title tap (pushes `GroupInfoViewController` for group conversations — wired fully in Task 29, since `GroupInfoViewController` doesn't exist yet): add a tappable title button only when `row.conversationType == .group`, in `viewDidLoad()`:

```swift
        if row.conversationType == .group {
            let titleButton = UIButton(type: .system)
            titleButton.setTitle(row.displayName, for: .normal)
            titleButton.setTitleColor(Theme.textPrimary, for: .normal)
            titleButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
            titleButton.addTarget(self, action: #selector(groupTitleTapped), for: .touchUpInside)
            navigationItem.titleView = titleButton
        }
```

```swift
    var onGroupInfoTapped: (() -> Void)?

    @objc private func groupTitleTapped() { onGroupInfoTapped?() }
```

(`onGroupInfoTapped` is wired by `SceneDelegate` in Task 30, the same closure-from-outside convention every other navigation hop in this codebase already uses.)

- [ ] **Step 4: Build**

Run: build the `App` target.
Expected: builds successfully.

- [ ] **Step 5: Manually verify in the simulator**

Launch the app, open a group conversation (once Task 30's "+" button exists — if testing before that, temporarily hardcode a group conversation row to navigate to). Confirm: typing "@" opens the picker; picking a member inserts "@Name " and the sent message round-trips with the mention highlighted server-side (verify via the group's other test account, or by inspecting `storage.dbQueueForTesting` in a debugger if a second account isn't available yet); a received group text message shows the sender's avatar+name above the bubble; a group system action (once Task 29/30 can trigger one) renders as a centered tip, not a bubble.

- [ ] **Step 6: Commit**

```bash
git add App/SystemTipMessageCell.swift App/TextMessageCell.swift App/ImageMessageCell.swift App/ConversationViewController.swift
git commit -m "feat(app): render group sender rows, system tips, and @mention picker in chat"
```

---

### Task 29: `CreateGroupViewController`

**Files:**
- Create: `App/CreateGroupViewController.swift`

- [ ] **Step 1: Implement**

```swift
// App/CreateGroupViewController.swift
import UIKit
import IMKit

final class CreateGroupViewController: UIViewController {
    private let viewModel: CreateGroupViewModel
    private var cancellable: Any?
    private var dataSource: UITableViewDiffableDataSource<Int, CreateGroupViewModel.SelectableRow>!

    private let tableView = UITableView()
    private let nameField = UITextField()

    /// `groupId`/`name` of the newly created group, for the caller to push
    /// straight into its chat screen.
    var onGroupCreated: ((_ groupId: String, _ name: String) -> Void)?

    init(viewModel: CreateGroupViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "创建群聊"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "创建", style: .done, target: self, action: #selector(createTapped))
        navigationItem.rightBarButtonItem?.isEnabled = false
        layoutViews()
        configureDataSource()
        bindViewModel()
    }

    private func layoutViews() {
        nameField.placeholder = "群聊名称"
        nameField.borderStyle = .roundedRect
        nameField.backgroundColor = Theme.backgroundSecondary
        nameField.translatesAutoresizingMaskIntoConstraints = false

        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(nameField)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, CreateGroupViewModel.SelectableRow>(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: row.contact)
            cell.accessoryType = row.isSelected ? .checkmark : .none
            return cell
        }
    }

    private func bindViewModel() {
        let rowsCancellable = viewModel.$rows
            .sink { [weak self] rows in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, CreateGroupViewModel.SelectableRow>()
                snapshot.appendSections([0])
                snapshot.appendItems(rows, toSection: 0)
                self.dataSource.apply(snapshot, animatingDifferences: true)
            }
        let countCancellable = viewModel.$selectedCount
            .sink { [weak self] count in self?.navigationItem.rightBarButtonItem?.isEnabled = count > 0 }
        cancellable = (rowsCancellable, countCancellable)
    }

    @objc private func createTapped() {
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return }
        navigationItem.rightBarButtonItem?.isEnabled = false
        viewModel.createGroup(name: name) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let groupId):
                self.onGroupCreated?(groupId, name)
            case .failure:
                self.navigationItem.rightBarButtonItem?.isEnabled = true
            }
        }
    }
}

extension CreateGroupViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.toggleSelection(uid: row.contact.uid)
    }
}
```

(`cancellable: Any?` holding a tuple of two `AnyCancellable`s is a deliberate shortcut to avoid importing `Combine` just to spell `Set<AnyCancellable>` for two subscriptions — matches no existing precedent exactly, so if this feels inconsistent during review, the alternative is `import Combine` + `private var cancellables = Set<AnyCancellable>()` exactly like every other `App` view controller in this codebase; prefer that if in doubt, since consistency with the established pattern outweighs the minor import.)

- [ ] **Step 2: Build**

Run: build the `App` target.
Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add App/CreateGroupViewController.swift
git commit -m "feat(app): add CreateGroupViewController"
```

---

### Task 30: `GroupInfoViewController`

**Files:**
- Create: `App/GroupInfoViewController.swift`

- [ ] **Step 1: Implement**

```swift
// App/GroupInfoViewController.swift
import UIKit
import Combine
import IMKit

final class GroupInfoViewController: UIViewController {
    private let viewModel: GroupInfoViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, GroupInfoViewModel.MemberRow>!

    private let tableView = UITableView()
    private let quitButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)

    init(viewModel: GroupInfoViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "群信息"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        configureDataSource()
        bindViewModel()
        viewModel.refresh()
    }

    private func layoutViews() {
        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.translatesAutoresizingMaskIntoConstraints = false

        quitButton.setTitle("退出该群", for: .normal)
        quitButton.setTitleColor(.systemRed, for: .normal)
        quitButton.addTarget(self, action: #selector(quitTapped), for: .touchUpInside)
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.setTitle("解散该群", for: .normal)
        dismissButton.setTitleColor(.systemRed, for: .normal)
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(quitButton)
        view.addSubview(dismissButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: quitButton.topAnchor, constant: -8),

            quitButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            quitButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            quitButton.heightAnchor.constraint(equalToConstant: 44),

            dismissButton.topAnchor.constraint(equalTo: quitButton.bottomAnchor, constant: 4),
            dismissButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            dismissButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            dismissButton.heightAnchor.constraint(equalToConstant: 44),
            dismissButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, GroupInfoViewModel.MemberRow>(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: ContactRow(uid: row.uid, displayName: row.isOwner ? "👑 \(row.displayName)" : row.displayName, avatarURL: row.avatarURL, sectionLetter: ""))
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$members
            .sink { [weak self] members in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, GroupInfoViewModel.MemberRow>()
                snapshot.appendSections([0])
                snapshot.appendItems(members, toSection: 0)
                self.dataSource.apply(snapshot, animatingDifferences: true)
            }
            .store(in: &cancellables)

        viewModel.$group
            .sink { [weak self] group in self?.title = group?.name ?? "群信息" }
            .store(in: &cancellables)

        viewModel.$canKickMembers
            .sink { [weak self] _ in } // member-row swipe-to-kick wiring is left to UITableViewDelegate below, reading the published flag directly
            .store(in: &cancellables)

        viewModel.$canDismiss
            .sink { [weak self] canDismiss in self?.dismissButton.isHidden = !canDismiss }
            .store(in: &cancellables)

        // Quit is always allowed per the design doc's permission matrix
        // (every `GroupType` permits self-removal) — `quitButton` has no
        // corresponding `@Published` gate to hide it.
    }

    @objc private func quitTapped() {
        viewModel.quitGroup { [weak self] _ in self?.navigationController?.popViewController(animated: true) }
    }

    @objc private func dismissTapped() {
        viewModel.dismissGroup { [weak self] _ in self?.navigationController?.popViewController(animated: true) }
    }
}

extension GroupInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard viewModel.canKickMembers, let row = dataSource.itemIdentifier(for: indexPath), !row.isOwner else { return nil }
        let kick = UIContextualAction(style: .destructive, title: "移出") { [weak self] _, _, completion in
            self?.viewModel.kickMember(row.uid) { _ in }
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [kick])
    }
}
```

- [ ] **Step 2: Build**

Run: build the `App` target.
Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add App/GroupInfoViewController.swift
git commit -m "feat(app): add GroupInfoViewController"
```

---

### Task 31: `SceneDelegate` — "+" button, push flows, `onGroupInfoTapped` wiring

**Files:**
- Modify: `App/SceneDelegate.swift`
- Modify: `App/ConversationListViewController.swift`

- [ ] **Step 1: Add the "+" button to `ConversationListViewController`**

In `App/ConversationListViewController.swift`, add a closure and wire it in `viewDidLoad()`:

```swift
    var onCreateGroupTapped: (() -> Void)?
```

```swift
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(createGroupTapped))
        layoutTableView()
        configureDataSource()
        bindViewModel()
    }

    @objc private func createGroupTapped() { onCreateGroupTapped?() }
```

- [ ] **Step 2: Wire everything in `SceneDelegate`**

In `App/SceneDelegate.swift`, add `import IMGroups` and, inside `makeConversationListNavigationController()`, after constructing `listViewController` and before `return UINavigationController(...)`, add:

```swift
        listViewController.onCreateGroupTapped = { [weak self, weak listViewController] in
            guard let self else { return }
            let createGroupViewModel = CreateGroupViewModel(
                storage: self.environment.storage,
                groupActing: self.environment.groupSyncService,
                groupSyncing: self.environment.groupSyncService
            )
            let createGroupViewController = CreateGroupViewController(viewModel: createGroupViewModel)
            createGroupViewController.onGroupCreated = { [weak self, weak listViewController] groupId, name in
                guard let self else { return }
                let conversationViewModel = ConversationViewModel(
                    storage: self.environment.storage,
                    messageSending: self.environment.messagingService,
                    imageUploading: self.environment.mediaUploadService,
                    target: groupId,
                    conversationType: .group,
                    currentUserId: self.environment.imClient?.userId ?? ""
                )
                let conversationRow = ConversationRow(
                    conversationType: .group, target: groupId, line: 0,
                    displayName: name, avatarURL: nil, previewText: "",
                    timestamp: 0, unreadCount: 0, hasUnreadMention: false,
                    isTop: false, isMuted: false, lastMessageStatus: nil
                )
                let conversationViewController = ConversationViewController(row: conversationRow, viewModel: conversationViewModel)
                self.wireGroupInfoNavigation(on: conversationViewController, groupId: groupId)
                listViewController?.navigationController?.popToRootViewController(animated: false)
                listViewController?.navigationController?.pushViewController(conversationViewController, animated: true)
            }
            listViewController?.navigationController?.pushViewController(createGroupViewController, animated: true)
        }
```

Update `onConversationSelected` (already exists) to pass `currentUserId:` to `ConversationViewModel`'s now-required parameter, and to wire group-info navigation when the row is a group:

```swift
        listViewController.onConversationSelected = { [weak self, weak listViewController] row in
            guard let self else { return }
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
                target: row.target,
                conversationType: row.conversationType,
                line: row.line,
                currentUserId: self.environment.imClient?.userId ?? ""
            )
            let conversationViewController = ConversationViewController(row: row, viewModel: conversationViewModel)
            self.wireGroupInfoNavigation(on: conversationViewController, groupId: row.target)
            listViewController?.navigationController?.pushViewController(conversationViewController, animated: true)
        }
```

Add the shared helper as a new private method on `SceneDelegate`:

```swift
    /// Wires the chat screen's tappable group title (see
    /// `ConversationViewController.onGroupInfoTapped`) to push
    /// `GroupInfoViewController` — shared by both the "open an existing
    /// group" and "just created a group" navigation paths above. A no-op
    /// for single chat (`ConversationViewController` only shows a tappable
    /// title view for `conversationType == .group` in the first place).
    private func wireGroupInfoNavigation(on conversationViewController: ConversationViewController, groupId: String) {
        conversationViewController.onGroupInfoTapped = { [weak self, weak conversationViewController] in
            guard let self else { return }
            let groupInfoViewModel = GroupInfoViewModel(
                groupId: groupId,
                groupActing: self.environment.groupSyncService,
                groupSyncing: self.environment.groupSyncService,
                storage: self.environment.storage,
                currentUserId: self.environment.imClient?.userId ?? ""
            )
            conversationViewController?.navigationController?.pushViewController(GroupInfoViewController(viewModel: groupInfoViewModel), animated: true)
        }
    }
```

Also update `makeContactListNavigationController()`'s existing `ConversationViewModel(...)` construction (the "message a contact directly" path) to pass `currentUserId:`:

```swift
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
                target: row.uid,
                conversationType: .single,
                currentUserId: self.environment.imClient?.userId ?? ""
            )
```

and its `ConversationRow(...)` construction needs the new `hasUnreadMention: false` argument added (the type from Task 21 added a required field):

```swift
            let conversationRow = ConversationRow(
                conversationType: .single,
                target: row.uid,
                line: 0,
                displayName: row.displayName,
                avatarURL: row.avatarURL,
                previewText: "",
                timestamp: 0,
                unreadCount: 0,
                hasUnreadMention: false,
                isTop: false,
                isMuted: false,
                lastMessageStatus: nil
            )
```

- [ ] **Step 3: Build**

Run: build the `App` target.
Expected: builds successfully — this is the integration point where every signature change from Tasks 19–30 must finally line up; fix any remaining mismatch here rather than guessing earlier.

- [ ] **Step 4: Manually verify in the simulator**

Full walkthrough: tap "+" on the conversation list → select 1–2 friends → enter a name → "创建" → lands in the new group's chat screen → tap the title → group info page shows members with the owner crown → (with a second test account, or by directly calling the server) verify add/kick/rename/quit/dismiss each work and produce the correct Chinese system-tip text in both accounts' chat screens.

- [ ] **Step 5: Commit**

```bash
git add App/SceneDelegate.swift App/ConversationListViewController.swift
git commit -m "feat(app): wire group creation, group info navigation, and the conversation list + button"
```

---

## Final verification

### Task 32: Full test suite + build

**Files:** none (verification only)

- [ ] **Step 1: Run the entire SwiftPM test suite**

Run: `swift test`
Expected: PASS — every test added across Tasks 1–24, plus all pre-existing Phase 1/Plan I/J/K tests still green (this plan only ever *added* parameters with non-breaking defaults or *added* new enum cases to switches that the compiler forces exhaustive — nothing here should have silently broken old behavior, but this is the step that proves it).

- [ ] **Step 2: Build the full `App` target**

Run: build the `App` scheme in Xcode (or `xcodebuild build` with the project's scheme — check `ios-chat-pro.xcodeproj`/`.xcworkspace` for the exact scheme name).
Expected: builds with no warnings about unused `ConversationRow`/`ChatMessageRow` switch cases (the compiler enforces exhaustiveness on both, so a missed call site fails to build rather than failing silently at runtime).

- [ ] **Step 3: Manual end-to-end walkthrough (two test accounts)**

Using two logged-in simulators/devices:
1. Account A creates a group with Account B → both see the group appear with the "creator created the group" + "creator invited B" system tips (or just one combined tip, depending on what the server actually sends — verify against the real response rather than assuming).
2. Account A sends a text message @mentioning Account B → Account B's conversation list shows "[有人@我]" and the chat screen highlights the mention.
3. Account A renames the group, changes the (placeholder) portrait → both accounts see the correct Chinese system tip and the group info page updates.
4. Account A adds a third account, then kicks Account B → correct tips appear, permission buttons match the verified matrix for whatever `GroupType` the group was created as (`.normal`, per `GroupSyncService.createGroup`'s hardcoded default).
5. Account B quits; Account A (owner) dismisses → both flows work and pop back to the conversation list correctly.

- [ ] **Step 4: Commit (only if Step 3 surfaced fixes)**

```bash
git add -A
git commit -m "fix: address issues found during group chat end-to-end walkthrough"
```

---

## Plan self-review

**Spec coverage** — every section of `docs/superpowers/specs/2026-06-22-phase2-group-chat-design.md` maps to at least one task:
- §1 (范围/排除) — enforced implicitly throughout (no `TransferGroup`/`GMA`/Manager-Silent/公告/Extra code anywhere in this plan).
- §2 (协议层, wire formats) — Tasks 7–18 (handlers + `MessageContentCodec`).
- §3 (数据层) — Tasks 1–6.
- §4 (网络/同步层, permission matrix) — Tasks 7–15 (transport), permission matrix consumed by Task 24.
- §5 (`IMMessaging` 扩展) — Tasks 16–18.
- §6 (`IMKit` ViewModel 层) — Tasks 19–24.
- §7 (`App` 层) — Tasks 25–31.
- §8 (测试策略) — every `Sources/` task in Parts A–D has a matching test task; Part E's note explains the deliberate App-layer exception, matching the design doc's own §8.

**Placeholder scan** — no "TBD"/"TODO"/"add appropriate handling" in any task; every code-producing step shows complete code. The two spots that say "read the file first" (Tasks 17/18/21/22's test-fixture-name caveats) are not placeholders — they're honest flags that those specific pre-existing test files weren't re-read byte-for-byte after this plan's last edit, point at the exact existing names/lines to change, and were in fact resolved by reading the real files in this session and folding the corrections back in (the `FakeMessageSending` fix and the `waitForRow` async-wait fix in Tasks 21/22 are the result of that verification, not residual guesses).

**Type consistency** — cross-checked: `ConversationRow`'s new `hasUnreadMention` field (Task 21) is threaded through both `SceneDelegate` call sites that construct one (Task 31). `ConversationViewModel`'s new required `currentUserId` param (Task 22) is threaded through every construction site: `Tests/IMKitTests/ConversationViewModelTests.swift`'s `setUpWithError` (Task 22 Step 3) and both `SceneDelegate` construction sites (Task 31). `MessageSending`'s new two params (Task 19) are threaded through `MessagingService` (Task 18), the test fake (Task 22), and `ConversationViewModel.sendText` (Task 22). `GroupActing`/`GroupSyncing` method signatures (Task 20) match `GroupSyncService` (Task 15) and the two view models that depend on them (Tasks 23–24) exactly — verified by re-reading Task 15's method signatures while writing Tasks 20/23/24, not assumed.

---

**This plan is ready for execution.**
