import IMClient
import IMTransport
import IMProto

/// Parses a `PUBLISH`/`MN` "you have new messages" notification and invokes
/// `onNotify` with `(head - 1, type)` — the exact arguments
/// `ProtoService.pullMessage` is called with in the Android reference, so
/// whoever wires `onNotify` (see `MessagingService`, Task 10) can pass them
/// straight through to a pull request.
public final class NotifyMessageHandler: MessageHandler {
    public var onNotify: ((Int64, Int32) -> Void)?

    public init() {}

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .publish && subSignal == .mn
    }

    public func handle(frame: Frame) {
        guard let notify = try? Im_NotifyMessage(serializedBytes: frame.body) else { return }
        onNotify?(notify.head - 1, notify.type)
    }
}
