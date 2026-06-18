import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `PUB_ACK`/`UPUI` bulk-user-info-pull response and upserts
/// each user's profile fields into `IMStorage`. Same "1 byte error code,
/// then protobuf" wire format as `FriendSyncHandler`. Uses
/// `UserStore.upsertProfile(...)`, never the raw whole-row `upsert(_:)`,
/// so an existing `isFriend` flag is never clobbered — `isFriend` isn't
/// part of the wire `User` message at all (it comes from a separate `FP`
/// pull), so a `UPUI` response has no opinion on it either way. Every
/// other field (name/displayName/portrait/mobile/gender/updateDt) is
/// intentionally overwritten with whatever the response says, including
/// clearing a field the server no longer reports: `UPUI` always returns
/// the full current profile for the queried uid, never a partial patch,
/// so "the server omitted this field" means "this field is genuinely
/// unset now," not "leave the old value alone."
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class UserInfoSyncHandler: MessageHandler {
    private let storage: IMStorage

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .upui
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_PullUserResult(serializedBytes: frame.body.dropFirst()) else { return }
        for userResult in result.result {
            let user = userResult.user
            // Accepted Phase-1 gap: a failed upsert for one user is
            // silently dropped (no logging facility yet), same as
            // FriendSyncHandler/ReceiveMessageHandler/CredentialsStore.
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
    }
}
