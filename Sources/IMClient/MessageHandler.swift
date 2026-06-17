import IMTransport

public protocol MessageHandler: AnyObject {
    func canHandle(signal: Signal, subSignal: SubSignal) -> Bool
    func handle(frame: Frame)
}

/// Mirrors `AbstractProtoService.receiveMessage`'s dispatch loop: a linear
/// scan over registered handlers, first match wins.
public final class MessageHandlerRegistry {
    private var handlers: [MessageHandler] = []

    public init() {}

    public func register(_ handler: MessageHandler) {
        handlers.append(handler)
    }

    public func dispatch(_ frame: Frame) {
        for handler in handlers {
            if handler.canHandle(signal: frame.header.signal, subSignal: frame.header.subSignal) {
                handler.handle(frame: frame)
                return
            }
        }
    }
}
