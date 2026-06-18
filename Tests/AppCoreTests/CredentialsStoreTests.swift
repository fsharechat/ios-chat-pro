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
}
