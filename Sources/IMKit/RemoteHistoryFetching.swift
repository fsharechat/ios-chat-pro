import Foundation
import IMStorage
import IMMessaging

/// The remote-history capability `ConversationViewModel.loadMoreHistory`
/// falls back to when local storage runs out of older messages — the iOS
/// counterpart of Android's `ChatManager.getRemoteMessages` fallback inside
/// `ConversationViewModel.loadOldMessages`. `completion` receives the number
/// of newly persisted messages on success (0 when the server had nothing
/// new), or `nil` when the request itself failed (timeout, server error) —
/// mirroring Android's separate success/fail callbacks, so the caller can
/// retry after a failure instead of concluding history is exhausted.
/// Delivered on the main queue like everything else in this codebase.
public protocol RemoteHistoryFetching: AnyObject {
    func loadRemoteMessages(
        conversationType: ConversationType,
        target: String,
        line: Int,
        beforeUid: Int64,
        count: Int,
        completion: @escaping (Int?) -> Void
    )
}

extension MessagingService: RemoteHistoryFetching {}
