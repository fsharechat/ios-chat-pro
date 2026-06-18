import IMClient
import IMTransport
import IMProto

/// Parses the `PUB_ACK`/`GMURL` response to a presigned-upload-URL request
/// and resolves the matching `MinioUploadURLTracker` entry. Same "1 byte
/// error code, then protobuf" wire format as every other `PUB_ACK` handler
/// in this codebase.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class MinioUploadURLHandler: MessageHandler {
    private let tracker: MinioUploadURLTracker

    public init(tracker: MinioUploadURLTracker) {
        self.tracker = tracker
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .gmurl
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        if errorCode == 0 {
            guard let result = try? Im_GetMinioUploadUrlResult(serializedBytes: frame.body.dropFirst()) else {
                tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.malformedResponse))
                return
            }
            tracker.resolve(wireMessageId: frame.header.messageId, result: .success(result))
        } else {
            tracker.resolve(wireMessageId: frame.header.messageId, result: .failure(.serverError(errorCode: Int32(errorCode))))
        }
    }
}
