import XCTest
import IMClient
import IMStorage
@testable import AppCore

final class AppEnvironmentTests: XCTestCase {
    private var storage: IMStorage!
    private var credentialsStore: CredentialsStore!
    private var fakeTransport: FakeTransportConnection!
    private var environment: AppEnvironment!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        credentialsStore = CredentialsStore(service: "AppEnvironmentTests.\(UUID().uuidString)")
        fakeTransport = FakeTransportConnection()
        environment = AppEnvironment(
            storage: storage,
            credentialsStore: credentialsStore,
            deviceIdentifierProvider: DeviceIdentifierProvider(defaults: UserDefaults(suiteName: "AppEnvironmentTests.\(UUID().uuidString)")!),
            transportFactory: { [unowned self] _, _ in self.fakeTransport }
        )
    }

    override func tearDown() {
        credentialsStore.clear()
        super.tearDown()
    }

    func test_connectIfPossible_noCredentials_returnsFalseAndConstructsNoClient() {
        XCTAssertFalse(environment.connectIfPossible())
        XCTAssertNil(environment.imClient)
    }

    func test_connectIfPossible_withCredentials_constructsClientAndStartsConnecting() {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))

        XCTAssertTrue(environment.connectIfPossible())

        XCTAssertNotNil(environment.imClient)
        XCTAssertNotNil(environment.messagingService)
        XCTAssertEqual(fakeTransport.startCallCount, 1)
    }

    func test_connectIfPossible_calledAgainAfterAlreadyConnected_doesNotReconstructClient() {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))
        environment.connectIfPossible()
        let firstClient = environment.imClient

        XCTAssertTrue(environment.connectIfPossible())

        XCTAssertTrue(environment.imClient === firstClient)
        XCTAssertEqual(fakeTransport.startCallCount, 1) // not started a second time
    }

    func test_logOut_disconnectsClearsClientAndClearsCredentials() {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))
        environment.connectIfPossible()

        environment.logOut()

        XCTAssertNil(environment.imClient)
        XCTAssertNil(environment.messagingService)
        XCTAssertNil(credentialsStore.load())
    }

    func test_defaultDatabasePath_endsWithExpectedFileNameAndParentDirectoryExists() {
        let path = AppEnvironment.defaultDatabasePath()

        XCTAssertTrue(path.hasSuffix("im.sqlite"))
        let parent = (path as NSString).deletingLastPathComponent
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent))
    }
}
