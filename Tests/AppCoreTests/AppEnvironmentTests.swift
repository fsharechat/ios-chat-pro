import XCTest
import IMClient
import IMStorage
import IMProto
import IMTransport
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

    func test_connectIfPossible_withCredentials_alsoTriggersAFriendListSync() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))

        XCTAssertTrue(environment.connectIfPossible())

        // The CONNECT frame's send is the only thing the fake transport has
        // recorded so far — connectIfPossible() itself doesn't send FP, only
        // the post-CONNECT_ACK callback does (friend sync triggers from the
        // same hook as message catch-up). Simulate the server's CONNECT_ACK
        // to fire that callback.
        var payload = Im_ConnectAckPayload()
        payload.msgHead = 0
        payload.friendHead = 0
        payload.friendRqHead = 0
        payload.settingHead = 0
        payload.serverTime = 0
        let body = try payload.serializedData()
        let frameBytes = FrameEncoder.encode(signal: .connectAck, subSignal: .none, messageId: 1, body: body)
        fakeTransport.simulateReceivedData(frameBytes)

        let sentSignals = fakeTransport.sentFrames.compactMap { try? FrameDecoder().feed($0).first?.header.subSignal }
        XCTAssertTrue(sentSignals.contains(.fp))
    }

    func test_connectIfPossible_withCredentials_alsoTriggersAFriendRequestSync() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))

        XCTAssertTrue(environment.connectIfPossible())

        var payload = Im_ConnectAckPayload()
        payload.msgHead = 0
        payload.friendHead = 0
        payload.friendRqHead = 0
        payload.settingHead = 0
        payload.serverTime = 0
        let body = try payload.serializedData()
        let frameBytes = FrameEncoder.encode(signal: .connectAck, subSignal: .none, messageId: 1, body: body)
        fakeTransport.simulateReceivedData(frameBytes)

        let sentSignals = fakeTransport.sentFrames.compactMap { try? FrameDecoder().feed($0).first?.header.subSignal }
        XCTAssertTrue(sentSignals.contains(.frp))
    }

    func test_defaultDatabasePath_endsWithExpectedFileNameAndParentDirectoryExists() {
        let path = AppEnvironment.defaultDatabasePath()

        XCTAssertTrue(path.hasSuffix("im.sqlite"))
        let parent = (path as NSString).deletingLastPathComponent
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent))
    }

    func test_connectIfPossible_withCredentials_alsoConstructsMediaUploadService() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))

        XCTAssertTrue(environment.connectIfPossible())

        XCTAssertNotNil(environment.mediaUploadService)
    }

    func test_logOut_clearsMediaUploadService() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))
        environment.connectIfPossible()

        environment.logOut()

        XCTAssertNil(environment.mediaUploadService)
    }

    func test_logOut_clearsMessagesConversationsAndResetsSyncState() throws {
        credentialsStore.save(Credentials(userId: "u1", token: "dG9rZW4="))
        environment.connectIfPossible()
        try storage.messages.insert(StoredMessage(
            localMessageId: 1, conversationType: .single, target: "u2", from: "u1",
            content: .text("hi"), timestamp: 1_000, status: .sent, direction: .send
        ))
        try storage.conversations.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)
        try storage.syncState.set(StoredSyncState(msgHead: 42, friendHead: 7, friendRequestHead: 3, settingHead: 9))

        environment.logOut()

        XCTAssertNil(try storage.messages.message(localMessageId: 1))
        XCTAssertTrue(try storage.conversations.conversations().isEmpty)
        XCTAssertEqual(try storage.syncState.get().msgHead, 0)
    }
}
