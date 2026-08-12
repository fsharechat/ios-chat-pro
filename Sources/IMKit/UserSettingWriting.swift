// Sources/IMKit/UserSettingWriting.swift
import IMContacts

/// Narrow interface the conversation/group view models depend on instead of
/// the concrete `UserSettingSyncService`.
public protocol UserSettingWriting: AnyObject {
    func updateUserSetting(scope: Int, key: String, value: String)
}

extension UserSettingSyncService: UserSettingWriting {}
