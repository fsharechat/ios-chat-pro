# Phase 4「我的」Tab 设计

## 概述

本设计覆盖 Phase 4 的第一个子项目:对齐 `android-chat-pro`(`cn.wildfire.chat.app.main.MeFragment`)底部 Tab 栏第三个 Tab「我的」的真实功能 —— 个人资料卡、改昵称、改头像、个人二维码、设置(主题/关于/退出登录)。迁移设计文档(`2026-06-17-ios-chat-pro-migration-design.md` §Phase 划分)里列的「频道/订阅号、二维码加好友、全局搜索、APNs 推送」不在本设计范围内,留给各自独立的子项目。

不新增 SPM package,新增能力分布在现有模块体系里:`IMContacts`(资料修改服务)、`AppCore`(主题持久化、退出登录时的本地数据清理)、`IMKit`(ViewModel)、`App`(5 个新 ViewController)。

## 1. 范围与明确排除

**本轮覆盖:**

- 「我的」Tab 根页:资料卡(头像+昵称)+「设置」入口
- 个人资料详情页:改头像、改昵称、「我的二维码」入口
- 个人二维码页:本地生成,内容 `wildfirechat://user/{uid}`
- 设置页:主题(浅色/深色/跟随系统)、关于、退出登录
- 关于页:App 名称/版本号、IM 服务器地址、ICE/STUN 地址、三个外部链接(占位 URL)
- 退出登录:断连 + 清凭证(已有)+ 清本地会话/消息数据 + 重置同步游标(新增,顺带修复一个真实 bug,见第 5 节)

**明确排除(对齐 Android 现状,这些在 Android 端本身也是占位/隐藏,或属于其他 Phase4 子项目):**

- 「消息通知」「账号与安全」:Android 端是占位/隐藏入口,没有真实功能,不实现
- 扫码加好友(扫描他人二维码):属于迁移文档里单独的「二维码加好友」子项目
- 性别/手机号/邮箱等其他资料字段编辑:Android「我的」资料页本身也没有这些编辑入口
- 频道/订阅号、全局搜索、APNs 推送:各自独立子项目

## 2. 模块归属与新增类型

| 模块 | 新增内容 |
|---|---|
| `IMContacts` | `ProfileUpdateService`:封装 `Im_ModifyMyInfoRequest`,通过 `SubSignal.mmi`(协议已定义、目前零引用)发送,解析 `PUB_ACK`/`.mmi` 响应,成功后写回 `UserStore` |
| `AppCore` | `ThemePreferenceStore`(UserDefaults 持久化主题);`AppEnvironment.logOut()` 扩展(清本地会话数据,见第 5 节);`IMStorage` 新增 `clearSessionData()` |
| `IMKit` | `MyProfileViewModel`、`SettingsViewModel`,延续 `ConversationListViewModel` 等既有模式,通过协议(类似 `ImageUploading`)解耦 `ProfileUpdateService`/`MediaUploadService` 依赖 |
| `App` | `MeViewController`、`MyProfileViewController`、`MyQRCodeViewController`、`SettingsViewController`、`ThemeViewController`、`AboutViewController` |
| `App/SceneDelegate` | tab bar 从 2 个扩到 3 个(消息/联系人/我的) |

## 3. 界面清单与导航

```
MeViewController(Tab3 根)
├─ 资料卡(头像+昵称) → MyProfileViewController
│                         ├─ 头像(点击改头像)
│                         ├─ 昵称(点击弹 UIAlertController 改昵称)
│                         └─ 「我的二维码」 → MyQRCodeViewController
└─ 「设置」 → SettingsViewController
                ├─ 「主题」 → ThemeViewController(浅色/深色/跟随系统,单选)
                ├─ 「关于」 → AboutViewController
                └─ 「退出登录」(二次确认 alert)
```

资料卡数据来源 `UserStore.user(uid: myUid)`;若本地为空(全新登录,本地从未存过自己的资料行),`MeViewController`/`MyProfileViewModel` 触发一次 `ContactSyncService.fetchUserInfo(uids: [myUid])`(已有方法,此前从未用自己 uid 调用过)。失败时资料卡显示占位头像+空昵称,不自动重试,下次进入该 Tab 再触发一次。

## 4. 数据流与协议细节

### 4.1 改昵称 / 改头像(`ProfileUpdateService`,新增)

```swift
ProfileUpdateService.updateDisplayName(_ name: String, completion: @escaping (Result<Void, ProfileUpdateError>) -> Void)
ProfileUpdateService.updatePortrait(_ url: String, completion: @escaping (Result<Void, ProfileUpdateError>) -> Void)
```

内部构建 `Im_ModifyMyInfoRequest`(`InfoEntry.type=0` 对应 Android `ModifyMyInfoType.Modify_DisplayName`,`type=1` 对应 `Modify_Portrait`),通过 `imClient.sendFrame(signal: .publish, subSignal: .mmi, body:)` 发出,解析 `PUB_ACK`/`.mmi` 响应时复用 `UserSearchHandler` 的"1 字节错误码 + protobuf"模式。**成功才本地 `UserStore.upsertProfile(...)`**,不做乐观更新 —— 失败时 UI 保持原值并提示错误,避免本地状态和服务端不一致。

