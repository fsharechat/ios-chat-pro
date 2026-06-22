// Sources/IMKit/GroupActing.swift
import Foundation
import IMStorage
import IMGroups

/// Narrow interface `CreateGroupViewModel`/`GroupInfoViewModel` depend on
/// instead of the concrete `GroupSyncService` — same decoupling-for-
/// testability pattern as `FriendRequestSending`/`UserSearching`.
public protocol GroupActing: AnyObject {
    func createGroup(name: String, memberIds: [String], completion: @escaping (Result<String, Error>) -> Void)
    func addMembers(groupId: String, memberIds: [String], completion: @escaping (Result<Void, Error>) -> Void)
    func kickMember(groupId: String, memberId: String, completion: @escaping (Result<Void, Error>) -> Void)
    func modifyGroupInfo(groupId: String, type: ModifyGroupInfoType, value: String, completion: @escaping (Result<Void, Error>) -> Void)
    func quitGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void)
    func dismissGroup(groupId: String, completion: @escaping (Result<Void, Error>) -> Void)
}

extension GroupSyncService: GroupActing {}
