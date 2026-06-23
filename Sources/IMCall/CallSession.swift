import Foundation

public enum CallState: Equatable {
    case idle
    case outgoing
    case incoming
    case connecting
    case connected
}

public enum CallEndReason: Equatable {
    case localHangup
    case remoteBye
    case timeout
    case busy
    case mediaFailure
}

/// Plain data for the call currently in progress — `CallManager` is the
/// only thing that mutates this, and only ever has at most one of these at
/// a time (Phase 3 is one-to-one calling only, see the design doc §1).
struct CallSession {
    let callId: String
    let peerUid: String
    var audioOnly: Bool
    /// The `id` (GRDB row id, not `localMessageId` — see
    /// `MessageStore.updateContent`'s doc comment) of this call's
    /// CallStart bubble, so `CallManager` can update it in place as the
    /// call progresses. `nil` only transiently between `sendCallStart`/
    /// `ReceiveMessageHandler` inserting the row and `CallManager`
    /// capturing the result — never observed `nil` by any of this plan's
    /// call sites.
    var localMessageRowId: Int64?
    /// Set once when the call reaches `.connected`; read back when the
    /// call ends so the final bubble update can report the same
    /// `connectTime` rather than losing it.
    var connectTime: Int64 = 0
}
