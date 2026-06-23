/// Matches `cn.wildfirechat.model.Conversation.ConversationType`'s raw values
/// (kept identical purely so anyone cross-referencing the Android source
/// isn't surprised — there is no wire/storage compatibility requirement
/// forcing this, local SQLite schemas don't need to match Android's).
public enum ConversationType: Int, Codable, Equatable, Hashable {
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
public enum MessageStatus: Int, Codable, Equatable, Hashable {
    case sending = 0
    case sent = 1
    case sendFailure = 2
    case unread = 5
    case read = 6
}

/// Subset of `cn.wildfirechat.message.core.MessageContentType` needed for
/// Phase 1 + Phase 2 group chat. The 7 group-notification raw values are
/// transcribed from `MessageContentType.java`'s
/// `ContentType_CREATE_GROUP`(104)/`ADD_GROUP_MEMBER`(105)/
/// `KICKOFF_GROUP_MEMBER`(106)/`QUIT_GROUP`(107)/`DISMISS_GROUP`(108)/
/// `CHANGE_GROUP_NAME`(110)/`CHANGE_GROUP_PORTRAIT`(112).
public enum MessageContentType: Int, Codable, Equatable {
    case text = 1
    case image = 3
    case createGroup = 104
    case addGroupMember = 105
    case kickoffGroupMember = 106
    case quitGroup = 107
    case dismissGroup = 108
    case changeGroupName = 110
    case changeGroupPortrait = 112
    /// Matches Android `cn.wildfirechat.message.CallStartMessageContent`'s
    /// `ContentType_Call_Start`(400) — the only one of the 6 call-signaling
    /// types (400-405) that persists/displays as a chat bubble; 401-404 are
    /// transient and never reach `IMStorage` (see `ReceiveMessageHandler`).
    case callStart = 400
}

/// Matches `ProtoConstants.GroupType` (`chat-server-pro`'s
/// `push-stub/.../proto/ProtoConstants.java`) — verified by reading the
/// constants directly, not guessed: `Normal=0`, `Free=1`, `Restricted=2`.
public enum GroupType: Int, Codable, Equatable {
    case normal = 0
    case free = 1
    case restricted = 2
}

/// Matches `cn.wildfirechat.model.GroupMember.GroupMemberType`. `manager`/
/// `silent` are kept for wire parity even though Phase 2's UI never reads or
/// sets them (confirmed unused in Android's own `GroupInfoActivity`) — same
/// "mirror the full enum, use a subset" convention as `MessageStatus`.
public enum GroupMemberType: Int, Codable, Equatable {
    case normal = 0
    case manager = 1
    case owner = 2
    case silent = 3
    case removed = 4
}

/// Matches `ModifyGroupInfoRequest.type`'s declared semantics. `extra` is
/// kept for wire parity though Phase 2's UI has no editor for it.
public enum ModifyGroupInfoType: Int32, Codable, Equatable {
    case name = 0
    case portrait = 1
    case extra = 2
}
