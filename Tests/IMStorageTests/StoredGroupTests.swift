import XCTest
@testable import IMStorage

final class StoredGroupTests: XCTestCase {
    func test_init_setsAllFields() {
        let group = StoredGroup(groupId: "g1", name: "Test Group", portrait: "http://x/p.png", owner: "u1", groupType: .normal, memberCount: 3, updateDt: 100, memberUpdateDt: 200)
        XCTAssertEqual(group.groupId, "g1")
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.portrait, "http://x/p.png")
        XCTAssertEqual(group.owner, "u1")
        XCTAssertEqual(group.groupType, .normal)
        XCTAssertEqual(group.memberCount, 3)
        XCTAssertEqual(group.updateDt, 100)
        XCTAssertEqual(group.memberUpdateDt, 200)
    }

    func test_groupMember_init_setsAllFields() {
        let member = StoredGroupMember(groupId: "g1", memberId: "u2", memberType: .owner, updateDt: 50)
        XCTAssertEqual(member.groupId, "g1")
        XCTAssertEqual(member.memberId, "u2")
        XCTAssertEqual(member.memberType, .owner)
        XCTAssertEqual(member.updateDt, 50)
    }
}
