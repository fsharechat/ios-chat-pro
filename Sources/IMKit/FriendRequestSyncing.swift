// Sources/IMKit/FriendRequestSyncing.swift
import IMContacts

/// Narrow interface `NewFriendsViewModel` depends on instead of the
/// concrete `ContactSyncService` — same decoupling pattern as
/// `ImageUploading`/`ContactInfoFetching`.
public protocol FriendRequestSyncing: AnyObject {
    func syncFriendRequests()
    func markFriendRequestsAsRead()
}

extension ContactSyncService: FriendRequestSyncing {}
