import XCTest
import GRDB
@testable import IMStorage

final class UserSettingStoreTests: XCTestCase {

    private func makeStorage() throws -> IMStorage {
        try IMStorage.openInMemory()
    }

    private func setting(_ scope: Int, _ key: String, _ value: String, _ updateDt: Int64) -> StoredUserSetting {
        StoredUserSetting(scope: scope, key: key, value: value, updateDt: updateDt)
    }

    func testConversationKeyIsHyphenSeparatedTypeLineTarget() {
        // 必须与服务端 MemoryMessagesStore.getUserConversationSlient 的拼法完全一致
        XCTAssertEqual(
            UserSettingKeys.conversationKey(conversationType: .group, line: 0, target: "group123"),
            "1-0-group123"
        )
        XCTAssertEqual(
            UserSettingKeys.conversationKey(conversationType: .single, line: 0, target: "user456"),
            "0-0-user456"
        )
    }

    func testScopeConstantsMatchServer() {
        XCTAssertEqual(UserSettingKeys.Scope.conversationSilent, 1)
        XCTAssertEqual(UserSettingKeys.Scope.globalSilent, 2)
        XCTAssertEqual(UserSettingKeys.Scope.conversationTop, 3)
        XCTAssertEqual(UserSettingKeys.Scope.favoriteGroup, 6)
    }

    func testUpsertThenReadBack() throws {
        let storage = try makeStorage()

        try storage.userSettings.upsert([setting(6, "group-a", "1", 100)])

        XCTAssertEqual(try storage.userSettings.value(scope: 6, key: "group-a"), "1")
    }

    func testUpsertOverwritesSameScopeAndKey() throws {
        let storage = try makeStorage()

        try storage.userSettings.upsert([setting(6, "group-a", "1", 100)])
        try storage.userSettings.upsert([setting(6, "group-a", "0", 200)])

        XCTAssertEqual(try storage.userSettings.value(scope: 6, key: "group-a"), "0")
    }

    func testSameKeyUnderDifferentScopesCoexist() throws {
        let storage = try makeStorage()

        try storage.userSettings.upsert([
            setting(3, "1-0-group-a", "1", 100),
            setting(1, "1-0-group-a", "1", 100)
        ])

        XCTAssertEqual(try storage.userSettings.value(scope: 3, key: "1-0-group-a"), "1")
        XCTAssertEqual(try storage.userSettings.value(scope: 1, key: "1-0-group-a"), "1")
    }

    func testValueReturnsNilForUnknownKey() throws {
        let storage = try makeStorage()

        XCTAssertNil(try storage.userSettings.value(scope: 6, key: "nope"))
    }

    func testEnabledKeysExcludesTombstones() throws {
        // 取消保存写的是 "0"，不是删除记录；enabledKeys 只认 "1"
        let storage = try makeStorage()
        try storage.userSettings.upsert([
            setting(6, "group-a", "1", 100),
            setting(6, "group-b", "0", 200),
            setting(6, "group-c", "1", 300),
            setting(3, "1-0-group-d", "1", 400)
        ])

        let keys = try storage.userSettings.enabledKeys(scope: 6).sorted()

        XCTAssertEqual(keys, ["group-a", "group-c"])
    }

    func testEnabledKeysReturnsEmptyForUnusedScope() throws {
        let storage = try makeStorage()

        XCTAssertEqual(try storage.userSettings.enabledKeys(scope: 2), [])
    }

    func testClearSessionDataWipesUserSettings() throws {
        // 换账号登录时必须清干净，否则新账号会看到上一个账号保存的群
        let storage = try makeStorage()
        try storage.userSettings.upsert([setting(6, "group-a", "1", 100)])

        try storage.clearSessionData()

        XCTAssertNil(try storage.userSettings.value(scope: 6, key: "group-a"))
        XCTAssertEqual(try storage.syncState.get().settingHead, 0)
    }
}
