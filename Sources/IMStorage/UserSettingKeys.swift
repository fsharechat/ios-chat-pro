/// 用户设置 key 与 scope 的唯一定义处。
/// 会话类 setting 的 key 格式为 type-line-target，必须与服务端
/// MemoryMessagesStore.getUserConversationSlient() 的拼法完全一致，
/// 否则上传的设置服务端读不到。
public enum UserSettingKeys {

    /// 与服务端 UserSettingScope 对齐
    public enum Scope {
        public static let conversationSilent = 1
        public static let globalSilent = 2
        public static let conversationTop = 3
        public static let favoriteGroup = 6
    }

    public static func conversationKey(conversationType: ConversationType, line: Int, target: String) -> String {
        "\(conversationType.rawValue)-\(line)-\(target)"
    }
}
