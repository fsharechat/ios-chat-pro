import Foundation
import IMStorage
import IMMessaging

/// Narrow interface `ConversationViewModel` depends on instead of the
/// concrete `MessagingService` — same decoupling-for-testability pattern as
/// `ContactInfoFetching`/`ContactSyncService` above.
public protocol MessageSending: AnyObject {
    /// No default values here even though `MessagingService.sendText` has
    /// them on `mentionedType`/`mentionedTargets` — Swift protocol
    /// conformance checking matches on the exact declared signature, not
    /// on the conforming type's own defaults, so every caller through this
    /// protocol must pass all six arguments explicitly.
    func sendText(to target: String, conversationType: ConversationType, line: Int, text: String, mentionedType: Int32, mentionedTargets: [String]) throws
    func sendImage(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String) throws
    func sendVoice(to target: String, conversationType: ConversationType, line: Int, remoteURL: String, duration: Int) throws
    func sendFile(to target: String, conversationType: ConversationType, line: Int, name: String, size: Int, remoteURL: String) throws
    func sendVideo(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String, duration: Int) throws
    func resend(localMessageId: Int64) throws
}

extension MessagingService: MessageSending {}
