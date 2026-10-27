import XCTest
import GRDB
@testable import IMStorage

final class ConversationGapStoreTests: XCTestCase {
    private var storage: IMStorage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
    }

    private func insertMessage(uid: Int64, target: String = "g1", type: ConversationType = .group) throws {
        try storage.messages.insert(StoredMessage(
            localMessageId: uid, messageUid: uid, conversationType: type, target: target,
            from: "other", content: .text("m\(uid)"), timestamp: uid, status: .read, direction: .receive
        ))
    }

    private func record(_ beforeUid: Int64, target: String = "g1") throws -> Bool {
        try storage.write { db in
            try storage.gaps.record(conversationType: .group, target: target, line: 0, beforeUid: beforeUid, db: db)
        }
    }

    private func resolve(_ beforeUid: Int64, returned: [Int64], requested: Int, floor: Int64) throws {
        try storage.write { db in
            try storage.gaps.resolveAfterFill(
                conversationType: .group, target: "g1", line: 0, beforeUid: beforeUid,
                returnedUids: returned, requestedCount: requested, floorUid: floor, db: db
            )
        }
    }

    private func gapUids() throws -> [Int64] {
        try storage.gaps.gaps(conversationType: .group, target: "g1", line: 0).map(\.beforeUid)
    }

    // MARK: - record

    func testRecordsGapWhenOlderLocalMessageExists() throws {
        try insertMessage(uid: 5)
        try insertMessage(uid: 100)

        XCTAssertTrue(try record(100))
        XCTAssertEqual(try gapUids(), [100])
    }

    func testIgnoresGapWhenNothingOlderIsStoredLocally() throws {
        // 本地没有更早的消息：现有的"本地翻完拉远程"已经覆盖，不需要断层
        try insertMessage(uid: 100)

        XCTAssertFalse(try record(100))
        XCTAssertTrue(try gapUids().isEmpty)
    }

    func testOlderMessageInAnotherConversationDoesNotCount() throws {
        try insertMessage(uid: 5, target: "g2")
        try insertMessage(uid: 100)

        XCTAssertFalse(try record(100))
    }

    func testPendingMessagesWithoutUidDoNotCount() throws {
        try insertMessage(uid: 0)
        try insertMessage(uid: 100)

        XCTAssertFalse(try record(100))
    }

    func testTailGapRecordedWhenAnyLocalMessageExists() throws {
        try insertMessage(uid: 5)

        XCTAssertTrue(try record(Int64.max))
        XCTAssertTrue(try storage.gaps.hasTailGap(conversationType: .group, target: "g1", line: 0))
    }

    func testRecordingSameGapTwiceKeepsOneRow() throws {
        try insertMessage(uid: 5)

        _ = try record(100)
        _ = try record(100)

        XCTAssertEqual(try gapUids(), [100])
    }

    // MARK: - visibleFloorUid

    func testVisibleFloorIsHighestNonTailGap() throws {
        try insertMessage(uid: 5)
        _ = try record(50)
        _ = try record(100)
        _ = try record(Int64.max)

        XCTAssertEqual(try storage.gaps.visibleFloorUid(conversationType: .group, target: "g1", line: 0), 100)
    }

    func testVisibleFloorIsNilWithoutGaps() throws {
        XCTAssertNil(try storage.gaps.visibleFloorUid(conversationType: .group, target: "g1", line: 0))
    }

    // MARK: - localFloorUid

    func testLocalFloorIsNewestStoredUidBelowGap() throws {
        try insertMessage(uid: 5)
        try insertMessage(uid: 7)
        try insertMessage(uid: 100)

        let floor = try storage.write { db in
            try storage.gaps.localFloorUid(conversationType: .group, target: "g1", line: 0, below: 100, db: db)
        }

        XCTAssertEqual(floor, 7)
    }

    // MARK: - resolveAfterFill

    func testFullPageAboveFloorMovesGapDown() throws {
        try insertMessage(uid: 5)
        _ = try record(100)

        try resolve(100, returned: [80, 81, 82], requested: 3, floor: 5)

        XCTAssertEqual(try gapUids(), [80])
    }

    func testPageReachingFloorClosesGap() throws {
        try insertMessage(uid: 5)
        _ = try record(100)

        try resolve(100, returned: [5, 6, 7], requested: 3, floor: 5)

        XCTAssertTrue(try gapUids().isEmpty)
    }

    func testShortPageClosesGap() throws {
        try insertMessage(uid: 5)
        _ = try record(100)

        try resolve(100, returned: [80, 81], requested: 3, floor: 5)

        XCTAssertTrue(try gapUids().isEmpty)
    }

    func testEmptyPageClosesGap() throws {
        try insertMessage(uid: 5)
        _ = try record(100)

        try resolve(100, returned: [], requested: 3, floor: 5)

        XCTAssertTrue(try gapUids().isEmpty)
    }

    func testResolvingOneGapLeavesOthersAlone() throws {
        try insertMessage(uid: 5)
        _ = try record(50)
        _ = try record(100)

        try resolve(100, returned: [60, 61, 62], requested: 3, floor: 5)

        XCTAssertEqual(try gapUids().sorted(), [50, 60])
    }

    // MARK: - cleanup

    func testClearingConversationMessagesDropsItsGaps() throws {
        try insertMessage(uid: 5)
        _ = try record(100)

        try storage.messages.clearMessages(conversationType: .group, target: "g1")

        XCTAssertTrue(try gapUids().isEmpty)
    }

    func testClearSessionDataDropsAllGaps() throws {
        try insertMessage(uid: 5)
        _ = try record(100)

        try storage.clearSessionData()

        XCTAssertTrue(try gapUids().isEmpty)
    }
}
