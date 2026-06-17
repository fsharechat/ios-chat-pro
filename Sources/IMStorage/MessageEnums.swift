/// Matches `cn.wildfirechat.model.Conversation.ConversationType`'s raw values
/// (kept identical purely so anyone cross-referencing the Android source
/// isn't surprised — there is no wire/storage compatibility requirement
/// forcing this, local SQLite schemas don't need to match Android's).
public enum ConversationType: Int, Codable, Equatable {
    case single = 0
    case group = 1
    case chatRoom = 2
    case channel = 3
}

/// Matches `cn.wildfirechat.message.core.MessageDirection`.
public enum MessageDirection: Int, Codable, Equatable {
    case send = 0
    case receive = 1
}

/// Subset of `cn.wildfirechat.message.core.MessageStatus` needed for Phase 1
/// (text/image, no mentions, no voice playback). Raw values kept identical
/// to the Android subset in case a later phase needs the rest
/// (`Mentioned=3, AllMentioned=4, Played=7`) — adding them later is a
/// purely additive enum change, not a migration.
public enum MessageStatus: Int, Codable, Equatable {
    case sending = 0
    case sent = 1
    case sendFailure = 2
    case unread = 5
    case read = 6
}

/// Subset of `cn.wildfirechat.message.core.MessageContentType` needed for
/// Phase 1. The full Android enum has ~20 cases (voice, location, file,
/// video, group-management notifications, calls, etc.) — out of scope here.
public enum MessageContentType: Int, Codable, Equatable {
    case text = 1
    case image = 3
}
