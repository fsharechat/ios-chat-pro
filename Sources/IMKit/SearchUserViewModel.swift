// Sources/IMKit/SearchUserViewModel.swift
import Foundation
import Combine
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
    private let currentUserId: String
    private var searchGeneration = 0

    public init(userSearching: UserSearching?, friendRequestSending: FriendRequestSending?, storage: IMStorage, currentUserId: String) {
        self.userSearching = userSearching
        self.friendRequestSending = friendRequestSending
        self.storage = storage
        self.currentUserId = currentUserId
    }

    /// An empty keyword clears `results` without sending a request — the
    /// caller (debounced in `SearchUserViewController`) is expected to
    /// call this on every text change, including when the user has
    /// cleared the search bar entirely.
    public func search(keyword: String) {
        searchGeneration += 1
        let generation = searchGeneration
        guard !keyword.isEmpty else {
            results = []
            return
        }
        userSearching?.searchUser(keyword: keyword) { [weak self] result in
            guard let self, self.searchGeneration == generation else { return }
            switch result {
            case .success(let uids):
                // Existing friends have no business on the "add friend"
                // screen — they're already in the contact list. Nor does
                // the current user: you can't friend yourself.
                self.results = uids.compactMap { uid in
                    if uid == self.currentUserId { return nil }
                    let user = try? self.storage.users.user(uid: uid)
                    if user?.isFriend == true { return nil }
                    let displayName = user?.displayName ?? user?.name ?? uid
                    return ContactRow(uid: uid, displayName: displayName, avatarURL: user?.portrait, sectionLetter: "")
                }
            case .failure:
                self.results = []
            }
        }
    }

    /// Prefilled verification message, matching Android's
    /// `InviteFriendActivity`: "我是 <my display name>". Empty when the
    /// local profile hasn't synced yet — the UI just shows its placeholder.
    public var defaultRequestReason: String {
        let me = try? storage.users.user(uid: currentUserId)
        guard let name = me?.displayName ?? me?.name, !name.isEmpty else { return "" }
        return "我是 \(name)"
    }

    public func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        friendRequestSending?.sendFriendRequest(to: uid, reason: reason, completion: completion)
    }
}
