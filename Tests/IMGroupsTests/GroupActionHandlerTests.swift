import XCTest
import IMClient
import IMTransport
@testable import IMGroups

final class GroupActionHandlerTests: XCTestCase {
    private var tracker: GroupActionTracker!
    private var handler: GroupActionHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tracker = GroupActionTracker(scheduler: ManualScheduler())
        handler = GroupActionHandler(tracker: tracker)
    }

    func test_canHandle_matchesAllFiveGroupActionSubSignals() {
        for subSignal: SubSignal in [.gam, .gkm, .gmi, .gq, .gd] {
            XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: subSignal))
        }
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .gc))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .gam))
    }

    func test_handle_zeroErrorCode_resolvesSuccess() {
        var result: Result<Void, GroupActionTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result = $0 }

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gam, bodyLength: 1, messageId: 7), body: Data([0x00])))

        switch result {
        case .success: break
        default: XCTFail("expected success, got \(String(describing: result))")
        }
    }

    func test_handle_nonZeroErrorCode_resolvesServerError() {
        var result: Result<Void, GroupActionTracker.TrackerError>?
        tracker.track(wireMessageId: 7) { result = $0 }

        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gkm, bodyLength: 1, messageId: 7), body: Data([0x03])))

        switch result {
        case .failure(.serverError(errorCode: 3)): break
        default: XCTFail("expected serverError(3), got \(String(describing: result))")
        }
    }

    func test_handle_emptyBody_doesNothingNoCrash() {
        handler.handle(frame: Frame(header: Header(signal: .pubAck, subSignal: .gq, bodyLength: 0, messageId: 7), body: Data()))
        // no tracked entry, no crash — nothing to assert beyond "didn't crash"
    }
}
