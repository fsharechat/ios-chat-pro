import XCTest
@testable import IMClient

final class FakeTransportConnectionTests: XCTestCase {
    func test_send_recordsDataButDoesNotAutoComplete() {
        let transport = FakeTransportConnection()
        var completedResults: [Result<Void, Error>] = []

        transport.send(Data([1, 2, 3])) { completedResults.append($0) }

        XCTAssertEqual(transport.sentFrames, [Data([1, 2, 3])])
        XCTAssertTrue(completedResults.isEmpty)
        XCTAssertEqual(transport.pendingSendCount, 1)
    }

    func test_completeOldestSend_completesInFIFOOrder() {
        let transport = FakeTransportConnection()
        var order: [Int] = []

        transport.send(Data([1])) { _ in order.append(1) }
        transport.send(Data([2])) { _ in order.append(2) }

        XCTAssertTrue(transport.completeOldestSend())
        XCTAssertEqual(order, [1])
        XCTAssertTrue(transport.completeOldestSend())
        XCTAssertEqual(order, [1, 2])
        XCTAssertFalse(transport.completeOldestSend()) // nothing left
    }

    func test_simulate_invokesRegisteredHandler() {
        let transport = FakeTransportConnection()
        var receivedEvent: IMTransportEvent?
        transport.onEvent = { receivedEvent = $0 }

        transport.simulate(.connected)

        switch receivedEvent {
        case .connected: break
        default: XCTFail("expected .connected")
        }
    }
}
