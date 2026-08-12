import Foundation
import IMClient
import IMProto
import IMStorage

/// 用户设置同步的唯一入口：构造时注册 UG 应答与 UN 通知两个 handler，
/// 对外暴露 `syncUserSettings()`（拉）与 `updateUserSetting(scope:key:value:)`（推）。
///
/// 放在 IMContacts 而非新开 module：该模块已经承载「我自己这个账号的数据」的同步
/// （ContactSyncService.updateDisplayName / updatePortrait），用户设置是同一类东西。
///
/// **Threading contract:** 与本代码库其余部分一致，没有内部加锁，
/// 必须从单一一致的队列调用。
public final class UserSettingSyncService {
    private let imClient: IMClient
    private let storage: IMStorage

    /// 转发自 `UserSettingSyncHandler.onSavedGroupsResolved`：已保存但本地无群行的
    /// 群 id。AppEnvironment 把它接到 GroupSyncService.refreshGroup(targetId:)。
    public var onSavedGroupsResolved: (([String]) -> Void)? {
        get { syncHandler.onSavedGroupsResolved }
        set { syncHandler.onSavedGroupsResolved = newValue }
    }

    private let syncHandler: UserSettingSyncHandler

    public init(imClient: IMClient, storage: IMStorage) {
        self.imClient = imClient
        self.storage = storage
        syncHandler = UserSettingSyncHandler(storage: storage)
        imClient.register(syncHandler)

        let notifyHandler = UserSettingNotifyHandler()
        notifyHandler.onUserSettingUpdateNotified = { [weak self] in self?.syncUserSettings() }
        imClient.register(notifyHandler)
    }

    /// 增量拉取：version 取本地已同步到的 settingHead，新设备为 0 即全量。
    public func syncUserSettings() {
        let version = (try? storage.syncState.get().settingHead) ?? 0
        var request = Im_Version()
        request.version = version
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .ug, body: body)
    }

    /// 上报一条设置，同时立刻写本地，UI 不必等服务端往返。
    /// 取消操作传 value "0"（tombstone），不要用删除表达。
    /// 上报失败不回滚本地，下次登录以服务端为准 —— 与 android 端行为一致。
    public func updateUserSetting(scope: Int, key: String, value: String) {
        try? storage.userSettings.upsert([
            StoredUserSetting(scope: scope, key: key, value: value,
                              updateDt: Int64(Date().timeIntervalSince1970 * 1000))
        ])

        var request = Im_ModifyUserSettingReq()
        request.scope = Int32(scope)
        request.key = key
        request.value = value
        guard let body = try? request.serializedData() else { return }
        imClient.sendFrame(signal: .publish, subSignal: .up, body: body)
    }
}
