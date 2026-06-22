import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMGroups

final class GroupInfoSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: GroupInfoSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = GroupInfoSyncHandler(storage: storage)
    }

    private func makeFrame(infos: [Im_GroupInfo]) throws -> Frame {
        var result = Im_PullGroupInfoResult()
        result.info = infos
        let body = Data([0x00]) + (try result.serializedData())
        return Frame(header: Header(signal: .pubAck, subSignal: .gpgi, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    func test_canHandle_onlyMatchesPubAckAndGPGI() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .gpgi))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .gpgm))
    }

    func test_handle_upsertsEachGroupBySelfIdentifyingTargetId() throws {
        var info = Im_GroupInfo()
        info.targetID = "g1"
        info.name = "Group One"
        info.owner = "u1"
        info.type = 0
        info.memberCount = 3
        info.updateDt = 100
        info.memberUpdateDt = 50

        handler.handle(frame: try makeFrame(infos: [info]))

        let group = try storage.groups.group(groupId: "g1")
        XCTAssertEqual(group?.name, "Group One")
        XCTAssertEqual(group?.owner, "u1")
        XCTAssertEqual(group?.groupType, .normal)
        XCTAssertEqual(group?.memberCount, 3)
        XCTAssertEqual(group?.updateDt, 100)
        XCTAssertEqual(group?.memberUpdateDt, 50)
    }

    func test_handle_unsetOptionalFields_decodeAsNil() throws {
        var info = Im_GroupInfo()
        info.targetID = "g1"
        info.name = "Group One"
        info.type = 1 // free — no owner

        handler.handle(frame: try makeFrame(infos: [info]))

        let group = try storage.groups.group(groupId: "g1")
        XCTAssertNil(group?.owner)
        XCTAssertNil(group?.portrait)
        XCTAssertEqual(group?.groupType, .free)
    }

    func test_handle_nonZeroErrorCode_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gpgi, bodyLength: 1, messageId: 1), body: Data([0x01])))
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gpgi, bodyLength: 0, messageId: 1), body: Data()))
    }
}
