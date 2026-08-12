import Foundation
import IMClient
import IMProto
import IMStorage
import IMTransport

/// 处理 `PUB_ACK`/`UG` 的用户设置增量拉取应答。线上格式与其他 PUB_ACK 一致：
/// 1 字节错误码 + `Im_GetUserSettingResult`。
///
/// 全部条目写进 `userSetting` 表（含 value "0" 的 tombstone —— 保留它才能表达
/// 「这条被取消过」，读取方一律只认 "1"），再投影到 conversation.isTop /
/// conversation.isMuted / groupInfo.isFav 三个派生列。
///
/// **Threading contract:** 与本代码库其余部分一致，没有内部加锁，
/// 必须从单一一致的队列调用。
public final class UserSettingSyncHandler: MessageHandler {
    private let storage: IMStorage

    /// UG 应用完毕后回调「已保存(scope 6 = "1")但本地还没有群行」的群 id。
    /// 由 AppEnvironment 接到 GroupSyncService.refreshGroup(targetId:) —— 重装后
    /// 本地一个群行都没有，不拉群信息的话 FavGroupListViewController 是空的。
    public var onSavedGroupsResolved: (([String]) -> Void)?

    public init(storage: IMStorage) {
        self.storage = storage
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .ug
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_GetUserSettingResult(serializedBytes: frame.body.dropFirst()) else { return }

        let entries = result.entry
        guard !entries.isEmpty else { return }

        var unresolvedGroupIds: [String] = []
        do {
            try storage.write { db in
                try storage.userSettings.upsert(entries.map {
                    StoredUserSetting(scope: Int($0.scope), key: $0.key, value: $0.value, updateDt: $0.updateDt)
                }, db: db)

                for update in Self.projectedConversationUpdates(entries) {
                    if update.scope == UserSettingKeys.Scope.conversationTop {
                        try storage.conversations.setTop(update.enabled, conversationType: update.conversationType, target: update.target, line: update.line, db: db)
                    } else {
                        try storage.conversations.setMuted(update.enabled, conversationType: update.conversationType, target: update.target, line: update.line, db: db)
                    }
                }

                for entry in entries where Int(entry.scope) == UserSettingKeys.Scope.favoriteGroup {
                    let isFav = entry.value == "1"
                    try storage.groups.setFav(isFav, groupId: entry.key, db: db)
                    if isFav, try storage.groups.group(groupId: entry.key, db: db) == nil {
                        unresolvedGroupIds.append(entry.key)
                    }
                }

                var syncState = try storage.syncState.get(db: db)
                syncState.settingHead = Self.maxUpdateDt(entries, current: syncState.settingHead)
                try storage.syncState.set(syncState, db: db)
            }
        } catch {
            return
        }

        if !unresolvedGroupIds.isEmpty {
            onSavedGroupsResolved?(unresolvedGroupIds)
        }
    }

    /// 把 scope 3/1 的条目解析成派生列更新指令。key 不是合法会话三元组的直接跳过 ——
    /// scope 6 的 key 是群 id、scope 2 的 key 是空串，都不该走这里。
    public static func projectedConversationUpdates(
        _ entries: [Im_UserSettingEntry]
    ) -> [(scope: Int, conversationType: ConversationType, line: Int, target: String, enabled: Bool)] {
        var updates: [(scope: Int, conversationType: ConversationType, line: Int, target: String, enabled: Bool)] = []
        for entry in entries {
            let scope = Int(entry.scope)
            guard scope == UserSettingKeys.Scope.conversationTop
                    || scope == UserSettingKeys.Scope.conversationSilent else { continue }
            // target 里可能含连字符（群 id），只按前两个分隔符切
            let parts = entry.key.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let typeRaw = Int(parts[0]),
                  let conversationType = ConversationType(rawValue: typeRaw),
                  let line = Int(parts[1]),
                  !parts[2].isEmpty else { continue }
            updates.append((scope, conversationType, line, String(parts[2]), entry.value == "1"))
        }
        return updates
    }

    /// 版本号只增不减：以当前值为起点取最大，重叠拉取也不会回退。
    public static func maxUpdateDt(_ entries: [Im_UserSettingEntry], current: Int64) -> Int64 {
        entries.reduce(current) { max($0, $1.updateDt) }
    }
}
