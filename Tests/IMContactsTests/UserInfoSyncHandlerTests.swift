import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class UserInfoSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: UserInfoSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = UserInfoSyncHandler(storage: storage)
    }

    private func makeFrame(errorCode: UInt8, users: [Im_User]) throws -> Frame {
        var result = Im_PullUserResult()
        result.result = users.map { user in
            var userResult = Im_UserResult()
            userResult.user = user
            userResult.code = 0
            return userResult
        }
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .upui, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    private func makeWireUser(uid: String, displayName: String) -> Im_User {
        var user = Im_User()
        user.uid = uid
        user.displayName = displayName
        return user
    }

    func test_canHandle_onlyMatchesPubAckAndUPUI() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .upui))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .fp))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .upui))
    }

    func test_handle_successBody_upsertsEachUsersProfile() throws {
        let frame = try makeFrame(errorCode: 0, users: [makeWireUser(uid: "u1", displayName: "Alice"), makeWireUser(uid: "u2", displayName: "Bob")])

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.users.user(uid: "u1")?.displayName, "Alice")
        XCTAssertEqual(try storage.users.user(uid: "u2")?.displayName, "Bob")
    }

    func test_handle_doesNotClobberExistingIsFriendFlag() throws {
        try storage.users.replaceFriendList(uids: ["u1"])

        let frame = try makeFrame(errorCode: 0, users: [makeWireUser(uid: "u1", displayName: "Alice")])
        handler.handle(frame: frame)

        let u1 = try storage.users.user(uid: "u1")
        XCTAssertEqual(u1?.displayName, "Alice")
        XCTAssertTrue(u1?.isFriend ?? false)
    }

    func test_handle_nonZeroErrorCode_doesNothingNoCrash() throws {
        let frame = try makeFrame(errorCode: 1, users: [makeWireUser(uid: "u1", displayName: "Alice")])

        handler.handle(frame: frame)

        XCTAssertNil(try storage.users.user(uid: "u1"))
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .upui, bodyLength: 0, messageId: 1), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
