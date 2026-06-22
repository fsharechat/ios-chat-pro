import IMClient
import IMTransport

/// Parses the bare "1 byte error code, no payload" response shared by both
/// `.far` (send friend request) and `.fhr` (accept friend request) and
/// resolves the matching `FriendRequestActionTracker` entry. One handler
/// covers both sub-signals since `IMClient.sendFrame`'s `nextMessageId` is
/// a single incrementing counter shared across every outgoing frame, so a
/// `messageId` lookup alone is enough to find the right pending entry
/// regardless of which of the two requests it came from.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class FriendRequestActionHandler: MessageHandler {
    private let tracker: FriendRequestActionTracker

    public init(tracker: FriendRequestActionTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && (subSignal == .far || subSignal == .fhr)
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
