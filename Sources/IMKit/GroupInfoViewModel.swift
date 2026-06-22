// Sources/IMKit/GroupInfoViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the group-info screen: member list, and the 4 permission-gated
/// actions (add/kick/modify-info/dismiss) plus quit (always allowed). The
/// permission matrix below is verified against the real server-side
/// `Handler`/`MemoryMessagesStore` permission-check code (see the design
/// doc §4) — not guessed:
///
/// |              | Restricted   | Normal      | Free       |
/// |--------------|--------------|-------------|------------|
/// | add member   | owner only   | any member  | any member |
/// | kick member  | owner only   | owner only  | nobody     |
/// | modify info  | owner only   | any member  | any member |
/// | dismiss      | owner only   | owner only  | nobody     |
/// | quit         | any member   | any member  | any member |
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class GroupInfoViewModel {
    public struct MemberRow: Equatable, Hashable {
        public let uid: String
        public let displayName: String
        public let avatarURL: String?
        public let isOwner: Bool
    }

    @Published public private(set) var group: StoredGroup?
    @Published public private(set) var members: [MemberRow] = []
    @Published public private(set) var canAddMembers: Bool = false
    @Published public private(set) var canKickMembers: Bool = false
    @Published public private(set) var canModifyInfo: Bool = false
    @Published public private(set) var canDismiss: Bool = false

    private let groupId: String
    private let groupActing: GroupActing?
    private let groupSyncing: GroupSyncing?
    private let storage: IMStorage
    private let currentUserId: String
    private var groupCancellable: AnyCancellable?
    private var membersCancellable: AnyCancellable?

    public init(groupId: String, groupActing: GroupActing?, groupSyncing: GroupSyncing?, storage: IMStorage, currentUserId: String) {
        self.groupId = groupId
        self.groupActing = groupActing
        self.groupSyncing = groupSyncing
        self.storage = storage
        self.currentUserId = currentUserId

        groupCancellable = storage.groups.groupPublisher(groupId: groupId)
            .replaceError(with: nil)
            .sink { [weak self] group in self?.handleGroupUpdate(group) }
        membersCancellable = storage.groups.membersPublisher(groupId: groupId)
            .replaceError(with: [])
            .sink { [weak self] members in self?.handleMembersUpdate(members) }
    }

    /// Call when the page appears: pulls fresh group info + member list.
    public func refresh() {
        groupSyncing?.refreshGroup(targetId: groupId)
    }

    public func addMembers(_ uids: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.addMembers(groupId: groupId, memberIds: uids) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshMembers(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func kickMember(_ uid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.kickMember(groupId: groupId, memberId: uid) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshMembers(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func renameGroup(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.modifyGroupInfo(groupId: groupId, type: .name, value: name) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshGroup(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func updatePortrait(url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.modifyGroupInfo(groupId: groupId, type: .portrait, value: url) { [weak self] result in
            if case .success = result { self?.groupSyncing?.refreshGroup(targetId: self?.groupId ?? "") }
            completion(result)
        }
    }

    public func quitGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.quitGroup(groupId: groupId, completion: completion)
    }

    public func dismissGroup(completion: @escaping (Result<Void, Error>) -> Void) {
        groupActing?.dismissGroup(groupId: groupId, completion: completion)
    }

    private func handleGroupUpdate(_ group: StoredGroup?) {
        self.group = group
        recomputePermissions()
    }

    private func handleMembersUpdate(_ storedMembers: [StoredGroupMember]) {
        members = storedMembers.map { member in
            let user = try? storage.users.user(uid: member.memberId)
            return MemberRow(
                uid: member.memberId,
                displayName: user?.displayName ?? user?.name ?? member.memberId,
                avatarURL: user?.portrait,
                isOwner: member.memberType == .owner
            )
        }
    }

    private func recomputePermissions() {
        guard let group else {
            canAddMembers = false
            canKickMembers = false
            canModifyInfo = false
            canDismiss = false
            return
        }
        let isOwner = group.owner == currentUserId
        switch group.groupType {
        case .restricted:
            canAddMembers = isOwner
            canKickMembers = isOwner
            canModifyInfo = isOwner
            canDismiss = isOwner
        case .normal:
            canAddMembers = true
            canKickMembers = isOwner
            canModifyInfo = true
            canDismiss = isOwner
        case .free:
            canAddMembers = true
            canKickMembers = false
            canModifyInfo = true
            canDismiss = false
        }
    }
}
