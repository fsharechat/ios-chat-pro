import Foundation
@testable import IMCall

final class FakeCallKitAdapter: CallKitAdapting {
    private(set) var reportedIncomingCalls: [(callId: String, callerName: String, audioOnly: Bool)] = []
    private(set) var reportedOutgoingStarted: [String] = []
    private(set) var reportedConnected: [String] = []
    private(set) var reportedEnded: [(callId: String, reason: CallEndReason)] = []

    func reportIncomingCall(callId: String, callerName: String, audioOnly: Bool, completion: @escaping (Error?) -> Void) {
        reportedIncomingCalls.append((callId, callerName, audioOnly))
        completion(nil)
    }

    func reportOutgoingCallStarted(callId: String) {
        reportedOutgoingStarted.append(callId)
    }

    func reportConnected(callId: String) {
        reportedConnected.append(callId)
    }

    func reportCallEnded(callId: String, reason: CallEndReason) {
        reportedEnded.append((callId, reason))
    }
}
