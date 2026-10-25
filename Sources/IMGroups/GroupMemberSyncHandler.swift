import IMClient
import IMTransport
import IMProto
import IMStorage

/// Parses the `.gpgm` (pull group member) response and upserts each member,
/// tagged with the `groupId` resolved from `GroupMemberSyncTracker` (see
/// that type's doc comment for why a tracker is needed here when no other
/// `PUB_ACK` handler needs one).
public final class GroupMemberSyncHandler: MessageHandler {
    private let storage: IMStorage
    private let tracker: GroupMemberSyncTracker

    public init(storage: IMStorage, tracker: GroupMemberSyncTracker) {
        self.storage = storage
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .gpgm
    }

    public func handle(frame: Frame) {
        // Resolved unconditionally (before checking the error code) so a
        // server-error response still consumes the tracked entry rather
        // than leaking it until the 5-second timeout.
        guard let groupId = tracker.resolve(wireMessageId: frame.header.messageId) else { return }
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_PullGroupMemberResult(serializedBytes: frame.body.dropFirst()) else { return }
        // 服务端（MemoryMessagesStore.getGroupMembers）返回的是当前有效成员的
        // 全量列表，被踢/退群的人直接不在里面、不会以 Removed 类型下发——逐条
        // upsert 会让他们永远留在本地，必须整体替换。成员没变时服务端回
        // NOT_MODIFIED 错误码，已在上面被挡掉，不会误清空。
        let members = result.member.map { member in
            StoredGroupMember(
                groupId: groupId,
                memberId: member.memberID,
                // Falls back to `.normal` for an unrecognized wire value (today's 5
                // member types are exhaustively verified against
                // cn.wildfirechat.model.GroupMember.GroupMemberType, so this is currently
                // unreachable). Low risk today since nothing reads `memberType` to
                // authorize an action yet — but revisit once a later task starts making
                // permission decisions off `memberType == .owner`.
                memberType: GroupMemberType(rawValue: Int(member.type)) ?? .normal,
                updateDt: member.updateDt
            )
        }
        try? storage.groups.replaceMembers(groupId: groupId, with: members)
    }
}
