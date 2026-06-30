import Foundation
import Combine
import IMStorage

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ConversationListViewModel {
    @Published public private(set) var rows: [ConversationRow] = []

    private let storage: IMStorage
    private let contactSync: ContactInfoFetching?
    private let groupSync: GroupSyncing?
    private let currentUserId: String
    private var cancellable: AnyCancellable?

    public init(storage: IMStorage, contactSync: ContactInfoFetching?, groupSync: GroupSyncing? = nil, currentUserId: String = "") {
        self.storage = storage
        self.contactSync = contactSync
        self.groupSync = groupSync
        self.currentUserId = currentUserId

        // A row's displayName/avatarURL is derived from `UserStore`/
        // `GroupStore`, not just `StoredConversation` — and that profile
        // commonly resolves *asynchronously*, well after the conversation
        // itself was first written (a `UPUI`/`gpgi` round trip following
        // this view model's own `fetchUserInfo`/`refreshGroup` call below).
        // Driving off `conversationsPublisher()` alone means that once it
        // fires, nothing ever re-derives the rows again — so a profile that
        // arrives later leaves the row frozen on its uid-fallback
        // placeholder forever. Combining with `usersPublisher()`/
        // `groupsPublisher()` re-runs the same derivation whenever a
        // profile resolves, using the latest known conversations.
        cancellable = storage.conversations.conversationsPublisher()
            .replaceError(with: [])
            .combineLatest(
                storage.users.usersPublisher().replaceError(with: []),
                storage.groups.groupsPublisher().replaceError(with: [])
            )
            .map { conversations, _, _ in conversations }
            .sink { [weak self] conversations in self?.handleConversationsUpdate(conversations) }
    }

    private func handleConversationsUpdate(_ conversations: [StoredConversation]) {
        var unresolvedUids: [String] = []
        var unresolvedGroupIds: [String] = []

        // If either lookup fails, this silently falls back to "no last
        // message"/"no profile" with no diagnostic trail — accepted for
        // Phase 1 since there's no logging facility yet, same as
        // ReceiveMessageHandler/CredentialsStore/FriendSyncHandler/UserInfoSyncHandler.
        rows = conversations.map { conversation in
            let lastMessage = (try? storage.messages.messages(
                conversationType: conversation.conversationType,
                target: conversation.target,
                line: conversation.line,
                limit: 1
            ))?.first

            if conversation.conversationType == .group {
                return makeGroupRow(conversation: conversation, lastMessage: lastMessage, unresolvedGroupIds: &unresolvedGroupIds)
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
                previewText: conversation.draft.map { "[草稿] \($0)" } ?? recalledPreviewText(for: lastMessage) ?? lastMessage?.searchableContent ?? "",
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
        // No batched "many uids at once" call here, unlike `fetchUserInfo`
        // above — `GroupSyncing.refreshGroup(targetId:)` only ever pulls one
        // group at a time (mirrors every other call site, e.g.
        // `GroupInfoViewModel`), and the conversation list realistically has
        // only a handful of distinct groups, nowhere near the friend-list
        // scale that made batching necessary there.
        for groupId in unresolvedGroupIds {
            groupSync?.refreshGroup(targetId: groupId)
        }
    }

    /// Group rows resolve their name/avatar from `GroupStore`, not
    /// `UserStore` — a group is not a user. The preview text is prefixed
    /// with the last message's sender's display name (per the design
    /// doc's "{sender}: {digest}" format), unlike single chat, which shows
    /// the digest alone.
    private func makeGroupRow(conversation: StoredConversation, lastMessage: StoredMessage?, unresolvedGroupIds: inout [String]) -> ConversationRow {
        let group = try? storage.groups.group(groupId: conversation.target)
        if group == nil {
            unresolvedGroupIds.append(conversation.target)
        }
        let previewText: String
        if let draft = conversation.draft {
            previewText = "[草稿] \(draft)"
        } else if let recalled = recalledPreviewText(for: lastMessage) {
            previewText = recalled
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

    public func setTop(_ isTop: Bool, for row: ConversationRow) throws {
        try storage.conversations.setTop(isTop, conversationType: row.conversationType, target: row.target, line: row.line)
    }

    public func clearConversation(_ row: ConversationRow) throws {
        try storage.messages.clearMessages(conversationType: row.conversationType, target: row.target, line: row.line)
        try storage.conversations.resetLastMessage(conversationType: row.conversationType, target: row.target, line: row.line)
    }

    public func deleteConversation(_ row: ConversationRow) throws {
        try storage.messages.clearMessages(conversationType: row.conversationType, target: row.target, line: row.line)
        try storage.conversations.deleteConversation(conversationType: row.conversationType, target: row.target, line: row.line)
    }

    /// Returns a recall notice string if `lastMessage` is a recalled message,
    /// `nil` otherwise. Caller falls through to normal preview text on `nil`.
    /// Uses "您" for the current user (matching Android's convention) and the
    /// operator's resolved display name for anyone else.
    private func recalledPreviewText(for lastMessage: StoredMessage?) -> String? {
        guard let msg = lastMessage, msg.contentType == .recalled else { return nil }
        let operatorId = msg.textContent ?? ""
        if operatorId == currentUserId { return "您撤回了一条消息" }
        let user = try? storage.users.user(uid: operatorId)
        let name = user?.displayName ?? user?.name ?? operatorId
        return "\(name)撤回了一条消息"
    }
}
