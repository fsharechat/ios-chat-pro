// Sources/IMKit/MyProfileViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the「我的」tab's profile card and profile-detail screen: the
/// logged-in user's own `displayName`/`avatarURL`, kept in sync with
/// `IMStorage.UserStore`, plus the two mutations Android's `MeFragment`
/// exposes (change nickname, change avatar).
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class MyProfileViewModel {
    public let myUid: String

    @Published public private(set) var displayName: String = ""
    @Published public private(set) var avatarURL: String?

    private let profileUpdating: ProfileUpdating?
    private var cancellable: AnyCancellable?

    public init(myUid: String, storage: IMStorage, profileUpdating: ProfileUpdating?, contactSync: ContactInfoFetching?) {
        self.myUid = myUid
        self.profileUpdating = profileUpdating

        cancellable = storage.users.usersPublisher()
            .replaceError(with: [])
            .compactMap { users in users.first { $0.uid == myUid } }
            .sink { [weak self] user in
                self?.displayName = user.displayName ?? user.name ?? myUid
                self?.avatarURL = user.portrait
            }

        // Mirrors `ConversationListViewModel`'s "always ask, let
        // `ContactSyncService` decide if a round trip is needed" pattern —
        // the iOS login flow has never fetched the logged-in user's own
        // profile before this feature, so the first call after a fresh
        // login is never a no-op.
        contactSync?.fetchUserInfo(uids: [myUid], forceRefresh: false)
    }

    public func updateDisplayName(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let profileUpdating else { return }
        profileUpdating.updateDisplayName(name, completion: completion)
    }

    public func updatePortrait(_ url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let profileUpdating else { return }
        profileUpdating.updatePortrait(url, completion: completion)
    }
}
