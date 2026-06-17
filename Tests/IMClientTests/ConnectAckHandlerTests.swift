import XCTest
@testable import IMClient
import IMTransport
import IMProto

final class ConnectAckHandlerTests: XCTestCase {
    func test_canHandle_onlyMatchesConnectAckSignal() {
        let handler = ConnectAckHandler()
        XCTAssertTrue(handler.canHandle(signal: .connectAck, subSignal: .none))
        XCTAssertFalse(handler.canHandle(signal: .ping, subSignal: .none))
    }

    func test_handle_parsesPayloadAndInvokesCallback() {
        let handler = ConnectAckHandler()
        var captured: ConnectAckSyncState?
        handler.onSyncState = { captured = $0 }

        var payload = Im_ConnectAckPayload()
        payload.msgHead = 100
        payload.friendHead = 2
        payload.friendRqHead = 1
        payload.settingHead = 3
        payload.serverTime = 1_750_000_000
        let body = try! payload.serializedData()
        let frame = Frame(header: Header(signal: .connectAck, subSignal: .none, bodyLength: UInt32(body.count), messageId: 1), body: body)

        handler.handle(frame: frame)

        XCTAssertEqual(captured, ConnectAckSyncState(
            messageHead: 100, friendHead: 2, friendRequestHead: 1, settingHead: 3, serverTime: 1_750_000_000
        ))
    }

    func test_handle_malformedBody_doesNotCrashAndDoesNotInvokeCallback() {
        let handler = ConnectAckHandler()
        var callbackInvoked = false
        handler.onSyncState = { _ in callbackInvoked = true }
        let frame = Frame(header: Header(signal: .connectAck, subSignal: .none, bodyLength: 3, messageId: 1), body: Data([0xFF, 0xFF, 0xFF]))

        handler.handle(frame: frame)

        XCTAssertFalse(callbackInvoked)
    }
}
