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

        sections = PinyinIndexer.sections(of: rows, name: \.displayName)
            .map { (letter: $0.letter, rows: $0.items) }
    }
}
