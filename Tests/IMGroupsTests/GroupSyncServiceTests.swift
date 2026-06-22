// Tests/IMGroupsTests/GroupSyncServiceTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMGroups

final class GroupSyncServiceTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var imClient: IMClient!
    private var storage: IMStorage!
    private var scheduler: ManualScheduler!
    private var service: GroupSyncService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()
        storage = try IMStorage.openInMemory()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "me", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        scheduler = ManualScheduler()
        service = GroupSyncService(imClient: imClient, storage: storage, scheduler: scheduler)

        imClient.connect()
        fakeTransport.simulate(.connected)
    }

    private func decodeOnlySentFrame() throws -> Frame {
        try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
    }

    func test_createGroup_sendsGroupNameAndMembersIncludingSelfAsOwner() throws {
        service.createGroup(name: "My Group", memberIds: ["u2", "u3"]) { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gc)
        let request = try Im_CreateGroupRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.group.groupInfo.name, "My Group")
        let memberIds = request.group.members.map(\.memberID)
        XCTAssertEqual(Set(memberIds), ["me", "u2", "u3"])
        let owner = request.group.members.first { $0.memberID == "me" }
        XCTAssertEqual(owner?.type, 2) // GroupMemberType.owner
    }

    func test_createGroup_onSuccess_resolvesWithServerAssignedGroupId() throws {
        var capturedResult: Result<String, Error>?
        service.createGroup(name: "My Group", memberIds: []) { capturedResult = $0 }

        let sentFrame = try decodeOnlySentFrame()
        let body = Data([0x00]) + Data("g999".utf8)
        let ackBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .gc, messageId: sentFrame.header.messageId, body: body)
        fakeTransport.simulateReceivedData(ackBytes)

        switch capturedResult {
        case .success(let groupId): XCTAssertEqual(groupId, "g999")
        default: XCTFail("expected success, got \(String(describing: capturedResult))")
        }
    }

    func test_addMembers_sendsGroupIdAndMemberList() throws {
        service.addMembers(groupId: "g1", memberIds: ["u2"]) { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gam)
        let request = try Im_AddGroupMemberRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
        XCTAssertEqual(request.addedMember.map(\.memberID), ["u2"])
    }

    func test_kickMember_sendsGroupIdAndRemovedMemberList() throws {
        service.kickMember(groupId: "g1", memberId: "u2") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gkm)
        let request = try Im_RemoveGroupMemberRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
        XCTAssertEqual(request.removedMember, ["u2"])
    }

    func test_modifyGroupInfo_sendsGroupIdTypeAndValue() throws {
        service.modifyGroupInfo(groupId: "g1", type: .name, value: "New Name") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gmi)
        let request = try Im_ModifyGroupInfoRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
        XCTAssertEqual(request.type, 0)
        XCTAssertEqual(request.value, "New Name")
    }

    func test_quitGroup_sendsGroupId() throws {
        service.quitGroup(groupId: "g1") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gq)
        let request = try Im_QuitGroupRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
    }

    func test_dismissGroup_sendsGroupId() throws {
        service.dismissGroup(groupId: "g1") { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.subSignal, .gd)
        let request = try Im_DismissGroupRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.groupID, "g1")
    }

    func test_refreshGroup_sendsGPGIThenGPGM() throws {
        let framesSentBeforeTest = fakeTransport.sentFrames.count
        service.refreshGroup(targetId: "g1")

        let decoder = FrameDecoder()
        let frames = fakeTransport.sentFrames[framesSentBeforeTest...].flatMap { decoder.feed($0) }
        XCTAssertEqual(frames.map(\.header.subSignal), [.gpgi, .gpgm])
        let gpgiRequest = try Im_PullUserRequest(serializedBytes: frames[0].body)
        XCTAssertEqual(gpgiRequest.request.map(\.uid), ["g1"])
        let gpgmRequest = try Im_PullGroupMemberRequest(serializedBytes: frames[1].body)
        XCTAssertEqual(gpgmRequest.target, "g1")
        XCTAssertEqual(gpgmRequest.head, 0)
    }

    func test_refreshMembers_usesStoredMemberUpdateDtAsHead() throws {
        try storage.groups.upsertGroup(StoredGroup(groupId: "g1", name: "G1", portrait: nil, owner: nil, groupType: .normal, memberCount: 1, updateDt: 0, memberUpdateDt: 777))

        service.refreshMembers(targetId: "g1")

        let frame = try decodeOnlySentFrame()
        let request = try Im_PullGroupMemberRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.head, 777)
    }

    func test_receivingGPGMResponse_isHandledEndToEnd() throws {
        service.refreshMembers(targetId: "g1")
        let sentFrame = try decodeOnlySentFrame()

        var result = Im_PullGroupMemberResult()
        var member = Im_GroupMember()
        member.memberID = "u2"
        member.type = 0
        result.member = [member]
        let body = Data([0x00]) + (try result.serializedData())
        let ackBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .gpgm, messageId: sentFrame.header.messageId, body: body)

        fakeTransport.simulateReceivedData(ackBytes)

        XCTAssertEqual(try storage.groups.members(groupId: "g1").map(\.memberId), ["u2"])
    }
}
