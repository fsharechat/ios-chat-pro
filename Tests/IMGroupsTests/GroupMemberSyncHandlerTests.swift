import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMGroups

final class GroupMemberSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var tracker: GroupMemberSyncTracker!
    private var handler: GroupMemberSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        tracker = GroupMemberSyncTracker(scheduler: ManualScheduler())
        handler = GroupMemberSyncHandler(storage: storage, tracker: tracker)
    }

    private func makeFrame(members: [Im_GroupMember], messageId: UInt16, errorCode: UInt8 = 0) throws -> Frame {
        var result = Im_PullGroupMemberResult()
        result.member = members
        var body = Data([errorCode])
        if errorCode == 0 { body += try result.serializedData() }
        return Frame(header: Header(signal: .pubAck, subSignal: .gpgm, bodyLength: UInt32(body.count), messageId: messageId), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndGPGM() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .gpgm))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .gpgi))
    }

    func test_handle_tagsEachMemberWithTheTrackedGroupId() throws {
        tracker.track(wireMessageId: 5, groupId: "g1")
        var member = Im_GroupMember()
        member.memberID = "u2"
        member.type = 2 // owner
        member.updateDt = 100

        handler.handle(frame: try makeFrame(members: [member], messageId: 5))

        let members = try storage.groups.members(groupId: "g1")
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.memberId, "u2")
        XCTAssertEqual(members.first?.memberType, .owner)
        XCTAssertEqual(members.first?.updateDt, 100)
    }

    func test_handle_withoutATrackedEntry_doesNothingNoCrash() throws {
        var member = Im_GroupMember()
        member.memberID = "u2"
        member.type = 0

        handler.handle(frame: try makeFrame(members: [member], messageId: 99)) // never tracked

        XCTAssertEqual(try storage.groups.members(groupId: "g1"), [])
    }

    func test_handle_nonZeroErrorCode_stillConsumesTrackerEntryButWritesNothing() throws {
        tracker.track(wireMessageId: 5, groupId: "g1")

        handler.handle(frame: try makeFrame(members: [], messageId: 5, errorCode: 1))

        XCTAssertNil(tracker.resolve(wireMessageId: 5)) // already consumed, not left dangling
        XCTAssertEqual(try storage.groups.members(groupId: "g1"), [])
    }
}
