import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class UserSearchHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var scheduler: ManualScheduler!
    private var tracker: UserSearchTracker!
    private var handler: UserSearchHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        scheduler = ManualScheduler()
        tracker = UserSearchTracker(scheduler: scheduler)
        handler = UserSearchHandler(storage: storage, tracker: tracker)
    }

    private func makeUser(uid: String, displayName: String) -> Im_User {
        var user = Im_User()
        user.uid = uid
        user.displayName = displayName
        return user
    }

    private func makeFrame(errorCode: UInt8, users: [Im_User] = []) throws -> Frame {
        var result = Im_SearchUserResult()
        result.entry = users
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .us, bodyLength: UInt32(body.count), messageId: 9), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndUS() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .us))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .far))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .us))
    }

    func test_handle_successBody_upsertsEachUserAndResolvesTrackerWithUids() throws {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let frame = try makeFrame(errorCode: 0, users: [makeUser(uid: "u1", displayName: "Alice"), makeUser(uid: "u2", displayName: "Bob")])
        handler.handle(frame: frame)

        switch captured {
        case .success(let uids): XCTAssertEqual(uids, ["u1", "u2"])
        default: XCTFail("expected .success, got \(String(describing: captured))")
        }
        XCTAssertEqual(try storage.users.user(uid: "u1")?.displayName, "Alice")
        XCTAssertEqual(try storage.users.user(uid: "u2")?.displayName, "Bob")
    }

    func test_handle_upsertingMatchedUser_doesNotMarkThemAsFriend() throws {
        let frame = try makeFrame(errorCode: 0, users: [makeUser(uid: "u1", displayName: "Alice")])
        handler.handle(frame: frame)

        XCTAssertEqual(try storage.users.friends().count, 0)
    }

    func test_handle_nonZeroErrorCode_resolvesTrackerWithServerError() throws {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let frame = try makeFrame(errorCode: 6)
        handler.handle(frame: frame)

        switch captured {
        case .failure(.serverError(let code)): XCTAssertEqual(code, 6)
        default: XCTFail("expected .failure(.serverError), got \(String(describing: captured))")
        }
    }

    func test_handle_zeroErrorCodeButMalformedBody_resolvesTrackerWithMalformedResponseImmediately() {
        var captured: Result<[String], UserSearchTracker.TrackerError>?
        tracker.track(wireMessageId: 9) { result in captured = result }

        let body = Data([0]) + Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .us, bodyLength: UInt32(body.count), messageId: 9), body: body)
        handler.handle(frame: frame)

        switch captured {
        case .failure(.malformedResponse): break
        default: XCTFail("expected .failure(.malformedResponse), got \(String(describing: captured))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        let frame = Frame(header: Header(signal: .pubAck, subSignal: .us, bodyLength: 0, messageId: 9), body: Data())
        handler.handle(frame: frame) // must not crash
    }
}
