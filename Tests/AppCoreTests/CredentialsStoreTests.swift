import XCTest
@testable import AppCore

final class CredentialsStoreTests: XCTestCase {
    private var store: CredentialsStore!

    override func setUp() {
        super.setUp()
        // A per-test-run-unique service name keeps tests from colliding with
        // each other or with a real app's stored credentials on this machine.
        store = CredentialsStore(service: "AppCoreTests.\(UUID().uuidString)")
        store.clear()
    }

    override func tearDown() {
        store.clear()
        super.tearDown()
    }

    func test_load_returnsNilWhenNothingStored() {
        XCTAssertNil(store.load())
    }

    func test_saveThenLoad_roundTrips() {
        store.save(Credentials(userId: "u1", token: "t1"))

        let loaded = store.load()

        XCTAssertEqual(loaded?.userId, "u1")
        XCTAssertEqual(loaded?.token, "t1")
    }

    func test_saveTwice_overwritesRatherThanFailing() {
        store.save(Credentials(userId: "u1", token: "t1"))
        store.save(Credentials(userId: "u2", token: "t2"))

        XCTAssertEqual(store.load()?.userId, "u2")
    }

    func test_clear_removesStoredCredentials() {
        store.save(Credentials(userId: "u1", token: "t1"))
        store.clear()

        XCTAssertNil(store.load())
    }

    /// Keychain items survive app deletion on iOS, so a leftover token from
    /// a previous install must be wiped the first time `UserDefaults`
    /// (which *is* cleared on uninstall) shows no "already launched" flag.
    func test_clearIfFreshInstall_wipesStaleCredentialsOnFirstLaunch() {
        let defaults = makeIsolatedDefaults()
        store.save(Credentials(userId: "stale", token: "leftover-from-previous-install"))

        store.clearIfFreshInstall(defaults: defaults)

        XCTAssertNil(store.load())
    }

    func test_clearIfFreshInstall_leavesCredentialsAloneOnSubsequentLaunches() {
        let defaults = makeIsolatedDefaults()
        store.clearIfFreshInstall(defaults: defaults) // simulates the first-ever launch
        store.save(Credentials(userId: "u1", token: "t1")) // user logs in normally afterward

        store.clearIfFreshInstall(defaults: defaults) // simulates a later, ordinary launch

        XCTAssertEqual(store.load()?.userId, "u1")
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "AppCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
