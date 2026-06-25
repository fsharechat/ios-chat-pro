import XCTest
@testable import AppCore

final class ThemePreferenceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: ThemePreferenceStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ThemePreferenceStoreTests-\(UUID().uuidString)")
        store = ThemePreferenceStore(defaults: defaults)
    }

    func test_mode_defaultsToSystemWhenNeverSet() {
        XCTAssertEqual(store.mode, .system)
    }

    func test_mode_persistsAcrossStoreInstances() {
        store.mode = .dark

        let secondStore = ThemePreferenceStore(defaults: defaults)
        XCTAssertEqual(secondStore.mode, .dark)
    }

    func test_mode_roundTripsEveryCase() {
        for mode in ThemeMode.allCases {
            store.mode = mode
            XCTAssertEqual(store.mode, mode)
        }
    }
}
