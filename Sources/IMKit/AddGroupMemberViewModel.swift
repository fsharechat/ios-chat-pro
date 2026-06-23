// Sources/IMKit/AddGroupMemberViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the "add member" screen for an EXISTING group: a multi-select
/// friend list excluding whoever is already a member, plus a confirm
/// action that calls `GroupActing.addMembers`. Closes the gap where
/// `GroupInfoViewModel.addMembers`/`canAddMembers` existed with no UI
/// caller — this is that caller's view model.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class AddGroupMemberViewModel {
    public struct SelectableRow: Equatable, Hashable {
        public let contact: ContactRow
        public var isSelected: Bool
    }

    @Published public private(set) var rows: [SelectableRow] = []
    @Published public private(set) var selectedCount: Int = 0

    private let groupId: String
    private let groupActing: GroupActing?
    private let groupSyncing: GroupSyncing?
    private var cancellable: AnyCancellable?

    public init(groupId: String, storage: IMStorage, groupActing: GroupActing?, groupSyncing: GroupSyncing?) {
        self.groupId = groupId
        self.groupActing = groupActing
        self.groupSyncing = groupSyncing

        cancellable = Publishers.CombineLatest(
            storage.users.friendsPublisher().replaceError(with: []),
            storage.groups.membersPublisher(groupId: groupId).replaceError(with: [])
        )
        .sink { [weak self] users, existingMembers in
            self?.handleUpdate(users: users, existingMembers: existingMembers)
        }
    }

    private func handleUpdate(users: [StoredUser], existingMembers: [StoredGroupMember]) {
        let existingUids = Set(existingMembers.map(\.memberId))
        let selectedUids = Set(rows.filter(\.isSelected).map(\.contact.uid))
        rows = users
            .filter { !existingUids.contains($0.uid) }
            .map { user in
                let displayName = user.displayName ?? user.name ?? user.uid
                let contact = ContactRow(uid: user.uid, displayName: displayName, avatarURL: user.portrait, sectionLetter: PinyinIndexer.sectionLetter(for: displayName))
                return SelectableRow(contact: contact, isSelected: selectedUids.contains(user.uid))
            }
        selectedCount = rows.filter(\.isSelected).count
    }

    public func toggleSelection(uid: String) {
        guard let index = rows.firstIndex(where: { $0.contact.uid == uid }) else { return }
        rows[index].isSelected.toggle()
        selectedCount = rows.filter(\.isSelected).count
    }

    public func addSelectedMembers(completion: @escaping (Result<Void, Error>) -> Void) {
        let memberIds = rows.filter(\.isSelected).map(\.contact.uid)
        groupActing?.addMembers(groupId: groupId, memberIds: memberIds) { [weak self] result in
            if case .success = result {
                self?.groupSyncing?.refreshMembers(targetId: self?.groupId ?? "")
            }
            completion(result)
        }
    }
}
