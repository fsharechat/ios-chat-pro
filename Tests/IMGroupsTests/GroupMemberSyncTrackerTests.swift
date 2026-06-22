import XCTest
import IMClient
@testable import IMGroups

final class GroupMemberSyncTrackerTests: XCTestCase {
    func test_track_thenResolve_returnsTheTrackedGroupId() {
        let tracker = GroupMemberSyncTracker(scheduler: ManualScheduler())
        tracker.track(wireMessageId: 1, groupId: "g1")

        XCTAssertEqual(tracker.resolve(wireMessageId: 1), "g1")
    }

    func test_resolve_consumesTheEntry_secondResolveReturnsNil() {
        let tracker = GroupMemberSyncTracker(scheduler: ManualScheduler())
        tracker.track(wireMessageId: 1, groupId: "g1")
        _ = tracker.resolve(wireMessageId: 1)

        XCTAssertNil(tracker.resolve(wireMessageId: 1))
    }

    func test_resolve_forUntrackedId_returnsNil() {
        let tracker = GroupMemberSyncTracker(scheduler: ManualScheduler())
        XCTAssertNil(tracker.resolve(wireMessageId: 99))
    }

    func test_timeoutFires_dropsTheEntry() {
        let scheduler = ManualScheduler()
        let tracker = GroupMemberSyncTracker(scheduler: scheduler)
        tracker.track(wireMessageId: 1, groupId: "g1")

        scheduler.fireNext()

        XCTAssertNil(tracker.resolve(wireMessageId: 1))
    }
}
