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
    private var searchGeneration = 0

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
