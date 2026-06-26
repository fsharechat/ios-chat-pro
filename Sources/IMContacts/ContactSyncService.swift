// Sources/IMContacts/ContactSyncService.swift
import Foundation
import IMClient
import IMProto
import IMStorage

public enum ContactSyncServiceError: Error, Equatable {
    case requestEncodingFailed
}

/// The single entry point Plan G's UI code constructs (or, more likely,
/// `AppEnvironment` constructs once and Plan G's view models read
/// `IMStorage.UserStore` directly — this service only owns *sending*
/// requests, not data access): registers `FriendSyncHandler`/
/// `UserInfoSyncHandler`/`UserSearchHandler`/`FriendRequestActionHandler`/
/// `FriendRequestSyncHandler` with the given `IMClient`, and exposes
/// `syncFriendList()`/`fetchUserInfo(uids:forceRefresh:)`/`searchUser(...)`/
/// `sendFriendRequest(...)`/`acceptFriendRequest(...)`/
/// `syncFriendRequests()`/`markFriendRequestsAsRead()`.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ContactSyncService {
    private let imClient: IMClient
    private let storage: IMStorage
    private let userSearchTracker: UserSearchTracker
    private let friendRequestActionTracker: FriendRequestActionTracker
    private let profileUpdateTracker: ProfileUpdateTracker

    public init(imClient: IMClient, storage: IMStorage, scheduler: Scheduler = DispatchQueueScheduler()) {
        self.imClient = imClient
        self.storage = storage
        userSearchTracker = UserSearchTracker(scheduler: scheduler)
        friendRequestActionTracker = FriendRequestActionTracker(scheduler: scheduler)
        profileUpdateTracker = ProfileUpdateTracker(scheduler: scheduler)

        imClient.register(FriendSyncHandler(storage: storage))
        imClient.register(UserInfoSyncHandler(storage: storage))
        imClient.register(UserSearchHandler(storage: storage, tracker: userSearchTracker))
        imClient.register(FriendRequestActionHandler(tracker: friendRequestActionTracker))
        imClient.register(ProfileUpdateHandler(tracker: profileUpdateTracker))

        let friendRequestSyncHandler = FriendRequestSyncHandler(storage: storage)
        friendRequestSyncHandler.onRemoteUpdateNotified = { [weak self] in self?.syncFriendRequests() }
        imClient.register(friendRequestSyncHandler)
    }

    /// Always a full refresh (`version: 0`) — Android's own client never
    /// does incremental friend sync either. Call once after a successful
    /// connect (wire this to `ConnectAckHandler.onSyncState`, a later
    /// task), same as Android's `ConnectAckMessageHandler`.
    public func syncFriendList() {
        print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] syncFriendList() called")
        var request = Im_Version()
        request.version = 0
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .fp, body: body)
    }

    /// Requests profiles for `uids` not already cached locally, unless
    /// `forceRefresh` is true (then every requested uid goes out over the
    /// wire regardless of cache state). Sends nothing if there's nothing to
    /// ask for. Mirrors Android's `getUserInfo`/`getUserInfos` cache-check.
    public func fetchUserInfo(uids: [String], forceRefresh: Bool) {
        let targetUids: [String]
        if forceRefresh {
            targetUids = uids
        } else {
            // Not just "row doesn't exist" — FriendSyncHandler's
            // replaceFriendList(uids:) creates an empty placeholder row (every
            // profile field nil) for any newly-flagged friend before their
            // profile is ever resolved. A presence-only check would treat that
            // placeholder as "already cached" and never fetch the real
            // profile. displayName == nil is the same "not yet resolved"
            // signal UserStore.friends() already sorts by elsewhere.
            // Trade-off: a genuinely-resolved user whose server profile never
            // sets display_name (only name/mobile, say) would keep matching
            // this check and get redundantly re-requested on every call —
            // accepted for Phase 1 (extra network traffic, no data
            // corruption) rather than adding a dedicated placeholder marker.
            targetUids = uids.filter { uid in
                guard let user = try? storage.users.user(uid: uid) else { return true }
                return user.displayName == nil
            }
        }
        guard !targetUids.isEmpty else { return }

        var request = Im_PullUserRequest()
        request.request = targetUids.map { uid in
            var userRequest = Im_UserRequest()
            userRequest.uid = uid
            return userRequest
        }
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .upui, body: body)
    }

    /// Searches for users by uid/mobile (or display name, depending on
    /// server-side `fuzzy` matching). Matched profiles are written into
    /// `UserStore` by `UserSearchHandler` before this completion fires;
    /// callers needing the actual profile fields read them from
    /// `IMStorage.UserStore` directly.
    public func searchUser(keyword: String, completion: @escaping (Result<[String], Error>) -> Void) {
        var request = Im_SearchUserRequest()
        request.keyword = keyword
        request.fuzzy = 1
        request.page = 0
        guard let body = try? request.serializedData() else {
            completion(.failure(ContactSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .us, body: body)
        userSearchTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    public func sendFriendRequest(to uid: String, reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_AddFriendRequest()
        request.targetUid = uid
        request.reason = reason
        guard let body = try? request.serializedData() else {
            completion(.failure(ContactSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .far, body: body)
        friendRequestActionTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    /// On success, immediately marks the local row accepted (rather than
    /// waiting for the next incremental pull) and kicks off a
    /// `syncFriendRequests()` re-pull for eventual consistency with the
    /// server's own bookkeeping (e.g. `updateDt`).
    public func acceptFriendRequest(from uid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = Im_HandleFriendRequest()
        request.targetUid = uid
        request.status = 1 // server ignores this value but the field is still filled per its declared semantics
        guard let body = try? request.serializedData() else {
            completion(.failure(ContactSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .fhr, body: body)
        friendRequestActionTracker.track(wireMessageId: wireMessageId) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                try? self.storage.friendRequests.markAccepted(fromUid: uid)
                self.syncFriendRequests()
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Incremental pull, unlike `syncFriendList()` — sends the locally
    /// stored `friendRequestHead` (not a fixed `0`) so the server only
    /// returns requests newer than what's already synced.
    public func syncFriendRequests() {
        guard let syncState = try? storage.syncState.get() else { return }
        var request = Im_Version()
        request.version = syncState.friendRequestHead
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .frp, body: body)
    }

    /// Fire-and-forget: the server marks requests read and pushes the new
    /// head back via the same `.frn` notify `FriendRequestSyncHandler`
    /// already handles, so no completion/tracker is needed here.
    public func markFriendRequestsAsRead() {
        var request = Im_Version()
        request.version = Int64(Date().timeIntervalSince1970 * 1000)
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .frus, body: body)
    }

    /// Changes the logged-in user's own nickname (`InfoEntry.type=0`,
    /// matching Android `ModifyMyInfoType.Modify_DisplayName`). Only writes
    /// `UserStore` once the server acks success — no optimistic update, so
    /// a failed write never leaves the local cache out of sync with the
    /// server.
    public func updateDisplayName(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        sendModifyMyInfo(type: 0, value: name) { [weak self] result in
            if case .success = result { self?.applyLocalProfileUpdate(displayName: name) }
            completion(result)
        }
    }

    /// Changes the logged-in user's own avatar URL (`InfoEntry.type=1`,
    /// matching Android `ModifyMyInfoType.Modify_Portrait`). The caller is
    /// responsible for uploading the image first (`IMMedia.MediaUploadService`)
    /// and passing the resulting remote URL here — this method only does
    /// the profile-field write, mirroring `updateDisplayName`'s shape.
    public func updatePortrait(_ url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        sendModifyMyInfo(type: 1, value: url) { [weak self] result in
            if case .success = result { self?.applyLocalProfileUpdate(portrait: url) }
            completion(result)
        }
    }

    private func sendModifyMyInfo(type: Int32, value: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var entry = Im_InfoEntry()
        entry.type = type
        entry.value = value
        var request = Im_ModifyMyInfoRequest()
        request.entry = [entry]
        guard let body = try? request.serializedData() else {
            completion(.failure(ContactSyncServiceError.requestEncodingFailed))
            return
        }
        let wireMessageId = imClient.sendFrame(signal: .publish, subSignal: .mmi, body: body)
        profileUpdateTracker.track(wireMessageId: wireMessageId) { result in
            completion(result.mapError { $0 as Error })
        }
    }

    /// Merges a successful `.mmi` ack into `UserStore`, keeping every other
    /// profile field at its current local value — a naive `upsertProfile`
    /// call with only the changed field set would clobber the other
    /// columns back to `nil`/default (see `UserStore.upsertProfile`'s doc
    /// comment: it overwrites every profile column it's given).
    private func applyLocalProfileUpdate(displayName: String? = nil, portrait: String? = nil) {
        let uid = imClient.userId
        let existing = try? storage.users.user(uid: uid)
        try? storage.users.upsertProfile(
            uid: uid,
            name: existing?.name,
            displayName: displayName ?? existing?.displayName,
            portrait: portrait ?? existing?.portrait,
            mobile: existing?.mobile,
            gender: existing?.gender ?? 0,
            updateDt: existing?.updateDt ?? 0
        )
    }
}
