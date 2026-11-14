import XCTest
@testable import IMKit

final class ComposerStateTests: XCTestCase {
    func testEmojiAndKeyboardLeaveVoiceModeButMorePreservesIt() {
        var state = ComposerState()
        state.enterVoice()
        state.show(.more)
        XCTAssertEqual(state.mode, .voice)
        state.show(.emoji)
        XCTAssertEqual(state.mode, .text)
        state.enterVoice()
        state.show(.keyboard)
        XCTAssertEqual(state.mode, .text)
        state.collapse()
        XCTAssertEqual(state.surface, .collapsed)
    }

    func testKeyboardAndPanelShareTheirSpaceDuringHandoff() {
        XCTAssertEqual(ComposerState.occupiedHeight(keyboard: 290, panel: 260), 290)
        XCTAssertEqual(ComposerState.occupiedHeight(keyboard: 100, panel: 260), 260)
        XCTAssertEqual(ComposerState.occupiedHeight(keyboard: 0, panel: 260), 260)
        XCTAssertEqual(ComposerState.occupiedHeight(keyboard: 0, panel: 0), 0)
    }

    func testCancellationNeverSendsAndLateReleaseCannotSendAgain() {
        var gesture = VoiceRecordingGestureState()
        gesture.begin()
        XCTAssertFalse(gesture.finish(cancelled: true))
        XCTAssertFalse(gesture.finish(cancelled: false))
        gesture.begin()
        XCTAssertTrue(gesture.finish(cancelled: false))
        XCTAssertFalse(gesture.finish(cancelled: false))
    }

    func testSlideToCancelHasHysteresisAndCanBeReversed() {
        var gesture = VoiceRecordingGestureState()
        gesture.begin()
        gesture.move(upwardDistance: 65)
        gesture.move(upwardDistance: 50)
        XCTAssertTrue(gesture.isCancelArmed)
        XCTAssertFalse(gesture.finish(cancelled: false))
        gesture.begin()
        gesture.move(upwardDistance: 70)
        gesture.move(upwardDistance: 43)
        XCTAssertFalse(gesture.isCancelArmed)
        XCTAssertTrue(gesture.finish(cancelled: false))
    }
}
