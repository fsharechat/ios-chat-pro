import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `.gpgi` (pull group info) response and upserts each group
/// into `GroupStore`. Same "1 byte error code, then protobuf" wire format
/// as every other `PUB_ACK` handler. Each `Im_GroupInfo` self-identifies via
/// its own `target_id` field (unlike `.gpgm`'s member result, which doesn't
/// — see `GroupMemberSyncHandler`'s doc comment), so no request/response
/// correlation tracker is needed here — same shape as `IMContacts`'s
/// `UserInfoSyncHandler`.
public final class GroupInfoSyncHandler: MessageHandler {
    private let storage: IMStorage

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .gpgi
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_PullGroupInfoResult(serializedBytes: frame.body.dropFirst()) else { return }
        for info in result.info {
            // Accepted gap: a failed upsert for one group is silently
            // dropped (no logging facility yet), same as every other
            // best-effort handler in this codebase.
            try? storage.groups.upsertGroup(StoredGroup(
                groupId: info.targetID,
                name: info.name,
                portrait: info.hasPortrait ? info.portrait : nil,
                owner: info.hasOwner ? info.owner : nil,
                // Falls back to `.normal` for an unrecognized wire value (today's only 3
                // values — Normal/Free/Restricted — are exhaustively verified against
                // ProtoConstants, so this is currently unreachable). If a new group type
                // is ever added server-side, reconsider this default: `.normal` is the
                // most *permissive* fallback for the permission matrix in
                // GroupInfoViewModel, not the safest fail-closed choice.
                groupType: GroupType(rawValue: Int(info.type)) ?? .normal,
                memberCount: Int(info.memberCount),
                updateDt: info.updateDt,
                memberUpdateDt: info.memberUpdateDt
            ))
        }
    }
}
