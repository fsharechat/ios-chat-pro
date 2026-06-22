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
        for member in result.member {
            try? storage.groups.upsertMember(StoredGroupMember(
                groupId: groupId,
                memberId: member.memberID,
                memberType: GroupMemberType(rawValue: Int(member.type)) ?? .normal,
                updateDt: member.updateDt
            ))
        }
    }
}
