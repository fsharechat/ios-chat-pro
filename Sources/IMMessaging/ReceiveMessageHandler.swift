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
        // One write transaction for the whole pulled batch, not one per
        // message — a first-login (or long-offline) pull can return
        // hundreds of messages in a single MP response, and per-message
        // transactions would re-trigger conversationsPublisher once per
        // message, each causing a full conversation-list re-sort downstream
        // in ConversationListViewModel (visible as UI lag right after
        // login), plus a redundant UPUI re-fetch for any uid still
        // unresolved at that snapshot.
        try? storage.write { db in
            for wireMessage in result.message {
                persist(wireMessage, db: db)
            }
            advanceSyncHead(to: result.head, db: db)
        }
    }

    /// Wire types 401/402/403/404 (Answer/Bye/Signal/Modify) are
    /// intentionally never persisted to `storage.messages` — on Android
    /// these are `PersistFlag.No_Persist`/`.Transparent`, and at the volume
    /// ICE candidates/SDP exchanges happen during call setup, writing each
    /// one as a chat message row would spam the conversation's last-message
    /// preview. They're forwarded via `onCallSignal` instead and returned
    /// from early, before this method's normal persist-and-update-
    /// conversation flow runs. Type 400 (CallStart) is the one call-related
    /// type that *does* persist — it's the call-record bubble — so it falls
    /// through to the same path as every other message type below.
    private func persist(_ wireMessage: Im_Message, db: Database) {
        guard wireMessage.messageID != 0 else { return }
        if (try? storage.messages.message(uid: wireMessage.messageID, db: db)) != nil {
            return // already have it via server uid — pull windows can overlap
        }

        if [401, 402, 403, 404].contains(wireMessage.content.type) {
            onCallSignal?(wireMessage)
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

        let conversationType = ConversationType(rawValue: Int(wireMessage.conversation.type)) ?? .single
        // System-notification pushes (`chat-server-pro`'s `ImOpenApiController`,
        // `fromUser` always `"SystemNotification"`) deliberately send
        // `conversation.target = ""` and rely on the receiver treating the
        // sender as the conversation party — there's no "other side" to
        // name for a server-originated broadcast. A single-chat
        // conversation literally keyed by `""` can never resolve a display
        // name/avatar (no user has uid `""`), so the sender fills in here
        // whenever the wire payload leaves the target blank.
        let target = (conversationType == .single && direction == .receive && wireMessage.conversation.target.isEmpty)
            ? wireMessage.fromUser
            : wireMessage.conversation.target
        let line = Int(wireMessage.conversation.line)
        let mentionedType = Int(wireMessage.content.mentionedType)
        let mentionedTargets = wireMessage.content.mentionedTarget
        let isMentioned = conversationType == .group && direction == .receive
            && (mentionedType == 2 || (mentionedType == 1 && mentionedTargets.contains(myUserId())))

        do {
            let inserted = try storage.messages.insert(StoredMessage(
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
            ), db: db)
            try storage.conversations.recordIncomingMessage(
                conversationType: conversationType,
                target: target,
                line: line,
                messageUid: wireMessage.messageID,
                timestamp: wireMessage.serverTimestamp,
                incrementUnread: direction == .receive,
                incrementMention: isMentioned,
                db: db
            )
            if case .groupNotification = content {
                onGroupNotificationMessage?(target)
            }
            if case .callRecord = content, direction == .receive {
                onCallStartMessage?(inserted)
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
