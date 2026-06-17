import XCTest
@testable import IMClient

final class RoundRobinHostSelectorTests: XCTestCase {
    func test_cyclesThroughHostsInOrderAndWrapsAround() throws {
        let selector = try RoundRobinHostSelector(hostsString: "a:b:c")

        XCTAssertEqual(selector.nextHost(), "a")
        XCTAssertEqual(selector.nextHost(), "b")
        XCTAssertEqual(selector.nextHost(), "c")
        XCTAssertEqual(selector.nextHost(), "a")
        XCTAssertEqual(selector.nextHost(), "b")
    }

    func test_singleHostAlwaysReturnsTheSameHost() throws {
        let selector = try RoundRobinHostSelector(hostsString: "only-host")

        XCTAssertEqual(selector.nextHost(), "only-host")
        XCTAssertEqual(selector.nextHost(), "only-host")
    }

    func test_emptyStringThrows() {
        XCTAssertThrowsError(try RoundRobinHostSelector(hostsString: "")) { error in
            XCTAssertEqual(error as? RoundRobinHostSelector.Error, .emptyHostsString)
        }
    }

    func test_whitespaceOnlyStringThrows() {
        XCTAssertThrowsError(try RoundRobinHostSelector(hostsString: "   ")) { error in
            XCTAssertEqual(error as? RoundRobinHostSelector.Error, .emptyHostsString)
        }
    }
}
