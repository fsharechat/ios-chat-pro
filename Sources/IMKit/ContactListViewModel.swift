import Foundation
import Combine
import IMStorage

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ContactListViewModel {
    @Published public private(set) var sections: [(letter: String, rows: [ContactRow])] = []

    private let storage: IMStorage
    private var cancellable: AnyCancellable?

    public init(storage: IMStorage) {
        self.storage = storage
        cancellable = storage.users.friendsPublisher()
            .replaceError(with: [])
            .sink { [weak self] users in self?.handleFriendsUpdate(users) }
    }

    private func handleFriendsUpdate(_ users: [StoredUser]) {
        let rows = users.map { user -> ContactRow in
            let displayName = user.displayName ?? user.name ?? user.uid
            return ContactRow(
                uid: user.uid,
                displayName: displayName,
                avatarURL: user.portrait,
                sectionLetter: PinyinIndexer.sectionLetter(for: displayName)
            )
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
