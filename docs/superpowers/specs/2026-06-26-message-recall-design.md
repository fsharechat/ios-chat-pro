# Message Recall — iOS Design Spec

**Date:** 2026-06-26  
**Reference:** Android `RecallNotifyMessageHandler` + `RecallMessageContent` (`ContentType_Recall = 80`)

---

## Problem

The iOS client silently drops server-pushed recall notifications. When another user recalls a message, the server sends a `PUBLISH / RMN` (SubSignal 31) frame containing `Im_NotifyRecallMessage { id, fromUser }`. No registered `MessageHandler` in `MessagingService` matches this signal, so the frame is discarded, the original message remains in the database unchanged, and no "XXX 撤回了一条消息" tip is shown.

---

## Signal Clarification

| SubSignal | Direction | Purpose |
|-----------|-----------|---------|
| `mr = 30` | client → server | Request recall of a message |
| `rmn = 31` | server → client | Notify all connected clients of a recall |

The handler must match `.publish / .rmn`, not `.publish / .mr`.

---

## Design

### Behaviour

- Original message is replaced in-place with a `.recalled` content type.
- Chat view shows a centred tip row: "XXX 撤回了一条消息" (same style as group-notification tips).
- Conversation list preview updates to the same text.
- No re-edit affordance.

### Data Layer

**`MessageEnums.swift`**  
Add `case recalled = 80` to `MessageContentType` (matches Android `ContentType_Recall = 80`).

**`StoredMessage.swift`**  
Add `case recalled(operatorId: String)` to `MessageContent`.

`setContent(.recalled(operatorId:))` mapping:

| Column | Value |
|--------|-------|
| `contentType` | `.recalled` |
| `textContent` | `operatorId` (uid of who recalled) |
| `searchableContent` | `"[撤回消息]"` |
| all other columns | nil / 0 |

`content` var: `case .recalled → .recalled(operatorId: textContent ?? "")`.

No DB migration required — `textContent` is unused for recalled messages and the column already exists.

**`MessageStore.swift`**  
Add `updateContent(id: Int64, content: MessageContent, db: Database)` — a transaction-scoped variant of the existing `updateContent(id:content:)`, needed by `RecallNotifyMessageHandler` to batch the message update and conversation touch inside one write transaction.

### Transport Layer

**`Sources/IMMessaging/RecallNotifyMessageHandler.swift`** (new file)

```
canHandle: signal == .publish && subSignal == .rmn

handle(frame:):
  1. Parse Im_NotifyRecallMessage from frame.body
  2. storage.write { db in
       guard let msg = storage.messages.message(uid: notify.id, db: db),
             let rowId = msg.id else { return }
       storage.messages.updateContent(id: rowId, content: .recalled(operatorId: notify.fromUser), db: db)
       storage.conversations.recordIncomingMessage(
           conversationType: msg.conversationType, target: msg.target, line: msg.line,
           messageUid: msg.messageUid, timestamp: msg.timestamp,
           incrementUnread: false, db: db
       )
     }
  3. onRecalled?(notify.id)
```

`onRecalled: ((Int64) -> Void)?` — fires after the write, forwarded via `MessagingService`.

**`Sources/IMMessaging/MessagingService.swift`**  
- Register `RecallNotifyMessageHandler` in `init()`.
- Expose `onMessageRecalled: ((Int64) -> Void)?` forwarding to the handler's closure.

### UI Layer

**`Sources/IMKit/ConversationViewModel.swift`**  
`makeRow(_:)` new case:

```swift
case .recalled(let operatorId):
    let name: String
    if operatorId == currentUserId {
        name = "你"
    } else {
        let user = try? storage.users.user(uid: operatorId)
        name = user?.displayName ?? user?.name ?? operatorId
    }
    return .systemTip(SystemTipRow(
        storageId: message.id ?? -1,
        text: "\(name)撤回了一条消息",
        timestamp: message.timestamp
    ))
```

**`Sources/IMKit/ConversationListViewModel.swift`**  
- Add `currentUserId: String` to `init`.
- In `handleConversationsUpdate` (both single-chat and group branches), check `lastMessage?.contentType == .recalled`:
  - Single: fromUser == currentUserId → "你撤回了一条消息"; else → "对方撤回了一条消息"
  - Group: resolve display name from `storage.users.user(uid: fromUser)` → "XXX 撤回了一条消息"

**`App/SceneDelegate.swift`**  
Pass `currentUserId: environment.imClient?.userId ?? ""` to `ConversationListViewModel(...)`.

---

## Conversation List Refresh

After `RecallNotifyMessageHandler` updates the message row, `conversationsPublisher()` (which watches the `conversation` table) will not fire automatically. The handler therefore re-saves the conversation row via `recordIncomingMessage(..., incrementUnread: false, db: db)` within the same transaction. This causes GRDB's SQLite update hook to fire on the `conversation` table, triggering `conversationsPublisher` and prompting `ConversationListViewModel` to re-derive the preview text from the now-recalled message.

---

## Files Changed

| File | Change |
|------|--------|
| `Sources/IMStorage/MessageEnums.swift` | Add `case recalled = 80` |
| `Sources/IMStorage/StoredMessage.swift` | Add `.recalled` to `MessageContent` enum + `setContent` + `content` var |
| `Sources/IMStorage/MessageStore.swift` | Add `updateContent(id:content:db:)` transaction variant |
| `Sources/IMMessaging/RecallNotifyMessageHandler.swift` | New file |
| `Sources/IMMessaging/MessagingService.swift` | Register handler; expose `onMessageRecalled` |
| `Sources/IMKit/ConversationViewModel.swift` | Handle `.recalled` in `makeRow` |
| `Sources/IMKit/ConversationListViewModel.swift` | Add `currentUserId`; recalled preview text |
| `App/SceneDelegate.swift` | Pass `currentUserId` to `ConversationListViewModel` |

---

## Out of Scope

- Sending a recall (client → server PUBLISH/MR): not implemented in this spec.
- Re-edit affordance after recall: explicitly excluded (user decision).
- Recall within a time window enforcement: server-side only.
