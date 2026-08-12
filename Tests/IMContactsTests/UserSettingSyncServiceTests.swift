import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class UserSettingSyncServiceTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var service: UserSettingSyncService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        service = UserSettingSyncService(imClient: imClient, storage: storage)

        imClient.connect()
        fakeTransport.simulate(.connected) // CONNECT message send completes synchronously via the fake's completion callback
    }

    private func decodeOnlySentFrame() throws -> Frame {
        try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
    }

    private func insertConversation(_ conversationType: ConversationType, target: String) throws {
        try storage.dbQueueForTesting.write { db in
            try StoredConversation(conversationType: conversationType, target: target).save(db)
        }
    }

    private func insertGroup(_ groupId: String) throws {
        try storage.dbQueueForTesting.write { db in
            try StoredGroup(groupId: groupId, name: groupId, portrait: nil, owner: nil, groupType: .normal, memberCount: 0, updateDt: 0, memberUpdateDt: 0).save(db)
        }
    }

    private func ugEntry(_ scope: Int32, _ key: String, _ value: String, _ updateDt: Int64) -> Im_UserSettingEntry {
        var e = Im_UserSettingEntry()
        e.scope = scope
        e.key = key
        e.value = value
        e.updateDt = updateDt
        return e
    }

    private func simulateUGResponse(_ entries: [Im_UserSettingEntry]) throws {
        var result = Im_GetUserSettingResult()
        result.entry = entries
        let body = Data([0x00]) + (try result.serializedData())
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .ug, messageId: 1, body: body)
        fakeTransport.simulateReceivedData(frameBytes)
    }

    // MARK: - 1. UG 应答端到端

    func test_receivingUGResponse_isHandledEndToEnd() throws {
        // 三个派生列都要有底层行,否则 setTop/setMuted/setFav 的 raw SQL UPDATE 会静默无操作
        try insertConversation(.group, target: "groupA")
        try insertConversation(.single, target: "userB")
        try insertGroup("groupA")

        try simulateUGResponse([
            ugEntry(3, "1-0-groupA", "1", 100),
            ugEntry(1, "0-0-userB", "1", 200),
            ugEntry(6, "groupA", "1", 150)
        ])

        XCTAssertEqual(try storage.userSettings.value(scope: 3, key: "1-0-groupA"), "1")
        XCTAssertEqual(try storage.userSettings.value(scope: 1, key: "0-0-userB"), "1")
        XCTAssertEqual(try storage.userSettings.value(scope: 6, key: "groupA"), "1")

        let groupConversation = try XCTUnwrap(storage.conversations.conversation(conversationType: .group, target: "groupA"))
        XCTAssertTrue(groupConversation.isTop, "scope 3 应投影到 conversation.isTop")

        let singleConversation = try XCTUnwrap(storage.conversations.conversation(conversationType: .single, target: "userB"))
        XCTAssertTrue(singleConversation.isMuted, "scope 1 应投影到 conversation.isMuted")

        let group = try XCTUnwrap(storage.groups.group(groupId: "groupA"))
        XCTAssertTrue(group.isFav, "scope 6 应投影到 groupInfo.isFav")

        let syncState = try storage.syncState.get()
        XCTAssertEqual(syncState.settingHead, 200, "settingHead 应等于本批最大 updateDt")
    }

    /// Android 等价位置的最终评审查出过「凭空造出空会话行」的 Important —— setTop/
    /// setMuted 用的是 raw SQL UPDATE,本地没有该会话行时必须是纯粹的 no-op,不能顺手
    /// INSERT 一行只填了 isTop/isMuted 的半成品会话出来,否则会话列表会凭空多一行没有
    /// lastMessage/timestamp 的空壳。
    func test_receivingUGResponse_doesNotCreatePhantomConversationRowWhenNoneExistsLocally() throws {
        try simulateUGResponse([
            ugEntry(3, "1-0-groupZ", "1", 100)
        ])

        XCTAssertNil(
            try storage.conversations.conversation(conversationType: .group, target: "groupZ"),
            "没有本地会话行时,UG 投影不应该凭空创建一行"
        )
        // 设置本身仍然要落库,不受会话行是否存在影响
        XCTAssertEqual(try storage.userSettings.value(scope: 3, key: "1-0-groupZ"), "1")
    }

    // MARK: - 2. tombstone

    func test_receivingUGResponse_storesTombstoneAsOrdinaryValueRatherThanDeleting() throws {
        try insertGroup("groupA")

        try simulateUGResponse([ugEntry(6, "groupA", "0", 100)])

        XCTAssertEqual(try storage.userSettings.value(scope: 6, key: "groupA"), "0", "tombstone 应作为普通记录写入,而不是被删除")
        XCTAssertFalse(try storage.userSettings.enabledKeys(scope: 6).contains("groupA"), "但 enabledKeys 只认 \"1\",tombstone 不应出现")
    }

    // MARK: - 3. onSavedGroupsResolved 语义

    func test_onSavedGroupsResolved_onlyReportsSavedGroupsMissingALocalRow() throws {
        // "resolved-group" 本地已有群行 —— 不该出现在回调里
        try insertGroup("resolved-group")

        var resolvedIds: [String]?
        service.onSavedGroupsResolved = { ids in resolvedIds = ids }

        try simulateUGResponse([
            ugEntry(6, "unresolved-group", "1", 100), // 已保存但本地无群行 -> 应出现
            ugEntry(6, "resolved-group", "1", 100),   // 已保存且本地已有群行 -> 不应出现
            ugEntry(6, "tombstoned-group", "0", 100)  // 未保存(tombstone) -> 不应出现
        ])

        XCTAssertEqual(resolvedIds, ["unresolved-group"])
        // 同理: setFav 也是 raw SQL UPDATE,"unresolved-group" 本地没有群行,不该被
        // 凭空 INSERT 出一行只填了 isFav 的半成品群 —— 它出现在回调里就是为了让
        // 调用方(GroupSyncService.refreshGroup)去补一次真正的群信息拉取。
        XCTAssertNil(
            try storage.groups.group(groupId: "unresolved-group"),
            "本地没有群行时,UG 投影不应该凭空创建一行"
        )
    }

    // MARK: - 4. syncUserSettings() 发包

    func test_syncUserSettings_sendsUGRequestWithLocalSettingHeadAsVersion() throws {
        var state = try storage.syncState.get()
        state.settingHead = 555
        try storage.syncState.set(state)

        service.syncUserSettings()

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .ug)
        let request = try Im_Version(serializedBytes: frame.body)
        XCTAssertEqual(request.version, 555)
    }

    // MARK: - 5. updateUserSetting 写本地先于发送

    func test_updateUserSetting_writesLocalBeforeSendingUPRequest() throws {
        service.updateUserSetting(scope: 3, key: "1-0-groupC", value: "1")

        // 写本地不依赖网络往返,调用返回时就应该已经落库
        XCTAssertEqual(try storage.userSettings.value(scope: 3, key: "1-0-groupC"), "1")

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .up)
        let request = try Im_ModifyUserSettingReq(serializedBytes: frame.body)
        XCTAssertEqual(request.scope, 3)
        XCTAssertEqual(request.key, "1-0-groupC")
        XCTAssertEqual(request.value, "1")
    }
}
