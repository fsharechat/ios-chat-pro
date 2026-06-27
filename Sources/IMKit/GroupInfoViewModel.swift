// Sources/IMKit/GroupInfoViewModel.swift
import Foundation
import Combine
import IMStorage

/// Drives the group-info screen: member list, group info, conversation settings,
/// and message operations. The permission matrix is verified against real
/// server-side permission-check code (see design doc §4):
///
/// |              | Restricted   | Normal      | Free       |
/// |--------------|--------------|-------------|------------|
/// | add member   | owner only   | any member  | any member |
/// | kick member  | owner only   | owner only  | nobody     |
/// | modify info  | owner only   | any member  | any member |
/// | dismiss      | owner only   | owner only  | nobody     |
/// | quit         | any member   | any member  | any member |
///
/// **Threading contract:** no internal locking, call from a single consistent queue.
public final class GroupInfoViewModel {
    public struct MemberRow: Equatable, Hashable {
        public let uid: String
        public let displayName: String
        public let avatarURL: String?
        public let isOwner: Bool
    }

    // Group info
    @Published public private(set) var group: StoredGroup?
    @Published public private(set) var members: [MemberRow] = []

    // Permissions
    @Published public private(set) var canAddMembers: Bool = false
    @Published public private(set) var canKickMembers: Bool = false
    @Published public private(set) var canModifyInfo: Bool = false
    @Published public private(set) var canDismiss: Bool = false

    // Conversation settings (initialized from storage, updated optimistically)
    @Published public private(set) var isTop: Bool = false
    @Published public private(set) var isMuted: Bool = false
    @Published public private(set) var isFav: Bool = false

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

        // Load initial conversation settings (isTop, isMuted) from stored conversation
        if let conversation = try? storage.conversations.conversation(conversationType: .group, target: groupId) {
            self.isTop = conversation.isTop
            self.isMuted = conversation.isMuted
        }

        groupCancellable = storage.groups.groupPublisher(groupId: groupId)
            .replaceError(with: nil)
            .sink { [weak self] group in
                self?.handleGroupUpdate(group)
                self?.isFav = group?.isFav ?? false
            }
        membersCancellable = storage.groups.membersPublisher(groupId: groupId)
            .replaceError(with: [])
            .sink { [weak self] members in self?.handleMembersUpdate(members) }
    }

    public func refresh() {
        groupSyncing?.refreshGroup(targetId: groupId)
    }

    // MARK: - Member Actions

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

    // MARK: - Conversation Settings

    public func setTop(_ value: Bool) {
        isTop = value
        try? storage.conversations.setTop(value, conversationType: .group, target: groupId)
    }

    public func setMuted(_ value: Bool) {
        isMuted = value
        try? storage.conversations.setMuted(value, conversationType: .group, target: groupId)
    }

    public func setFav(_ value: Bool) {
        isFav = value
        try? storage.groups.setFav(value, groupId: groupId)
    }

    // MARK: - Message Operations

    public func clearMessages(completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try storage.messages.clearMessages(conversationType: .group, target: groupId)
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    public func searchMessages(keyword: String) -> [StoredMessage] {
        (try? storage.messages.searchMessages(conversationType: .group, target: groupId, keyword: keyword)) ?? []
    }

    // MARK: - Private

    private func handleGroupUpdate(_ group: StoredGroup?) {
        self.group = group
        self.isFav = group?.isFav ?? false
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
            canAddMembers = false; canKickMembers = false
            canModifyInfo = false; canDismiss = false
            return
        }
        let isOwner = group.owner == currentUserId
        switch group.groupType {
        case .restricted:
            canAddMembers = isOwner; canKickMembers = isOwner
            canModifyInfo = isOwner; canDismiss = isOwner
        case .normal:
            canAddMembers = true; canKickMembers = isOwner
            canModifyInfo = true; canDismiss = isOwner
        case .free:
            canAddMembers = true; canKickMembers = false
            canModifyInfo = true; canDismiss = false
        }
    }
}
