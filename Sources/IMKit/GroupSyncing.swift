// Sources/IMKit/GroupSyncing.swift
import IMGroups

/// Narrow interface `CreateGroupViewModel`/`GroupInfoViewModel` depend on
/// instead of the concrete `GroupSyncService`.
public protocol GroupSyncing: AnyObject {
    func refreshGroup(targetId: String)
    func refreshMembers(targetId: String)
}

extension GroupSyncService: GroupSyncing {}
