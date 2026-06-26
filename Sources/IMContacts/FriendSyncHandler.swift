import Foundation
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
        print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] FriendSyncHandler.handle bodyBytes=\(frame.body.count)")
        guard let errorCode = frame.body.first, errorCode == 0 else {
            print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] FriendSyncHandler bailed: errorCode=\(frame.body.first.map(String.init) ?? "nil")")
            return
        }
        guard let result = try? Im_GetFriendsResult(serializedBytes: frame.body.dropFirst()) else {
            print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] FriendSyncHandler bailed: Im_GetFriendsResult parse failed")
            return
        }
        print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] FriendSyncHandler parsed entries=\(result.entry.count) uids=\(result.entry.map(\.uid))")
        // If the write fails, the friend list is silently left stale with no
        // diagnostic trail — accepted for Phase 1 since there's no logging
        // facility yet, the same accepted gap documented in
        // `ReceiveMessageHandler`'s persist method and `CredentialsStore`'s
        // save/clear methods.
        do {
            try storage.users.replaceFriendList(uids: result.entry.map(\.uid))
            print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] replaceFriendList succeeded")
        } catch {
            print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] replaceFriendList THREW: \(error)")
        }
    }
}
