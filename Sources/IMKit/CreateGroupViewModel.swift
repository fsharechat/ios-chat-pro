// Sources/IMKit/CreateGroupViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the create-group screen: a multi-select friend list (reusing the
/// same `ContactRow` shape as the contacts tab) plus a name field. On
/// success, immediately triggers a `GroupSyncing.refreshGroup` for the
/// server-assigned id — group metadata/membership is only ever populated by
/// that passive-discovery pull (see the design doc §4), never by this
/// view-model writing to `GroupStore` directly.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class CreateGroupViewModel {
    public struct SelectableRow: Equatable, Hashable {
        public let contact: ContactRow
        public var isSelected: Bool
    }

    @Published public private(set) var rows: [SelectableRow] = []
    @Published public private(set) var selectedCount: Int = 0

    private let groupActing: GroupActing?
    private let groupSyncing: GroupSyncing?
    private var cancellable: AnyCancellable?

    public init(storage: IMStorage, groupActing: GroupActing?, groupSyncing: GroupSyncing?) {
        self.groupActing = groupActing
        self.groupSyncing = groupSyncing

        cancellable = storage.users.friendsPublisher()
            .replaceError(with: [])
            .sink { [weak self] users in self?.handleFriendsUpdate(users) }
    }

    private func handleFriendsUpdate(_ users: [StoredUser]) {
        let selectedUids = Set(rows.filter(\.isSelected).map(\.contact.uid))
        rows = users.map { user in
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

    public enum StartChatResult: Equatable {
        case single(uid: String)
        case group(groupId: String, name: String)
    }

    /// "发起聊天" semantics, aligned with Android's `CreateConversationActivity`:
    /// exactly one contact selected opens a single chat directly; two or more
    /// creates a group named after the first few members. No callback fires
    /// for an empty selection (the UI disables the confirm button anyway).
    public func startChat(completion: @escaping (Result<StartChatResult, Error>) -> Void) {
        let selected = rows.filter(\.isSelected).map(\.contact)
        guard let first = selected.first else { return }
        guard selected.count > 1 else {
            completion(.success(.single(uid: first.uid)))
            return
        }
        let name = Self.autoGroupName(from: selected.map(\.displayName))
        createGroup(name: name) { result in
            completion(result.map { .group(groupId: $0, name: name) })
        }
    }

    /// Android caps the auto-generated name at the first 3 display names
    /// joined by "、" (`GroupViewModel.createGroup`).
    public static func autoGroupName(from displayNames: [String]) -> String {
        displayNames.prefix(3).joined(separator: "、")
    }

    public func createGroup(name: String, completion: @escaping (Result<String, Error>) -> Void) {
        let memberIds = rows.filter(\.isSelected).map(\.contact.uid)
        groupActing?.createGroup(name: name, memberIds: memberIds) { [weak self] result in
            if case .success(let groupId) = result {
                self?.groupSyncing?.refreshGroup(targetId: groupId)
            }
            completion(result)
        }
    }
}
