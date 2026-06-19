import IMStorage

public struct ConversationRow: Equatable, Hashable {
    public let conversationType: ConversationType
    public let target: String
    public let line: Int
    public let displayName: String
    public let avatarURL: String?
    public let previewText: String
    public let timestamp: Int64
    public let unreadCount: Int
    public let isTop: Bool
    public let isMuted: Bool
    public let lastMessageStatus: MessageStatus?

    public init(
        conversationType: ConversationType,
        target: String,
        line: Int,
        displayName: String,
        avatarURL: String?,
        previewText: String,
        timestamp: Int64,
        unreadCount: Int,
        isTop: Bool,
        isMuted: Bool,
        lastMessageStatus: MessageStatus?
    ) {
        self.conversationType = conversationType
        self.target = target
        self.line = line
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.previewText = previewText
        self.timestamp = timestamp
        self.unreadCount = unreadCount
        self.isTop = isTop
        self.isMuted = isMuted
        self.lastMessageStatus = lastMessageStatus
    }
}
