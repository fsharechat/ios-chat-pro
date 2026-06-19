import Foundation
import IMStorage
import IMMessaging

/// Narrow interface `ConversationViewModel` depends on instead of the
/// concrete `MessagingService` — same decoupling-for-testability pattern as
/// `ContactInfoFetching`/`ContactSyncService` above.
public protocol MessageSending: AnyObject {
    func sendText(to target: String, conversationType: ConversationType, line: Int, text: String) throws
    func sendImage(to target: String, conversationType: ConversationType, line: Int, thumbnail: Data?, remoteURL: String) throws
    func resend(localMessageId: Int64) throws
}

extension MessagingService: MessageSending {}
