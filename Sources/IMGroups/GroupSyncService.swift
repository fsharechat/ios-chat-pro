// Sources/IMGroups/GroupSyncService.swift
import Foundation
import IMClient
import IMProto
import IMStorage

public enum GroupSyncServiceError: Error, Equatable {
    case requestEncodingFailed
}

/// The single entry point `IMKit`'s `GroupActing`/`GroupSyncing` conformance
/// wraps: registers every group `MessageHandler` with the given `IMClient`,
/// and exposes `createGroup`/`addMembers`/`kickMember`/`modifyGroupInfo`/
/// `quitGroup`/`dismissGroup`/`refreshGroup`/`refreshMembers`. Mirrors
/// `IMContacts`'s `ContactSyncService` shape exactly.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class GroupSyncService {
    private let imClient: IMClient
    private let storage: IMStorage
    private let actionTracker: GroupActionTracker
    private let createTracker: GroupCreateTracker
    private let memberSyncTracker: GroupMemberSyncTracker

    public init(imClient: IMClient, storage: IMStorage, scheduler: Scheduler = DispatchQueueScheduler()) {
        self.imClient = imClient
        self.storage = storage
        actionTracker = GroupActionTracker(scheduler: scheduler)
        createTracker = GroupCreateTracker(scheduler: scheduler)
        memberSyncTracker = GroupMemberSyncTracker(scheduler: scheduler)

        imClient.register(GroupCreateHandler(tracker: createTracker))
        imClient.register(GroupActionHandler(tracker: actionTracker))
        imClient.register(GroupInfoSyncHandler(storage: storage))
        imClient.register(GroupMemberSyncHandler(storage: storage, tracker: memberSyncTracker))
    }

    /// Always creates a `GroupType.normal` group — Phase 2's UI has no
    /// group-type picker (out of scope per the design doc). The creator
    /// must be explicitly included in `group.members` as `.owner`: unlike
    /// e.g. Android's own assumptions, `chat-server-pro`'s
    /// `MemoryMessagesStore.createGroup` does **not** auto-add the creator
    /// (verified by reading it) — omitting this would create a group the
    /// creator isn't even a member of.
    public func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void) {
        var groupInfo = Im_GroupInfo()
        groupInfo.name = name
        groupInfo.type = Int32(GroupType.normal.rawValue)

        var ownerMember = Im_GroupMember()
        ownerMember.memberID = imClient.userId
        ownerMember.type = Int32(GroupMemberType.owner.rawValue)

        var group = Im_Group()
        group.groupInfo = groupInfo
        group.members = [ownerMember] + memberIds.map { uid in
            var member = Im_GroupMember()
            member.memberID = uid
            member.type = Int32(GroupMemberType.normal.rawValue)
            return member
        }

        var request = Im_CreateGroupRequest()
        request.group = group
        guard let body = try? request.serializedData() else {
            completion(.failure(GroupSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gc, body: body)
        createTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    public func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_AddGroupMemberRequest()
        request.groupID = groupId
        request.addedMember = memberIds.map { uid in
            var member = Im_GroupMember()
            member.memberID = uid
            member.type = Int32(GroupMemberType.normal.rawValue)
            return member
        }
        guard let body = try? request.serializedData() else {
            completion(.failure(GroupSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gam, body: body)
        actionTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    public func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_RemoveGroupMemberRequest()
        request.groupID = groupId
        request.removedMember = [memberId]
        guard let body = try? request.serializedData() else {
            completion(.failure(GroupSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gkm, body: body)
        actionTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    public func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_ModifyGroupInfoRequest()
        request.groupID = groupId
        request.type = type.rawValue
        request.value = value
        guard let body = try? request.serializedData() else {
            completion(.failure(GroupSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gmi, body: body)
        actionTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    public func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_QuitGroupRequest()
        request.groupID = groupId
        guard let body = try? request.serializedData() else {
            completion(.failure(GroupSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gq, body: body)
        actionTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    public func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_DismissGroupRequest()
        request.groupID = groupId
        guard let body = try? request.serializedData() else {
            completion(.failure(GroupSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gd, body: body)
        actionTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    /// Pulls fresh group info, then fresh member info. Fire-and-forget —
    /// callers observe `IMStorage.groups`'s Combine publishers for the
    /// result rather than receiving a completion here, since both
    /// underlying handlers (`GroupInfoSyncHandler`/`GroupMemberSyncHandler`)
    /// write straight to `GroupStore`.
    public func refreshGroup(targetId: String) {
        var userRequest = Im_UserRequest()
        userRequest.uid = targetId
        var request = Im_PullUserRequest()
        request.request = [userRequest]
        if let body = try? request.serializedData() {
            imClient.sendFrame(signal: .publish, subSignal: .gpgi, body: body)
        }
        refreshMembers(targetId: targetId)
    }

    /// Incremental pull: sends the locally stored `memberUpdateDt` as
    /// `head` so the server only returns members changed since the last
    /// sync, same incremental-pull shape as `IMContacts`'s
    /// `syncFriendRequests()`.
    public func refreshMembers(targetId: String) {
        let head = (try? storage.groups.group(groupId: targetId))?.memberUpdateDt ?? 0
        var request = Im_PullGroupMemberRequest()
        request.target = targetId
        request.head = head
        guard let body = try? request.serializedData() else { return }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .gpgm, body: body)
        memberSyncTracker.track(wireMessageId: wireMessageId, groupId: targetId)
    }
}
