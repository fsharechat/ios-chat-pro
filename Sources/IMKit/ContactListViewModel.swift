import Foundation
import Combine
import IMStorage

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ContactListViewModel {
    @Published public private(set) var sections: [(letter: String, rows: [ContactRow])] = []
    @Published public private(set) var unreadFriendRequestCount: Int = 0

    private let storage: IMStorage
    private let contactSync: ContactInfoFetching?
    private var cancellable: AnyCancellable?
    private var friendRequestCountCancellable: AnyCancellable?

    public init(storage: IMStorage, contactSync: ContactInfoFetching?) {
        self.storage = storage
        self.contactSync = contactSync
        cancellable = storage.users.friendsPublisher()
            .replaceError(with: [])
            .sink { [weak self] users in
                print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] friendsPublisher emitted \(users.count) rows")
                self?.handleFriendsUpdate(users)
            }
        friendRequestCountCancellable = storage.friendRequests.unreadIncomingCountPublisher()
            .replaceError(with: 0)
            .sink { [weak self] count in self?.unreadFriendRequestCount = count }
    }

    private func handleFriendsUpdate(_ users: [StoredUser]) {
        var unresolvedUids: [String] = []

        let rows = users.map { user -> ContactRow in
            if user.displayName == nil && user.name == nil {
                unresolvedUids.append(user.uid)
            }
            let displayName = user.displayName ?? user.name ?? user.uid
            return ContactRow(
                uid: user.uid,
                displayName: displayName,
                avatarURL: user.portrait,
                sectionLetter: PinyinIndexer.sectionLetter(for: displayName)
            )
        }

        if !unresolvedUids.isEmpty {
            contactSync?.fetchUserInfo(uids: unresolvedUids, forceRefresh: false)
        }

        let grouped = Dictionary(grouping: rows, by: { $0.sectionLetter })
        let sortedLetters = grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        sections = sortedLetters.map { letter in
            let sortedRows = grouped[letter]!.sorted { PinyinIndexer.sortKey(for: $0.displayName) < PinyinIndexer.sortKey(for: $1.displayName) }
            return (letter: letter, rows: sortedRows)
        }
    }
}
