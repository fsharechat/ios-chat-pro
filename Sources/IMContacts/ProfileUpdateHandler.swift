import IMClient
import IMTransport

/// Parses the bare "1 byte error code, no payload" `PUB_ACK`/`.mmi`
/// response and resolves the matching `ProfileUpdateTracker` entry.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ProfileUpdateHandler: MessageHandler {
    private let tracker: ProfileUpdateTracker

    public init(tracker: ProfileUpdateTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .mmi
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
