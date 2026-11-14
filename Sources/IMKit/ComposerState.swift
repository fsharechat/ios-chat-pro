/// Presentation state shared by the UIKit composer and its tests. No keyboard or audio APIs here.
public struct ComposerState: Equatable {
    public enum Mode { case text, voice }
    public enum Surface { case collapsed, keyboard, emoji, more }
    public private(set) var mode: Mode = .text
    public private(set) var surface: Surface = .collapsed

    public init() {}

    public mutating func show(_ surface: Surface) {
        if surface == .keyboard || surface == .emoji { mode = .text }
        self.surface = surface
    }

    public mutating func enterVoice() {
        mode = .voice
        surface = .collapsed
    }

    public mutating func collapse() { surface = .collapsed }

    /// Both surfaces occupy the same bottom region; they must never be added together.
    public static func occupiedHeight(keyboard: Double, panel: Double) -> Double {
        max(0, keyboard, panel)
    }
}

/// One press can produce at most one recording result. Cancellation never means send.
public struct VoiceRecordingGestureState {
    public private(set) var isActive = false
    public private(set) var isCancelArmed = false

    public init() {}

    public mutating func begin() {
        isActive = true
        isCancelArmed = false
    }

    public mutating func move(upwardDistance: Double) {
        guard isActive else { return }
        if upwardDistance >= 64 { isCancelArmed = true }
        else if upwardDistance < 44 { isCancelArmed = false }
    }

    /// Returns true only when this gesture may send. A second UP/timeout is a no-op.
    public mutating func finish(cancelled: Bool) -> Bool {
        let shouldSend = isActive && !cancelled && !isCancelArmed
        isActive = false
        isCancelArmed = false
        return shouldSend
    }
}
