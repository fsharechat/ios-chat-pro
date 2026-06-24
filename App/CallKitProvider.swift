// App/CallKitProvider.swift
import Foundation
import CallKit
import IMCall

/// Bridges `CallManager` to the system telephony UI. Constructed once in
/// `AppEnvironment` alongside `CallManager` (a later task), assigned to
/// `callManager.callKitAdapter`, and given a back-reference to the same
/// `CallManager` so its `CXProviderDelegate` callbacks (user tapped
/// answer/decline on the system call screen) can drive it back.
final class CallKitProvider: NSObject, CallKitAdapting {
    private let provider: CXProvider
    private weak var callManager: CallManager?
    /// CallKit identifies calls by `UUID`, call signaling identifies them
    /// by the `String` `callId` used on the wire — this is the mapping
    /// between the two for the one call in progress (Phase 3 is
    /// one-to-one only, see the design doc §1).
    private var currentCallUUID: UUID?
    private var currentCallId: String?

    init(callManager: CallManager) {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        provider = CXProvider(configuration: configuration)
        self.callManager = callManager
        super.init()
        provider.setDelegate(self, queue: nil) // nil = main queue, matching this codebase's single-queue threading contract
    }

    // MARK: - CallKitAdapting (CallManager → CallKit)

    func reportIncomingCall(callId: String, callerName: String, audioOnly: Bool, completion: @escaping (Error?) -> Void) {
        let callUUID = UUID()
        currentCallUUID = callUUID
        currentCallId = callId

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = !audioOnly
        update.localizedCallerName = callerName

        provider.reportNewIncomingCall(with: callUUID, update: update, completion: completion)
    }

    func reportOutgoingCallStarted(callId: String) {
        // Must assign a UUID here, not just `currentCallId` — `reportConnected`/
        // `reportCallEnded` below both gate on `currentCallUUID` being set, so
        // without this an outgoing call's `reportConnected`/`reportCallEnded`
        // would silently no-op for its entire lifetime.
        //
        // Deliberately not registered with the system via `CXStartCallAction`/
        // `CXCallController` here — Phase 3 is foreground-only and CallKit's
        // job is limited to the incoming-call system UI (design doc §3/§4);
        // an outgoing call gets no status-bar pill / Siri "hang up" support
        // while ringing, only `reportOutgoingCall(with:connectedAt:)` once it
        // connects, via `reportConnected` below.
        currentCallUUID = UUID()
        currentCallId = callId
    }

    func reportConnected(callId: String) {
        guard let callUUID = currentCallUUID else { return }
        provider.reportOutgoingCall(with: callUUID, connectedAt: Date())
    }

    func reportCallEnded(callId: String, reason: CallEndReason) {
        guard let callUUID = currentCallUUID else { return }
        let cxReason: CXCallEndedReason
        switch reason {
        case .remoteBye, .localHangup: cxReason = .remoteEnded
        case .timeout: cxReason = .unanswered
        case .busy: cxReason = .declinedElsewhere
        case .mediaFailure: cxReason = .failed
        }
        provider.reportCall(with: callUUID, endedAt: Date(), reason: cxReason)
        currentCallUUID = nil
        currentCallId = nil
    }
}

extension CallKitProvider: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        try? callManager?.hangUp()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Design spec §5's edge-case table requires checking mic/camera
        // permission before entering the dialing/answering state. Unlike
        // the outgoing path in `SceneDelegate` (which can present a rich
        // "go to Settings" alert from a normal view controller), this fires
        // mid-`CXProviderDelegate` callback with no reasonable view
        // controller to present from. So the asymmetry is deliberate:
        // outgoing calls get a Settings-redirect alert, incoming calls get
        // a graceful auto-decline instead of answering into a broken
        // audio/video state.
        //
        // `callManager?.audioOnly` reflects the just-accepted incoming
        // call's actual flag (set in `CallManager.acceptIncomingCall`
        // before `state` becomes `.incoming`), so this checks exactly the
        // permissions this call needs — no need to over-ask for camera on
        // an audio-only call.
        let audioOnly = callManager?.audioOnly ?? true
        CallPermissions.ensureAuthorized(audioOnly: audioOnly) { [weak self] authorized in
            guard authorized else {
                // `reject()` (via `hangUp`/`endSession`) already reports
                // this call's end through `reportCallEnded` — that's the
                // independent "what happened to the call" channel.
                // `action.fail()` here is a separate acknowledgement that
                // resolves *this pending `CXAnswerCallAction`*, not a
                // second end-of-call report; both are expected to fire.
                try? self?.callManager?.reject()
                action.fail()
                return
            }
            try? self?.callManager?.answer()
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        try? callManager?.hangUp()
        action.fulfill()
    }
}
