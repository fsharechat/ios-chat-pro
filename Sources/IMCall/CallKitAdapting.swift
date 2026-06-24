import Foundation

/// `CallManager`'s view of CallKit — kept as a protocol so `IMCall` itself
/// never imports CallKit (see the Phase 3 design doc §3: CallKit
/// integration lives in the App target, behind this protocol). The App
/// target's `CallKitProvider` (`App/CallKitProvider.swift`) is the real
/// conformer; `Tests/IMCallTests/Support/FakeCallKitAdapter.swift` is the
/// test double.
public protocol CallKitAdapting: AnyObject {
    /// `completion` carries whatever `CXProvider.reportNewIncomingCall`'s
    /// own completion handler reported (e.g. the system refusing the call
    /// because Do Not Disturb / call blocking is active) — `CallManager`
    /// doesn't currently act on a non-nil error (Phase 3 has no UX for
    /// "the system itself refused this call"), but the signature carries
    /// it through rather than silently swallowing it.
    func reportIncomingCall(callId: String, callerName: String, audioOnly: Bool, completion: @escaping (Error?) -> Void)
    func reportOutgoingCallStarted(callId: String)
    func reportConnected(callId: String)
    func reportCallEnded(callId: String, reason: CallEndReason)
}
