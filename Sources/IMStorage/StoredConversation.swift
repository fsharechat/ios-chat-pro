import GRDB

public struct StoredConversation: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversation"

    public var conversationType: ConversationType
    public var target: String
    public var line: Int
    public var lastMessageUid: Int64?
    public var timestamp: Int64
    public var unreadCount: Int
    public var unreadMentionCount: Int
    public var isTop: Bool
    public var isMuted: Bool
    public var draft: String?

    public init(
        conversationType: ConversationType,
        target: String,
        line: Int = 0,
        lastMessageUid: Int64? = nil,
        timestamp: Int64 = 0,
        unreadCount: Int = 0,
        unreadMentionCount: Int = 0,
        isTop: Bool = false,
        isMuted: Bool = false,
        draft: String? = nil
    ) {
        self.conversationType = conversationType
        self.target = target
        self.line = line
        self.lastMessageUid = lastMessageUid
        self.timestamp = timestamp
        self.unreadCount = unreadCount
        self.unreadMentionCount = unreadMentionCount
        self.isTop = isTop
        self.isMuted = isMuted
        self.draft = draft
    }
}
