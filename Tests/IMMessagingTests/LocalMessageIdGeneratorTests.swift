import XCTest
@testable import IMMessaging

final class LocalMessageIdGeneratorTests: XCTestCase {
    func test_next_returnsDistinctValuesAcrossManyRapidCalls() {
        let generator = LocalMessageIdGenerator()

        let ids = (0..<500).map { _ in generator.next() }

        XCTAssertEqual(Set(ids).count, 500)
    }

    func test_next_valuesAreNonNegativeAndIncreasingOverall() {
        let generator = LocalMessageIdGenerator()

        let first = generator.next()
        let second = generator.next()

        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }
}
