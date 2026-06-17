import XCTest
@testable import IMTransport

final class SignalTests: XCTestCase {
    func test_rawValuesMatchAndroidOrdinals() {
        XCTAssertEqual(Signal.none.rawValue, 0)
        XCTAssertEqual(Signal.sub.rawValue, 1)
        XCTAssertEqual(Signal.auth.rawValue, 2)
        XCTAssertEqual(Signal.ping.rawValue, 3)
        XCTAssertEqual(Signal.push.rawValue, 4)
        XCTAssertEqual(Signal.contact.rawValue, 5)
        XCTAssertEqual(Signal.connect.rawValue, 6)
        XCTAssertEqual(Signal.connectAck.rawValue, 7)
        XCTAssertEqual(Signal.disconnect.rawValue, 8)
        XCTAssertEqual(Signal.publish.rawValue, 9)
        XCTAssertEqual(Signal.pubAck.rawValue, 10)
    }

    func test_outOfRangeRawValueIsNil() {
        XCTAssertNil(Signal(rawValue: 11))
    }
}
