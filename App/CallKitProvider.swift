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
    private let callController = CXCallController()
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
        currentCallId = callId
        // No system UI to report for an outgoing call until it connects —
        // `CXProvider` only needs `reportOutgoingCall(with:startedConnectingAt:)`
        // once the far end actually answers, which `reportConnected` covers.
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
        try? callManager?.answer()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        try? callManager?.hangUp()
        action.fulfill()
    }
}
