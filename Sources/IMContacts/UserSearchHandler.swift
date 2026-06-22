import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `PUB_ACK`/`.us` search response and resolves the matching
/// `UserSearchTracker` entry. Same "1 byte error code, then protobuf" wire
/// format as every other `PUB_ACK` handler in this codebase. Every matched
/// `Im_User` is upserted into `UserStore` via `upsertProfile(...)` (never
/// touching `isFriend` — search results say nothing about friendship
/// status) before the tracker is resolved with the matched `[uid]` list.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class UserSearchHandler: MessageHandler {
    private let storage: IMStorage
    private let tracker: UserSearchTracker

    public init(storage: IMStorage, tracker: UserSearchTracker) {
        self.storage = storage
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .us
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        if errorCode == 0 {
            guard let result = try? Im_SearchUserResult(serializedBytes: frame.body.dropFirst()) else {
                tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.malformedResponse))
                return
            }
            for user in result.entry {
                // Accepted Phase-2 gap: a failed upsert for one user is
                // silently dropped (no logging facility yet), same as
                // UserInfoSyncHandler/FriendSyncHandler.
                try? storage.users.upsertProfile(
                    uid: user.uid,
                    name: user.hasName ? user.name : nil,
                    displayName: user.hasDisplayName ? user.displayName : nil,
                    portrait: user.hasPortrait ? user.portrait : nil,
                    mobile: user.hasMobile ? user.mobile : nil,
                    gender: Int(user.gender),
                    updateDt: user.updateDt
                )
            }
            tracker.resolve(wireMessageId: frame.header.messageId, result: .success(result.entry.map(\.uid)))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.serverError(errorCode: Int32(errorCode))))
        }
    }
}
