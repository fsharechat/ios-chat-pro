import IMClient
import IMProto
import IMStorage

/// The single entry point Plan G's UI code constructs (or, more likely,
/// `AppEnvironment` constructs once and Plan G's view models read
/// `IMStorage.UserStore` directly — this service only owns *sending*
/// requests, not data access): registers `FriendSyncHandler`/
/// `UserInfoSyncHandler` with the given `IMClient`, and exposes
/// `syncFriendList()`/`fetchUserInfo(uids:forceRefresh:)`.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ContactSyncService {
    private let imClient: IMClient
    private let storage: IMStorage

    public init(imClient: IMClient, storage: IMStorage) {
        self.imClient = imClient
        self.storage = storage

        imClient.register(FriendSyncHandler(storage: storage))
        imClient.register(UserInfoSyncHandler(storage: storage))
    }

    /// Always a full refresh (`version: 0`) — Android's own client never
    /// does incremental friend sync either. Call once after a successful
    /// connect (wire this to `ConnectAckHandler.onSyncState`, a later
    /// task), same as Android's `ConnectAckMessageHandler`.
    public func syncFriendList() {
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
            targetUids = uids.filter { (try? storage.users.user(uid: $0)) == nil }
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
}
