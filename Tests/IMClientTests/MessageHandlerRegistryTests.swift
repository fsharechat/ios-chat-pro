import XCTest
@testable import IMClient
import IMTransport

private final class RecordingHandler: MessageHandler {
    let matchSignal: Signal
    private(set) var handledFrames: [Frame] = []

    init(matchSignal: Signal) {
        self.matchSignal = matchSignal
    }

    func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == matchSignal
    }

    func handle(frame: Frame) {
        handledFrames.append(frame)
    }
}

final class MessageHandlerRegistryTests: XCTestCase {
    private func makeFrame(signal: Signal) -> Frame {
        Frame(header: Header(signal: signal, subSignal: .none, bodyLength: 0, messageId: 1), body: Data())
    }

    func test_dispatch_routesToFirstMatchingHandlerOnly() {
        let registry = MessageHandlerRegistry()
        let pingHandler = RecordingHandler(matchSignal: .ping)
        let connectAckHandler = RecordingHandler(matchSignal: .connectAck)
        registry.register(pingHandler)
        registry.register(connectAckHandler)

        registry.dispatch(makeFrame(signal: .connectAck))

        XCTAssertEqual(pingHandler.handledFrames.count, 0)
        XCTAssertEqual(connectAckHandler.handledFrames.count, 1)
    }

    func test_dispatch_firstRegisteredMatchWins_whenMultipleHandlersWouldMatch() {
        let registry = MessageHandlerRegistry()
        let first = RecordingHandler(matchSignal: .ping)
        let second = RecordingHandler(matchSignal: .ping)
        registry.register(first)
        registry.register(second)

        registry.dispatch(makeFrame(signal: .ping))

        XCTAssertEqual(first.handledFrames.count, 1)
        XCTAssertEqual(second.handledFrames.count, 0)
    }

    func test_dispatch_noMatchingHandler_doesNothingAndDoesNotCrash() {
        let registry = MessageHandlerRegistry()
        registry.register(RecordingHandler(matchSignal: .ping))

        registry.dispatch(makeFrame(signal: .disconnect)) // no crash, no-op
    }
}
