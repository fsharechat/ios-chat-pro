import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class FriendSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: FriendSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = FriendSyncHandler(storage: storage)
    }

    private func makeFrame(errorCode: UInt8, uids: [String]) throws -> Frame {
        var result = Im_GetFriendsResult()
        result.entry = uids.map { uid in
            var friend = Im_Friend()
            friend.uid = uid
            // `state` and `updateDt` are `required` fields in the proto2
            // schema (see `Friend` in WFCMessage.proto) — serialization
            // throws `missingRequiredFields` unless every required field is
            // explicitly set, even though `FriendSyncHandler` itself only
            // reads `uid`.
            friend.state = 0
            friend.updateDt = 0
            return friend
        }
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .fp, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndFP() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .fp))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .upui))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .fp))
    }

    func test_handle_successBody_replacesFriendListInStorage() throws {
        let frame = try makeFrame(errorCode: 0, uids: ["u1", "u2"])

        handler.handle(frame: frame)

        let friends = try storage.users.friends()
        XCTAssertEqual(Set(friends.map(\.uid)), ["u1", "u2"])
    }

    func test_handle_nonZeroErrorCode_doesNothingNoCrash() throws {
        let frame = try makeFrame(errorCode: 1, uids: ["u1"])

        handler.handle(frame: frame)

        XCTAssertEqual(try storage.users.friends().count, 0)
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .fp, bodyLength: 0, messageId: 1), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
