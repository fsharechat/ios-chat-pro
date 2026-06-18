import Foundation
import Combine
import IMStorage

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
