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
        // Deduplicate by fromUid. The DB should already be clean (FriendRequestSyncHandler
        // filters out outgoing requests), but this guards against stale data from
        // before that fix was deployed, which would otherwise crash DiffableDataSource
        // with "supplied item identifiers are not unique".
        var seen = Set<String>()
        rows = requests.compactMap { request in
            guard seen.insert(request.fromUid).inserted else { return nil }
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
