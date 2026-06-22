import IMClient
import IMTransport

/// Parses the bare "1 byte error code, no payload" response shared by
/// `.gam` (add member)/`.gkm` (kick member)/`.gmi` (modify group info)/
/// `.gq` (quit group)/`.gd` (dismiss group) and resolves the matching
/// `GroupActionTracker` entry. One handler covers all five since
/// `IMClient.sendFrame`'s `nextMessageId` is a single incrementing counter
/// shared across every outgoing frame — exact mirror of `IMContacts`'s
/// `FriendRequestActionHandler`.
public final class GroupActionHandler: MessageHandler {
    private let tracker: GroupActionTracker

    public init(tracker: GroupActionTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && (subSignal == .gam || subSignal == .gkm || subSignal == .gmi || subSignal == .gq || subSignal == .gd)
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        if errorCode == 0 {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .success(()))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.serverError(errorCode: Int32(errorCode))))
        }
    }
}
