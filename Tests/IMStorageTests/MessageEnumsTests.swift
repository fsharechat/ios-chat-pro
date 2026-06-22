import XCTest
@testable import IMStorage

final class MessageEnumsTests: XCTestCase {
    func test_groupType_rawValuesMatchProtoConstants() {
        XCTAssertEqual(GroupType.normal.rawValue, 0)
        XCTAssertEqual(GroupType.free.rawValue, 1)
        XCTAssertEqual(GroupType.restricted.rawValue, 2)
    }

    func test_groupMemberType_rawValuesMatchAndroid() {
        XCTAssertEqual(GroupMemberType.normal.rawValue, 0)
        XCTAssertEqual(GroupMemberType.manager.rawValue, 1)
        XCTAssertEqual(GroupMemberType.owner.rawValue, 2)
        XCTAssertEqual(GroupMemberType.silent.rawValue, 3)
        XCTAssertEqual(GroupMemberType.removed.rawValue, 4)
    }

    func test_modifyGroupInfoType_rawValuesMatchProto() {
        XCTAssertEqual(ModifyGroupInfoType.name.rawValue, 0)
        XCTAssertEqual(ModifyGroupInfoType.portrait.rawValue, 1)
        XCTAssertEqual(ModifyGroupInfoType.extra.rawValue, 2)
    }

    func test_messageContentType_includesGroupNotificationCases() {
        XCTAssertEqual(MessageContentType.createGroup.rawValue, 104)
        XCTAssertEqual(MessageContentType.addGroupMember.rawValue, 105)
        XCTAssertEqual(MessageContentType.kickoffGroupMember.rawValue, 106)
        XCTAssertEqual(MessageContentType.quitGroup.rawValue, 107)
        XCTAssertEqual(MessageContentType.dismissGroup.rawValue, 108)
        XCTAssertEqual(MessageContentType.changeGroupName.rawValue, 110)
        XCTAssertEqual(MessageContentType.changeGroupPortrait.rawValue, 112)
    }
}
