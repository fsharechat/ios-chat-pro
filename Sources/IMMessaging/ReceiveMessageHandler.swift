import Foundation
import IMClient
import IMTransport
import IMProto
import IMStorage
import GRDB

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

    /// Fired after persisting a *received* (never my own echoed-back) 400
    /// CallStart message — `IMCall.CallManager` wires this to learn about
    /// an incoming call. Carries the full `StoredMessage` (not just the
    /// caller's uid) so the caller has the row's `id` on hand for later
    /// `MessageStore.updateContent` calls without a second lookup.
    public var onCallStartMessage: ((StoredMessage) -> Void)?

    /// Fired for every 401/402/403/404 (Answer/Bye/Signal/Modify) message —
    /// these are intentionally **never persisted** (see this type's
    /// `persist(_:)` doc comment below), so this is the only way `IMCall`
    /// ever sees them. Carries the raw wire `Im_Message` rather than a
    /// decoded type, because decoding these 4 signal shapes is `IMCall`'s
    /// job (`CallSignalCodec`) — `IMMessaging` only needs to know "this is
    /// call signaling, don't persist it."
    public var onCallSignal: ((Im_Message) -> Void)?

    /// Set to `true` before an initial-sync pull (localHead == 0) so that
    /// historical messages don't generate unread badges on first login.
    /// Automatically reset to `false` after the first batch is processed.
    public var suppressUnreadIncrement = false

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
        print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] ReceiveMessageHandler: mp frame parsed, messages=\(result.message.count) head=\(result.head)")
        // One write transaction for the whole pulled batch, not one per
        // message — a first-login (or long-offline) pull can return
        // hundreds of messages in a single MP response, and per-message
        // transactions would re-trigger conversationsPublisher once per
        // message, each causing a full conversation-list re-sort downstream
        // in ConversationListViewModel (visible as UI lag right after
        // login), plus a redundant UPUI re-fetch for any uid still
        // unresolved at that snapshot.
        let shouldSuppressUnread = suppressUnreadIncrement
        suppressUnreadIncrement = false
        var groupNotificationTargets: Set<String> = []
        var callStartMessages: [StoredMessage] = []
        var callSignalMessages: [Im_Message] = []
        let t0 = ProcessInfo.processInfo.systemUptime
        try? storage.write { db in
            for wireMessage in result.message {
                persist(wireMessage, db: db, suppressUnread: shouldSuppressUnread, groupNotificationTargets: &groupNotificationTargets, callStartMessages: &callStartMessages, callSignalMessages: &callSignalMessages)
            }
            advanceSyncHead(to: result.head, db: db)
        }
        print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] ReceiveMessageHandler: write done, elapsed=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-t0))s")
        // Fired only once the write transaction above has released the
        // GRDB serial queue: both callbacks can themselves trigger further
        // synchronous database access (`GroupSyncService.refreshGroup` reads,
        // `CallManager`'s call-bubble updates write) — GRDB's queue isn't
        // reentrant, so calling these from inside `storage.write` crashes
        // (`GRDBPrecondition` fatal error) the first time either fires
        // during a batch, e.g. a group-notification message in the
        // historical pull right after logging into a different account.
        for target in groupNotificationTargets {
            onGroupNotificationMessage?(target)
        }
        for message in callStartMessages {
            onCallStartMessage?(message)
        }
        for wireMessage in callSignalMessages {
            onCallSignal?(wireMessage)
        }
    }

    /// Wire types 401-405 (Answer/Bye/Signal/Modify/AnswerT) are
    /// intentionally never persisted to `storage.messages` — on Android
    /// these are `PersistFlag.No_Persist`/`.Transparent`, and at the volume
    /// ICE candidates/SDP exchanges happen during call setup, writing each
    /// one as a chat message row would spam the conversation's last-message
    /// preview. They're forwarded via `onCallSignal` instead and returned
    /// from early, before this method's normal persist-and-update-
    /// conversation flow runs. Type 400 (CallStart) is the one call-related
    /// type that *does* persist — it's the call-record bubble — so it falls
    /// through to the same path as every other message type below.
    private func persist(_ wireMessage: Im_Message, db: Database, suppressUnread: Bool, groupNotificationTargets: inout Set<String>, callStartMessages: inout [StoredMessage], callSignalMessages: inout [Im_Message]) {
        guard wireMessage.messageID != 0 else { return }
        if (try? storage.messages.message(uid: wireMessage.messageID, db: db)) != nil {
            return // already have it via server uid — pull windows can overlap
        }

        if [401, 402, 403, 404, 405].contains(wireMessage.content.type) {
            // 不能在这里(写事务内)直接回调 —— CallManager 的信令处理会同步
            // 写库(更新通话气泡),GRDB 串行队列不可重入;与 callStartMessages
            // 相同的"事务后再发"模式。
            callSignalMessages.append(wireMessage)
            return
        }

        let direction: MessageDirection = wireMessage.fromUser == myUserId() ? .send : .receive

        if direction == .send, wireMessage.localMessageID != 0,
           (try? storage.messages.message(localMessageId: wireMessage.localMessageID, db: db)) != nil {
            try? storage.messages.updateMessageUid(localMessageId: wireMessage.localMessageID, messageUid: wireMessage.messageID, db: db)
            try? storage.messages.updateStatus(localMessageId: wireMessage.localMessageID, status: .sent, db: db)
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
        // Recalled messages: Android puts operatorId in payload.content; fall
        // back to fromUser (the original sender, identical to the operator in
        // the self-recall case that covers 99% of recalls) when absent.
        if case .recalled(let operatorId) = content, operatorId.isEmpty {
            content = .recalled(operatorId: wireMessage.fromUser)
        }

        let conversationType = ConversationType(rawValue: Int(wireMessage.conversation.type)) ?? .single
        // For single-chat, the server always sets conversation.target to the
        // *recipient* uid (i.e. the current user when receiving). The correct
        // conversation key is the *other* party — fromUser when receiving,
        // conversation.target when sending. This mirrors Android's
        // convertProtoMessage logic (AbstractProtoService.java lines 739-747).
        // System-notification pushes set fromUser = "SystemNotification" and
        // target = ""; the receiving branch below handles that correctly too.
        let target: String
        if conversationType == .single && direction == .receive {
            target = wireMessage.fromUser
        } else {
            target = wireMessage.conversation.target
        }
        let line = Int(wireMessage.conversation.line)
        let mentionedType = Int(wireMessage.content.mentionedType)
        let mentionedTargets = wireMessage.content.mentionedTarget
        let isMentioned = conversationType == .group && direction == .receive
            && (mentionedType == 2 || (mentionedType == 1 && mentionedTargets.contains(myUserId())))

        do {
            // Server-generated messages (group notifications, etc.) have
            // localMessageID == 0 because the client never assigned one.
            // Inserting multiple such messages as direction=.send would violate
            // the partial unique index on (localMessageId) WHERE direction=send.
            // Use the server-assigned messageUID as a unique surrogate in that case.
            let storedLocalMessageId = (direction == .send && wireMessage.localMessageID == 0)
                ? wireMessage.messageID
                : wireMessage.localMessageID
            let inserted = try storage.messages.insert(StoredMessage(
                localMessageId: storedLocalMessageId,
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
            ), db: db)
            try storage.conversations.recordIncomingMessage(
                conversationType: conversationType,
                target: target,
                line: line,
                messageUid: wireMessage.messageID,
                timestamp: wireMessage.serverTimestamp,
                incrementUnread: direction == .receive && !suppressUnread,
                incrementMention: isMentioned && !suppressUnread,
                db: db
            )
            if case .groupNotification = content {
                groupNotificationTargets.insert(target)
            }
            if case .callRecord = content, direction == .receive {
                callStartMessages.append(inserted)
            }
        } catch {
            // Best-effort: one malformed/unexpected row shouldn't abort the rest of the batch.
        }
    }

    private func advanceSyncHead(to head: Int64, db: Database) {
        guard let current = try? storage.syncState.get(db: db), head > current.msgHead else { return }
        try? storage.syncState.set(StoredSyncState(
            msgHead: head,
            friendHead: current.friendHead,
            friendRequestHead: current.friendRequestHead,
            settingHead: current.settingHead
        ), db: db)
    }
}
