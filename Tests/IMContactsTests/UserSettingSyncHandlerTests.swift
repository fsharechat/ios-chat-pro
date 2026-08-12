import XCTest
import IMProto
import IMStorage
@testable import IMContacts

final class UserSettingSyncHandlerTests: XCTestCase {

    private func entry(_ scope: Int32, _ key: String, _ value: String, _ updateDt: Int64) -> Im_UserSettingEntry {
        var e = Im_UserSettingEntry()
        e.scope = scope
        e.key = key
        e.value = value
        e.updateDt = updateDt
        return e
    }

    func testProjectedConversationUpdatesParsesTopAndSilent() {
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(3, "1-0-group-a", "1", 100),
            entry(1, "0-0-user-b", "1", 200)
        ])

        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].scope, 3)
        XCTAssertEqual(updates[0].conversationType, .group)
        XCTAssertEqual(updates[0].line, 0)
        XCTAssertEqual(updates[0].target, "group-a")
        XCTAssertTrue(updates[0].enabled)
        XCTAssertEqual(updates[1].conversationType, .single)
        XCTAssertEqual(updates[1].target, "user-b")
    }

    func testProjectedConversationUpdatesTreatsTombstoneAsDisabled() {
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(3, "1-0-group-a", "0", 100)
        ])

        XCTAssertEqual(updates.count, 1)
        XCTAssertFalse(updates[0].enabled)
    }

    func testProjectedConversationUpdatesIgnoresNonConversationScopes() {
        // scope 6 的 key 是群 id、scope 2 的 key 是空串，都不是会话三元组
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(6, "group-a", "1", 100),
            entry(2, "", "1", 200)
        ])

        XCTAssertTrue(updates.isEmpty)
    }

    func testProjectedConversationUpdatesSkipsMalformedKeys() {
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(3, "not-a-key", "1", 100),
            entry(3, "", "1", 200),
            entry(3, "x-0-target", "1", 300),
            entry(3, "1-0-good", "1", 400)
        ])

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].target, "good")
    }

    func testProjectedConversationUpdatesKeepsHyphensInsideTarget() {
        // 群 id 本身可能含连字符，只能按前两个分隔符切
        let updates = UserSettingSyncHandler.projectedConversationUpdates([
            entry(3, "1-0-abc-def-ghi", "1", 100)
        ])

        XCTAssertEqual(updates[0].target, "abc-def-ghi")
    }

    func testMaxUpdateDtNeverGoesBackwards() {
        let entries = [entry(6, "a", "1", 100), entry(6, "b", "1", 50)]

        XCTAssertEqual(UserSettingSyncHandler.maxUpdateDt(entries, current: 200), 200)
        XCTAssertEqual(UserSettingSyncHandler.maxUpdateDt(entries, current: 0), 100)
        XCTAssertEqual(UserSettingSyncHandler.maxUpdateDt([], current: 77), 77)
    }
}
