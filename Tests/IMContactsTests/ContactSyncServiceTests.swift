import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class ContactSyncServiceTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var scheduler: ManualScheduler!
    private var service: ContactSyncService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        scheduler = ManualScheduler()
        service = ContactSyncService(imClient: imClient, storage: storage, scheduler: scheduler)

        imClient.connect()
        fakeTransport.simulate(.connected) // CONNECT message send completes synchronously via the fake's completion callback
    }

    private func decodeOnlySentFrame() throws -> Frame {
        try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
    }

    func test_syncFriendList_sendsAVersionZeroFPRequest() throws {
        service.syncFriendList()

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .fp)
        let request = try Im_Version(serializedBytes: frame.body)
        XCTAssertEqual(request.version, 0)
    }

    func test_fetchUserInfo_requestsOnlyUncachedUids() throws {
        try storage.users.upsertProfile(uid: "cached", name: nil, displayName: "Cached", portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        service.fetchUserInfo(uids: ["cached", "uncached"], forceRefresh: false)

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .upui)
        let request = try Im_PullUserRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.request.map(\.uid), ["uncached"])
    }

    func test_fetchUserInfo_treatsPlaceholderRowFromFriendListAsUncached() throws {
        try storage.users.replaceFriendList(uids: ["newFriend"]) // creates a placeholder row: uid set, every profile field nil

        service.fetchUserInfo(uids: ["newFriend"], forceRefresh: false)

        let frame = try decodeOnlySentFrame()
        let request = try Im_PullUserRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.request.map(\.uid), ["newFriend"])
    }

    func test_fetchUserInfo_withForceRefresh_requestsEveryRequestedUid() throws {
        try storage.users.upsertProfile(uid: "cached", name: nil, displayName: "Cached", portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        service.fetchUserInfo(uids: ["cached", "uncached"], forceRefresh: true)

        let frame = try decodeOnlySentFrame()
        let request = try Im_PullUserRequest(serializedBytes: frame.body)
        XCTAssertEqual(Set(request.request.map(\.uid)), ["cached", "uncached"])
    }

    func test_fetchUserInfo_withNoUncachedUidsAndNoForceRefresh_sendsNothing() throws {
        try storage.users.upsertProfile(uid: "cached", name: nil, displayName: "Cached", portrait: nil, mobile: nil, gender: 0, updateDt: 0)
        let countBefore = fakeTransport.sentFrames.count

        service.fetchUserInfo(uids: ["cached"], forceRefresh: false)

        XCTAssertEqual(fakeTransport.sentFrames.count, countBefore)
    }

    func test_receivingFPResponse_isHandledEndToEnd() throws {
        var result = Im_GetFriendsResult()
        var friend = Im_Friend()
        friend.uid = "u1"
        // `state`/`update_dt` are `required` fields in the proto2 schema
        // (see `Friend` in WFCMessage.proto) — serialization throws
        // `missingRequiredFields` unless every required field is set,
        // even though the handler only reads `uid` (confirmed in Task 3's
        // FriendSyncHandlerTests).
        friend.state = 0
        friend.updateDt = 0
        result.entry = [friend]
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .fp, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(try storage.users.friends().map(\.uid), ["u1"])
    }

    func test_receivingUPUIResponse_isHandledEndToEnd() throws {
        var result = Im_PullUserResult()
        var userResult = Im_UserResult()
        userResult.user.uid = "u1"
        userResult.user.displayName = "Alice"
        // `code` is a `required` field on `UserResult` (see WFCMessage.proto)
        // — confirmed in Task 4's UserInfoSyncHandlerTests.
        userResult.code = 0
        result.result = [userResult]
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .upui, messageId: 1, body: body)

        fakeTransport.simulateReceivedData(frameBytes)

        XCTAssertEqual(try storage.users.user(uid: "u1")?.displayName, "Alice")
    }

    func test_searchUser_sendsKeywordFuzzyOneAndPageZero() throws {
        service.searchUser(keyword: "alice") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .us)
        let request = try Im_SearchUserRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.keyword, "alice")
        XCTAssertEqual(request.fuzzy, 1)
        XCTAssertEqual(request.page, 0)
    }

    func test_sendFriendRequest_sendsTargetUidAndReason() throws {
        service.sendFriendRequest(to: "u1", reason: "hi") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .far)
        let request = try Im_AddFriendRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.targetUid, "u1")
        XCTAssertEqual(request.reason, "hi")
    }

    func test_acceptFriendRequest_sendsTargetUidAndStatusOne() throws {
        service.acceptFriendRequest(from: "u1") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .fhr)
        let request = try Im_HandleFriendRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.targetUid, "u1")
        XCTAssertEqual(request.status, 1)
    }

    func test_acceptFriendRequest_onSuccess_marksAcceptedLocallyAndRePullsFriendRequests() throws {
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))

        var capturedResult: Result<Void, Error>?
        service.acceptFriendRequest(from: "u1") { result in capturedResult = result }

        let acceptFrame = try decodeOnlySentFrame()
        let acceptFrameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .fhr, messageId: acceptFrame.header.messageId, body: Data([0x00]))
        fakeTransport.simulateReceivedData(acceptFrameBytes)

        switch capturedResult {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: capturedResult))")
        }
        let rows = try storage.dbQueueForTesting.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows.first?.status, StoredFriendRequest.Status.accepted)

        let followUpFrame = try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
        XCTAssertEqual(followUpFrame.header.subSignal, .frp)
    }

    func test_syncFriendRequests_sendsCurrentFriendRequestHeadAsVersion() throws {
        var state = try storage.syncState.get()
        state.friendRequestHead = 777
        try storage.syncState.set(state)

        service.syncFriendRequests()

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .frp)
        let request = try Im_Version(serializedBytes: frame.body)
        XCTAssertEqual(request.version, 777)
    }

    func test_markFriendRequestsAsRead_sendsFRUSWithNonZeroVersion() throws {
        service.markFriendRequestsAsRead()

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .frus)
        let request = try Im_Version(serializedBytes: frame.body)
        XCTAssertGreaterThan(request.version, 0)
    }

    func test_receivingFRNNotify_triggersAFollowUpFRPPull() throws {
        let frameBytes = FrameEncoder.encode(signal: .publish, subSignal: .frn, messageId: 0, body: Data([0, 0, 0, 0, 0, 0, 0, 1]))

        fakeTransport.simulateReceivedData(frameBytes)

        let frame = try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
        XCTAssertEqual(frame.header.subSignal, .frp)
    }
}
