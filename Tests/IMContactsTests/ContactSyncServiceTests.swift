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

        let followUpSubSignals = try fakeTransport.sentFrames.suffix(2).map {
            try XCTUnwrap(FrameDecoder().feed($0).first).header.subSignal
        }
        XCTAssertTrue(followUpSubSignals.contains(.frp), "接受成功后应重新拉取好友请求,实际发送: \(followUpSubSignals)")
    }

    func test_acceptFriendRequest_onSuccess_alsoRefreshesFriendList() throws {
        try storage.friendRequests.upsert(StoredFriendRequest(fromUid: "u1", toUid: "me", reason: "hi", status: StoredFriendRequest.Status.pending, updateDt: 100, fromReadStatus: false, toReadStatus: false))
        service.acceptFriendRequest(from: "u1") { _ in }

        let acceptFrame = try decodeOnlySentFrame()
        let ackBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .fhr, messageId: acceptFrame.header.messageId, body: Data([0x00]))
        fakeTransport.simulateReceivedData(ackBytes)

        let followUpSubSignals = try fakeTransport.sentFrames.suffix(2).map {
            try XCTUnwrap(FrameDecoder().feed($0).first).header.subSignal
        }
        XCTAssertTrue(followUpSubSignals.contains(.fp), "接受好友请求成功后应重新拉取好友列表,实际发送: \(followUpSubSignals)")
    }

    func test_receivingFNNotify_triggersFriendListAndFriendRequestPull() throws {
        let frameBytes = FrameEncoder.encode(signal: .publish, subSignal: .fn, messageId: 0, body: Data([0, 0, 0, 0, 0, 0, 0, 1]))

        fakeTransport.simulateReceivedData(frameBytes)

        let sentSubSignals = try fakeTransport.sentFrames.suffix(2).map {
            try XCTUnwrap(FrameDecoder().feed($0).first).header.subSignal
        }
        XCTAssertTrue(sentSubSignals.contains(.fp), "FN 通知(好友关系变化,如对方接受了我的请求)应触发好友列表拉取,实际发送: \(sentSubSignals)")
        XCTAssertTrue(sentSubSignals.contains(.frp), "FN 通知同时应刷新好友请求列表(对齐 Android NotifyFriendHandler),实际发送: \(sentSubSignals)")
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

    func test_updateDisplayName_sendsInfoEntryTypeZeroWithName() throws {
        service.updateDisplayName("NewName") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .mmi)
        let request = try Im_ModifyMyInfoRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.entry.count, 1)
        XCTAssertEqual(request.entry.first?.type, 0)
        XCTAssertEqual(request.entry.first?.value, "NewName")
    }

    func test_updatePortrait_sendsInfoEntryTypeOneWithURL() throws {
        service.updatePortrait("https://example.com/a.png") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .mmi)
        let request = try Im_ModifyMyInfoRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.entry.first?.type, 1)
        XCTAssertEqual(request.entry.first?.value, "https://example.com/a.png")
    }

    func test_updateDisplayName_onSuccess_mergesIntoUserStoreKeepingOtherFields() throws {
        try storage.users.upsertProfile(uid: "me", name: "real-name", displayName: "Old", portrait: "old-url", mobile: "123", gender: 1, updateDt: 5)

        var capturedResult: Result<Void, Error>?
        service.updateDisplayName("New") { result in capturedResult = result }

        let frame = try decodeOnlySentFrame()
        let ackFrame = FrameEncoder.encode(signal: .pubAck, subSignal: .mmi, messageId: frame.header.messageId, body: Data([0x00]))
        fakeTransport.simulateReceivedData(ackFrame)

        switch capturedResult {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: capturedResult))")
        }
        let updated = try storage.users.user(uid: "me")
        XCTAssertEqual(updated?.displayName, "New")
        XCTAssertEqual(updated?.name, "real-name")
        XCTAssertEqual(updated?.portrait, "old-url")
        XCTAssertEqual(updated?.mobile, "123")
        XCTAssertEqual(updated?.gender, 1)
    }

    func test_updateDisplayName_onFailure_doesNotWriteUserStore() throws {
        try storage.users.upsertProfile(uid: "me", name: nil, displayName: "Old", portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        service.updateDisplayName("New") { _ in }

        let frame = try decodeOnlySentFrame()
        let ackFrame = FrameEncoder.encode(signal: .pubAck, subSignal: .mmi, messageId: frame.header.messageId, body: Data([0x06]))
        fakeTransport.simulateReceivedData(ackFrame)

        XCTAssertEqual(try storage.users.user(uid: "me")?.displayName, "Old")
    }

    func test_updatePortrait_onSuccess_mergesIntoUserStoreKeepingDisplayName() throws {
        try storage.users.upsertProfile(uid: "me", name: nil, displayName: "Old", portrait: "old-url", mobile: nil, gender: 0, updateDt: 0)

        service.updatePortrait("new-url") { _ in }

        let frame = try decodeOnlySentFrame()
        let ackFrame = FrameEncoder.encode(signal: .pubAck, subSignal: .mmi, messageId: frame.header.messageId, body: Data([0x00]))
        fakeTransport.simulateReceivedData(ackFrame)

        let updated = try storage.users.user(uid: "me")
        XCTAssertEqual(updated?.portrait, "new-url")
        XCTAssertEqual(updated?.displayName, "Old")
    }
}
