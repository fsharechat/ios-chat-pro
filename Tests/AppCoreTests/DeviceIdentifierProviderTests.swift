import XCTest
@testable import AppCore

final class DeviceIdentifierProviderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var provider: DeviceIdentifierProvider!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DeviceIdentifierProviderTests-\(UUID().uuidString)")
        provider = DeviceIdentifierProvider(defaults: defaults)
    }

    func test_currentIdentifier_generatesAValidUUIDStringOnFirstCall() {
        let identifier = provider.currentIdentifier()
        XCTAssertNotNil(UUID(uuidString: identifier))
    }

    func test_currentIdentifier_returnsTheSameValueOnSubsequentCalls() {
        let first = provider.currentIdentifier()
        let second = provider.currentIdentifier()
        XCTAssertEqual(first, second)
    }

    func test_currentIdentifier_persistsAcrossProviderInstances() {
        let first = provider.currentIdentifier()
        let secondProvider = DeviceIdentifierProvider(defaults: defaults)
        XCTAssertEqual(secondProvider.currentIdentifier(), first)
    }
}
