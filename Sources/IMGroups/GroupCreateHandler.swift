import IMClient
import IMTransport
import Foundation

/// Parses the `.gc` (create group) response and resolves the matching
/// `GroupCreateTracker` entry. **Wire format:** like every `PUB_ACK`, 1 byte
/// error code, then — only here, unlike every other group action — the
/// server-assigned group id as raw UTF-8 bytes (confirmed by reading
/// `CreateGroupHandler.java`: `byte[] data = groupInfo.getTarget().getBytes();
/// ackPayload.ensureWritable(data.length).writeBytes(data);`). Not protobuf,
/// not the fixed-width binary `MessageSendAckHandler` uses — a third
/// distinct ack shape, each handled by its own dedicated handler.
public final class GroupCreateHandler: MessageHandler {
    private let tracker: GroupCreateTracker

    public init(tracker: GroupCreateTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .gc
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        if errorCode == 0 {
            let groupIdBytes = frame.body.dropFirst()
            guard let groupId = String(data: groupIdBytes, encoding: .utf8), !groupId.isEmpty else {
                tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.malformedResponse))
                return
            }
            tracker.resolve(wireMessageId: frame.header.messageId, result: .success(groupId))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.serverError(errorCode: Int32(errorCode))))
        }
    }
}
