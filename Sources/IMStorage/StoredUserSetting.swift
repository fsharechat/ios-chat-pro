import GRDB

/// 服务端 t_user_setting 的本地镜像，也是本地设置的真值来源。
/// conversation.isTop/isMuted 与 groupInfo.isFav 是从这里投影出去的派生列 ——
/// 之所以两边都留，是因为那三列上已经挂着既有 UI（favGroupsPublisher、
/// 会话列表排序），而这张表在群行/会话行尚未建立时也能保住设置。
public struct StoredUserSetting: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "userSetting"

    public var scope: Int
    public var key: String
    public var value: String
    public var updateDt: Int64

    public init(scope: Int, key: String, value: String, updateDt: Int64) {
        self.scope = scope
        self.key = key
        self.value = value
        self.updateDt = updateDt
    }
}
