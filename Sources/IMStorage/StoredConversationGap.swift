import GRDB

/// 增量拉取时服务端截断某会话留下的断层：本地 `messageUid < beforeUid` 的消息与
/// `>= beforeUid` 的消息之间缺了一段，需要用 `loadRemoteMessages(beforeUid)` 补拉。
/// `beforeUid == Int64.max` 是尾部断层：该会话本次一条都没下发，缺的是最新的一段。
public struct StoredConversationGap: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversationGap"

    public var conversationType: ConversationType
    public var target: String
    public var line: Int
    public var beforeUid: Int64

    public init(conversationType: ConversationType, target: String, line: Int = 0, beforeUid: Int64) {
        self.conversationType = conversationType
        self.target = target
        self.line = line
        self.beforeUid = beforeUid
    }

    public var isTail: Bool { beforeUid == Int64.max }
}
