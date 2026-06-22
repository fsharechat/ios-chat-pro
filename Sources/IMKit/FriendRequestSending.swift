// Sources/IMKit/FriendRequestSending.swift
import IMContacts

/// Narrow interface `SearchUserViewModel`/`NewFriendsViewModel` depend on
/// instead of the concrete `ContactSyncService` — same decoupling pattern
/// as `ImageUploading`/`ContactInfoFetching`.
public protocol FriendRequestSending: AnyObject {
    func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void)
    func acceptFriendRequest(from uid: String, completion: @escaping (Result<Void, Error>) -> Void)
}

extension ContactSyncService: FriendRequestSending {}
