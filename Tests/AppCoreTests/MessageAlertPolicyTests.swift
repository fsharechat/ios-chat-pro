import XCTest
@testable import AppCore

final class MessageAlertPolicyTests: XCTestCase {
    func test_evaluate_mutedConversation_returnsSilentRegardlessOfOtherSignals() {
        var policy = MessageAlertPolicy()

        XCTAssertEqual(policy.evaluate(isMuted: true, isActiveConversation: false, isGroupNotification: false, now: Date()), .silent)
    }

    func test_evaluate_activeConversationNotMuted_returnsVibrate() {
        var policy = MessageAlertPolicy()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: true, isGroupNotification: false, now: Date()), .vibrate)
    }

    func test_evaluate_notActiveNotMutedNotGroupNotification_returnsVibrateAndSound() {
        var policy = MessageAlertPolicy()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: Date()), .vibrateAndSound)
    }

    func test_evaluate_groupNotificationNotMuted_alwaysReturnsVibrateEvenWhenNotActiveConversation() {
        var policy = MessageAlertPolicy()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: true, now: Date()), .vibrate)
    }

    func test_evaluate_secondCallWithinCooldownWindow_returnsSilent() {
        var policy = MessageAlertPolicy(cooldown: 2)
        let t0 = Date()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0), .vibrateAndSound)
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(1)), .silent)
    }

    func test_evaluate_callAfterCooldownWindowElapses_firesAgain() {
        var policy = MessageAlertPolicy(cooldown: 2)
        let t0 = Date()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0), .vibrateAndSound)
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(2.1)), .vibrateAndSound)
    }

    func test_evaluate_droppedCallDuringCooldown_doesNotExtendTheCooldownWindow() {
        var policy = MessageAlertPolicy(cooldown: 2)
        let t0 = Date()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0), .vibrateAndSound)
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(1)), .silent) // dropped, doesn't reset lastFiredAt
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(2.1)), .vibrateAndSound) // 2.1s after t0, not after the dropped call at t0+1
    }

    func test_evaluate_mutedCallDuringCooldown_doesNotConsumeOrExtendTheWindow() {
        var policy = MessageAlertPolicy(cooldown: 2)
        let t0 = Date()

        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0), .vibrateAndSound)
        XCTAssertEqual(policy.evaluate(isMuted: true, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(0.5)), .silent)
        XCTAssertEqual(policy.evaluate(isMuted: false, isActiveConversation: false, isGroupNotification: false, now: t0.addingTimeInterval(2.1)), .vibrateAndSound)
    }
}
