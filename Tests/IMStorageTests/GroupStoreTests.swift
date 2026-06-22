import XCTest
import Combine
@testable import IMStorage

final class GroupStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: GroupStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = GroupStore(dbQueue: database.dbQueue)
        cancellables = []
    }

    func test_upsertGroup_thenFetch_returnsStoredGroup() throws {
        try store.upsertGroup(StoredGroup(groupId: "g1", name: "Group 1", portrait: nil, owner: "u1", groupType: .normal, memberCount: 2, updateDt: 100, memberUpdateDt: 0))

        let group = try store.group(groupId: "g1")
        XCTAssertEqual(group?.name, "Group 1")
        XCTAssertEqual(group?.owner, "u1")
    }

    func test_upsertGroup_overwritesExistingRow() throws {
        try store.upsertGroup(StoredGroup(groupId: "g1", name: "Old Name", portrait: nil, owner: "u1", groupType: .normal, memberCount: 2, updateDt: 100, memberUpdateDt: 0))
        try store.upsertGroup(StoredGroup(groupId: "g1", name: "New Name", portrait: nil, owner: "u1", groupType: .normal, memberCount: 3, updateDt: 200, memberUpdateDt: 0))

        let group = try store.group(groupId: "g1")
        XCTAssertEqual(group?.name, "New Name")
        XCTAssertEqual(group?.memberCount, 3)
    }

    func test_groupPublisher_emitsOnUpsert() throws {
        var received: [StoredGroup?] = []
        let expectation = expectation(description: "received 2 emissions")
        expectation.expectedFulfillmentCount = 2

        store.groupPublisher(groupId: "g1")
            .sink(receiveCompletion: { _ in }, receiveValue: { group in
                received.append(group)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.upsertGroup(StoredGroup(groupId: "g1", name: "Group 1", portrait: nil, owner: "u1", groupType: .normal, memberCount: 1, updateDt: 0, memberUpdateDt: 0))

        wait(for: [expectation], timeout: 2)
        XCTAssertNil(received[0])
        XCTAssertEqual(received[1]?.name, "Group 1")
    }

    func test_upsertMember_thenFetchMembers_excludesRemoved() throws {
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u1", memberType: .owner, updateDt: 1))
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u2", memberType: .normal, updateDt: 2))
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u3", memberType: .removed, updateDt: 3))

        let members = try store.members(groupId: "g1")

        XCTAssertEqual(Set(members.map(\.memberId)), ["u1", "u2"])
    }

    func test_upsertMember_overwritesExistingRowForSamePair() throws {
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u1", memberType: .normal, updateDt: 1))
        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u1", memberType: .owner, updateDt: 2))

        let members = try store.members(groupId: "g1")

        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.memberType, .owner)
    }

    func test_membersPublisher_emitsOnUpsert() throws {
        var receivedCounts: [Int] = []
        let expectation = expectation(description: "received 2 emissions")
        expectation.expectedFulfillmentCount = 2

        store.membersPublisher(groupId: "g1")
            .sink(receiveCompletion: { _ in }, receiveValue: { members in
                receivedCounts.append(members.count)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.upsertMember(StoredGroupMember(groupId: "g1", memberId: "u1", memberType: .owner, updateDt: 1))

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(receivedCounts, [0, 1])
    }
}
