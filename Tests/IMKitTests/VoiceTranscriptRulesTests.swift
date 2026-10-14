import XCTest
@testable import IMKit

final class VoiceTranscriptRulesTests: XCTestCase {
    private let loading = TranscriptEngine.Entry(status: .loading, text: "", hidden: false)
    private let done = TranscriptEngine.Entry(status: .done, text: "hi", hidden: false)
    private let empty = TranscriptEngine.Entry(status: .done, text: "", hidden: false)
    private let hidden = TranscriptEngine.Entry(status: .done, text: "hi", hidden: true)
    private let error = TranscriptEngine.Entry(status: .error, text: "", hidden: false)

    func test_pill() {
        XCTAssertTrue(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: false, messageUid: 1, entry: nil, auto: false))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: false, messageUid: 1, entry: nil, auto: true))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: true, messageUid: 1, entry: nil, auto: false))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: false, isPlayed: false, messageUid: 1, entry: nil, auto: false))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: false, messageUid: 1, entry: loading, auto: false))
        XCTAssertFalse(VoiceTranscriptRules.showPill(isIncoming: true, isPlayed: false, messageUid: 0, entry: nil, auto: false))
    }

    func test_block() {
        XCTAssertEqual(VoiceTranscriptRules.block(nil), .none)
        XCTAssertEqual(VoiceTranscriptRules.block(loading), .loading)
        XCTAssertEqual(VoiceTranscriptRules.block(done), .text)
        XCTAssertEqual(VoiceTranscriptRules.block(empty), .empty)
        XCTAssertEqual(VoiceTranscriptRules.block(error), .error)
        XCTAssertEqual(VoiceTranscriptRules.block(hidden), .none)
    }

    func test_menusAreMutuallyExclusive() {
        XCTAssertTrue(VoiceTranscriptRules.showTranscribeMenu(messageUid: 1, entry: nil))
        XCTAssertTrue(VoiceTranscriptRules.showTranscribeMenu(messageUid: 1, entry: error))
        XCTAssertTrue(VoiceTranscriptRules.showTranscribeMenu(messageUid: 1, entry: hidden))
        XCTAssertFalse(VoiceTranscriptRules.showTranscribeMenu(messageUid: 1, entry: done))
        XCTAssertTrue(VoiceTranscriptRules.showHideMenu(messageUid: 1, entry: done))
        XCTAssertTrue(VoiceTranscriptRules.showHideMenu(messageUid: 1, entry: loading))
        XCTAssertFalse(VoiceTranscriptRules.showHideMenu(messageUid: 1, entry: hidden))
        XCTAssertFalse(VoiceTranscriptRules.showTranscribeMenu(messageUid: 0, entry: nil))
    }

    func test_isRealtimeRejectsOldMessages() {
        let now: Int64 = 1_000_000_000
        let delta: Int64 = 500
        XCTAssertTrue(VoiceTranscriptRules.isRealtime(serverTimestamp: now + delta - 1_000, serverDelta: delta, now: now))
        XCTAssertTrue(VoiceTranscriptRules.isRealtime(serverTimestamp: now + delta - VoiceTranscriptRules.realtimeWindowMillis, serverDelta: delta, now: now))
        XCTAssertFalse(VoiceTranscriptRules.isRealtime(serverTimestamp: now + delta - VoiceTranscriptRules.realtimeWindowMillis - 1, serverDelta: delta, now: now))
    }
}
