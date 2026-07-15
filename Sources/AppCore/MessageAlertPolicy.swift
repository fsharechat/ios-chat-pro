import Foundation

/// Pure decision logic for the message-alert feature: given the three
/// signals `ReceiveMessageHandler.onIncomingMessageAlert` carries, decides
/// whether/how loudly to alert, and applies a simple global leading-edge
/// cooldown so a burst of messages (e.g. an active group chat) doesn't
/// vibrate/ring repeatedly. No UIKit/AudioToolbox dependency — the actual
/// playback lives in `App.MessageAlertPlayer`, which owns one instance of
/// this type.
///
/// **Cooldown semantics:** only a call that would otherwise produce
/// `.vibrate`/`.vibrateAndSound` starts or is subject to the cooldown.
/// `.silent` calls (muted conversation) neither consume nor extend the
/// window — a muted conversation's messages interleaved with real ones
/// don't eat into the throttle budget.
public struct MessageAlertPolicy {
    public enum Alert: Equatable {
        case silent
        case vibrate
        case vibrateAndSound
    }

    private let cooldown: TimeInterval
    private var lastFiredAt: Date?

    public init(cooldown: TimeInterval = 2.0) {
        self.cooldown = cooldown
    }

    public mutating func evaluate(isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool, now: Date) -> Alert {
        guard !isMuted else { return .silent }

        let tier: Alert = (isGroupNotification || isActiveConversation) ? .vibrate : .vibrateAndSound

        if let lastFiredAt, now.timeIntervalSince(lastFiredAt) < cooldown {
            return .silent
        }
        lastFiredAt = now
        return tier
    }
}
