import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `PUB_ACK`/`FP` friend-list-pull response and replaces
/// `IMStorage`'s friend-flagged user set. The wire body is "1 byte error
/// code, then `Im_GetFriendsResult`" — universal to every `PUB_ACK`
/// response. Only `Im_Friend.uid` is used, matching Android's own client,
/// which reads but never uses `state`/`alias`/`updateDt`.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class FriendSyncHandler: MessageHandler {
    private let storage: IMStorage

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .fp
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_GetFriendsResult(serializedBytes: frame.body.dropFirst()) else { return }
        try? storage.users.replaceFriendList(uids: result.entry.map(\.uid))
    }
}