头像走两步串行请求:`MyProfileViewController` 选图 → `MediaUploadService.uploadImage(data:)`(已有,复用聊天图片上传逻辑)拿到远程 URL → 用该 URL 调 `ProfileUpdateService.updatePortrait`。中间态用同一个 loading 态覆盖,不细分阶段文案。上传失败和写资料失败都只提示错误、不触碰本地资料。

### 4.2 个人二维码

纯本地生成(`CoreImage` 的 `CIQRCodeGenerator`),内容固定为 `wildfirechat://user/{uid}`(沿用 Android `WfcScheme.QR_CODE_PREFIX_USER` 前缀,为以后扫码加好友子项目预留兼容性),不发请求、不依赖网络、不做保存/分享。

### 4.3 主题持久化

`ThemePreferenceStore`(UserDefaults,key `"theme.mode"`,值 0=浅色/1=深色/2=跟随系统)。`SceneDelegate` 在 `scene(_:willConnectTo:)` 创建 window 后读取并设置一次 `window.overrideUserInterfaceStyle`;`ThemeViewController` 选中新值时同时写 store + 立即设置当前 window 的 `overrideUserInterfaceStyle`,无需重启 App(比 Android 的"改完重启生效"体验更好)。

### 4.4 关于页

展示 `Bundle.main` 的 `CFBundleShortVersionString`/`CFBundleVersion`、`environment.config.imHosts`/`imPort`、`environment.config.iceServers`(只展示 `urlString`,不展示 `username`/`credential`),以及三个链接按钮(功能介绍/用户协议/隐私政策)—— URL 先用占位常量(标注"占位,待替换"),点击用 `UIApplication.open` 调系统 Safari。

## 5. 退出登录与本地数据清理

现状:`AppEnvironment.logOut()`(`Sources/AppCore/AppEnvironment.swift`)目前只断连 + 清 `credentialsStore`,**完全不清本地 SQLite 数据**——聊天记录、会话列表、同步游标全部原样保留。

对照 Android(`SettingActivity.exit()` → `ChatManager.disconnect(true)` → `SqliteDatabaseStore.stop()`):只 `DELETE` `conversations`/`messages` 两张表,好友/群组/用户资料表不清(下次登录走增量同步覆盖)。Android 同时把存同步游标的 `SharedPreferences`(`"wildfirechat.config"`)一并 `clear()` —— iOS 对应的是 `IMStorage.syncState` 表(`msgHead`/`friendHead`/`friendRequestHead`/`settingHead`),目前 `logOut()` 完全没碰它。**不重置的话,换账号登录会用上一账号残留的同步游标去拉增量,导致漏消息/同步错乱**——这是当前代码里一个真实的潜在 bug,本设计顺带修复。

**新增 `IMStorage.clearSessionData()`**(单个 `dbQueue.write` 事务内完成,避免中途失败导致部分清理):

```swift
public func clearSessionData() throws {
    try dbQueue.write { db in
        try StoredMessage.deleteAll(db)
        try StoredConversation.deleteAll(db)
        try StoredSyncState(msgHead: 0, friendHead: 0, friendRequestHead: 0, settingHead: 0).save(db)
    }
}
```

`friends`/`groups`/`users` 表不清,对齐 Android 现状。

**`AppEnvironment.logOut()` 扩展**:在现有断连/清服务对象/清凭证逻辑之后追加 `try? storage.clearSessionData()`。

**UI 触发**:`SettingsViewController`「退出登录」弹二次确认 alert → 确认后调 `environment.logOut()` → 通过 delegate/closure 通知 `SceneDelegate` 把 root 切回 `LoginViewController`(与登录成功后切到 tab bar 是同一套"换根"机制反向跑一次)。

## 6. 测试策略与边界情况

- **`ProfileUpdateService`**:仿照 `MessagingServiceTests`/`UserSearchHandler` 的模式,用 `FakeTransportConnection` 构造真实 `IMClient`,断言发出的 `.mmi` 帧内容、ack 成功时 `UserStore` 被正确 `upsertProfile`、ack 失败时不写本地。
- **`IMStorage.clearSessionData()`**:插入消息+会话+非零 `syncState` 后调用,断言三者都清空/复位,且 `users`/`groups`/`friends` 表不受影响。
- **`ThemePreferenceStore`**:纯 UserDefaults 读写单测,不依赖 UIKit。
- **二维码内容拼接**:断言生成的字符串是 `wildfirechat://user/{uid}`,不对图片像素断言。
- **UI 部分**(5 个新 ViewController):走现有模式,ViewModel 单测 + 用 `/run` 手动跑一遍模拟器验证头像选择、改昵称、退出登录这几个有真实副作用的路径。
- **边界情况**:自己资料拉取失败 → 资料卡占位显示,不自动重试;改资料/上传头像网络失败 → 不写本地、仅提示错误;退出登录时 `clearSessionData()` 失败(极端情况,如磁盘满)→ 仍然继续断连/清凭证/切回登录页,不阻塞退出流程(`try?`)。
