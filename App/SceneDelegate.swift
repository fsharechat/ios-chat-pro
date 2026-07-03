// App/SceneDelegate.swift
import UIKit
import Combine
import AppCore
import IMStorage
import IMKit
import IMCall

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var environment: AppEnvironment!
    private var cancellables = Set<AnyCancellable>()
    private var presentedCallViewController: CallViewController?
    /// environment.callManager 为 nil(未登录)时 no-op,登录成功回调里会再
    /// 调一次;用 cancellables 里已有订阅做幂等门(callManager 重建仅发生在
    /// 重新登录,那时 SceneDelegate 也会重走这里)。
    private var callManagerWired = false
    private let themePreferenceStore = ThemePreferenceStore()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let storage: IMStorage
        do {
            storage = try IMStorage.open(atPath: AppEnvironment.defaultDatabasePath())
        } catch {
            // Phase 1 has no DB-corruption-recovery UX yet — fail loudly
            // rather than silently falling back to an in-memory store,
            // which would silently lose the user's message history with no
            // indication anything went wrong.
            fatalError("Failed to open local database: \(error)")
        }
        environment = AppEnvironment(storage: storage)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController()
        window.overrideUserInterfaceStyle = themePreferenceStore.mode.userInterfaceStyle
        wireCallManagerIfReady()
        window.makeKeyAndVisible()
        self.window = window
    }

    private func rootViewController() -> UIViewController {
        environment.connectIfPossible() ? makeMainTabBarController() : makeLoginViewController()
    }

    /// Three tabs: conversations (default landing tab), contacts, and
    /// "我的" (Phase 4). All three are independent `UINavigationController`s.
    private func makeMainTabBarController() -> UIViewController {
        let tabBarController = UITabBarController()

        let conversationListNav = makeConversationListNavigationController()
        conversationListNav.tabBarItem = UITabBarItem(title: "消息", image: UIImage(systemName: "message"), tag: 0)

        let contactListViewModel = ContactListViewModel(storage: environment.storage, contactSync: environment.contactSyncService)
        let contactListNav = makeContactListNavigationController(viewModel: contactListViewModel)
        contactListNav.tabBarItem = UITabBarItem(title: "联系人", image: UIImage(systemName: "person.2"), tag: 1)
        contactListViewModel.$unreadFriendRequestCount
            .sink { [weak contactListNav] count in
                contactListNav?.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil
            }
            .store(in: &cancellables)

        let myProfileViewModel = MyProfileViewModel(
            myUid: environment.imClient?.userId ?? "",
            storage: environment.storage,
            profileUpdating: environment.contactSyncService,
            contactSync: environment.contactSyncService
        )
        let meNav = makeMeNavigationController(viewModel: myProfileViewModel)
        meNav.tabBarItem = UITabBarItem(title: "我的", image: UIImage(systemName: "person.crop.circle"), tag: 2)

        tabBarController.viewControllers = [conversationListNav, contactListNav, meNav]
        return tabBarController
    }

    /// Builds the「我的」tab's nav stack and wires its 2 push destinations
    /// (`MyProfileViewController` from the profile card, `SettingsViewController`
    /// from the settings row) plus `SettingsViewController`'s own 3
    /// destinations — same "closure wired from SceneDelegate" pattern as
    /// `makeContactListNavigationController`/`wireGroupInfoNavigation`.
    private func makeMeNavigationController(viewModel: MyProfileViewModel) -> UINavigationController {
        let meViewController = MeViewController(viewModel: viewModel)
        meViewController.onProfileCardTapped = { [weak self, weak meViewController] in
            guard let self, let imageUploading = self.environment.mediaUploadService else { return }
            let profileViewController = MyProfileViewController(viewModel: viewModel, imageUploading: imageUploading)
            meViewController?.navigationController?.pushViewController(profileViewController, animated: true)
        }
        meViewController.onSettingsTapped = { [weak self, weak meViewController] in
            guard let self else { return }
            let settingsViewController = SettingsViewController()
            settingsViewController.onThemeTapped = { [weak self, weak settingsViewController] in
                guard let self else { return }
                let themeViewController = ThemeViewController(store: self.themePreferenceStore)
                themeViewController.onModeChanged = { [weak self] mode in
                    self?.window?.overrideUserInterfaceStyle = mode.userInterfaceStyle
                }
                settingsViewController?.navigationController?.pushViewController(themeViewController, animated: true)
            }
            settingsViewController.onAboutTapped = { [weak self, weak settingsViewController] in
                guard let self else { return }
                settingsViewController?.navigationController?.pushViewController(AboutViewController(config: self.environment.config), animated: true)
            }
            settingsViewController.onLogoutConfirmed = { [weak self] in
                self?.performLogout()
            }
            meViewController?.navigationController?.pushViewController(settingsViewController, animated: true)
        }
        return UINavigationController(rootViewController: meViewController)
    }

    /// Tears down the current session and switches back to the login
    /// screen — the reverse of `makeLoginViewController`'s
    /// `onLoginSucceeded`. Drops every `cancellables` subscription (the
    /// contact-list unread badge, the call-state sink) and resets
    /// `callManagerWired` before switching root: those were bound to view
    /// models / a `CallManager` that `environment.logOut()` is about to
    /// tear down, and `wireCallManagerIfReady()`'s `callManagerWired`
    /// guard must see a clean slate so it actually re-subscribes to the
    /// next login's new `CallManager`.
    private func performLogout() {
        cancellables.removeAll()
        callManagerWired = false
        environment.logOut()
        window?.rootViewController = makeLoginViewController()
    }

    private func makeConversationListNavigationController() -> UIViewController {
        let viewModel = ConversationListViewModel(storage: environment.storage, contactSync: environment.contactSyncService, groupSync: environment.groupSyncService, currentUserId: environment.imClient?.userId ?? "")
        let listViewController = ConversationListViewController(viewModel: viewModel)
        listViewController.onConversationSelected = { [weak self, weak listViewController] row in
            guard let self else { return }
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
                voiceUploading: self.environment.mediaUploadService,
                fileUploading: self.environment.mediaUploadService,
                videoUploading: self.environment.mediaUploadService,
                remoteHistory: self.environment.messagingService,
                target: row.target,
                conversationType: row.conversationType,
                line: row.line,
                currentUserId: self.environment.imClient?.userId ?? ""
            )
            let conversationViewController = ConversationViewController(row: row, viewModel: conversationViewModel)
            self.wireGroupInfoNavigation(on: conversationViewController, groupId: row.target)
            if row.conversationType == .single {
                self.wireContactInfoNavigation(on: conversationViewController, userId: row.target)
            }
            conversationViewController.onCallTapped = { [weak self] audioOnly in
                self?.startCallIfAuthorized(to: row.target, audioOnly: audioOnly)
            }
            conversationViewController.forwardViewModelFactory = { [weak self] in
                guard let self else { return ConversationListViewModel(storage: (try? IMStorage.openInMemory()) ?? (try! IMStorage.openInMemory()), contactSync: nil, currentUserId: "") }
                return ConversationListViewModel(
                    storage: self.environment.storage,
                    contactSync: self.environment.contactSyncService,
                    groupSync: self.environment.groupSyncService,
                    currentUserId: self.environment.imClient?.userId ?? ""
                )
            }
            listViewController?.navigationController?.pushViewController(conversationViewController, animated: true)
        }
        listViewController.onCreateGroupTapped = { [weak self, weak listViewController] in
            guard let self else { return }
            let createGroupViewModel = CreateGroupViewModel(
                storage: self.environment.storage,
                groupActing: self.environment.groupSyncService,
                groupSyncing: self.environment.groupSyncService
            )
            let createGroupViewController = CreateGroupViewController(viewModel: createGroupViewModel)
            createGroupViewController.onGroupCreated = { [weak self, weak listViewController] groupId, name in
                guard let self else { return }
                let conversationViewModel = ConversationViewModel(
                    storage: self.environment.storage,
                    messageSending: self.environment.messagingService,
                    imageUploading: self.environment.mediaUploadService,
                    voiceUploading: self.environment.mediaUploadService,
                    fileUploading: self.environment.mediaUploadService,
                    videoUploading: self.environment.mediaUploadService,
                    remoteHistory: self.environment.messagingService,
                    target: groupId,
                    conversationType: .group,
                    currentUserId: self.environment.imClient?.userId ?? ""
                )
                let conversationRow = ConversationRow(
                    conversationType: .group, target: groupId, line: 0,
                    displayName: name, avatarURL: nil, previewText: "",
                    timestamp: 0, unreadCount: 0, hasUnreadMention: false,
                    isTop: false, isMuted: false, lastMessageStatus: nil
                )
                let conversationViewController = ConversationViewController(row: conversationRow, viewModel: conversationViewModel)
                self.wireGroupInfoNavigation(on: conversationViewController, groupId: groupId)
                conversationViewController.forwardViewModelFactory = { [weak self] in
                    guard let self else { return ConversationListViewModel(storage: (try? IMStorage.openInMemory()) ?? (try! IMStorage.openInMemory()), contactSync: nil, currentUserId: "") }
                    return ConversationListViewModel(
                        storage: self.environment.storage,
                        contactSync: self.environment.contactSyncService,
                        groupSync: self.environment.groupSyncService,
                        currentUserId: self.environment.imClient?.userId ?? ""
                    )
                }
                listViewController?.navigationController?.popToRootViewController(animated: false)
                listViewController?.navigationController?.pushViewController(conversationViewController, animated: true)
            }
            listViewController?.navigationController?.pushViewController(createGroupViewController, animated: true)
        }
        return UINavigationController(rootViewController: listViewController)
    }

    /// Wires the chat screen's tappable group title (see
    /// `ConversationViewController.onGroupInfoTapped`) to push
    /// `GroupInfoViewController` — shared by both the "open an existing
    /// group" and "just created a group" navigation paths above. A no-op
    /// for single chat (`ConversationViewController` only shows a tappable
    /// title view for `conversationType == .group` in the first place).
    private func wireGroupInfoNavigation(on conversationViewController: ConversationViewController, groupId: String) {
        conversationViewController.onGroupInfoTapped = { [weak self, weak conversationViewController] in
            guard let self else { return }
            let groupInfoViewModel = GroupInfoViewModel(
                groupId: groupId,
                groupActing: self.environment.groupSyncService,
                groupSyncing: self.environment.groupSyncService,
                storage: self.environment.storage,
                currentUserId: self.environment.imClient?.userId ?? ""
            )
            let groupInfoViewController = GroupInfoViewController(viewModel: groupInfoViewModel)

            // 添加成员
            groupInfoViewController.onAddMembersTapped = { [weak self, weak groupInfoViewController] in
                guard let self else { return }
                let addVM = AddGroupMemberViewModel(
                    groupId: groupId,
                    storage: self.environment.storage,
                    groupActing: self.environment.groupSyncService,
                    groupSyncing: self.environment.groupSyncService
                )
                let addVC = AddGroupMemberViewController(viewModel: addVM)
                addVC.onMembersAdded = { [weak addVC] in addVC?.dismiss(animated: true) }
                groupInfoViewController?.present(UINavigationController(rootViewController: addVC), animated: true)
            }

            // 移除成员（跳转到 AddGroupMemberViewController 的移除模式，暂用同一 VC）
            groupInfoViewController.onRemoveMembersTapped = { [weak groupInfoViewController] in
                let alert = UIAlertController(title: "移除成员", message: "请在成员列表中左滑移除", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                groupInfoViewController?.present(alert, animated: true)
            }

            // 查看成员资料
            groupInfoViewController.onMemberTapped = { [weak self, weak groupInfoViewController] uid in
                guard let self else { return }
                let userInfoVC = UserInfoViewController(userId: uid, storage: self.environment.storage)
                userInfoVC.onSendMessage = { [weak self, weak groupInfoViewController] in
                    guard let self else { return }
                    let conversationViewModel = ConversationViewModel(
                        storage: self.environment.storage,
                        messageSending: self.environment.messagingService,
                        imageUploading: self.environment.mediaUploadService,
                        voiceUploading: self.environment.mediaUploadService,
                        fileUploading: self.environment.mediaUploadService,
                        videoUploading: self.environment.mediaUploadService,
                        remoteHistory: self.environment.messagingService,
                        target: uid,
                        conversationType: .single,
                        currentUserId: self.environment.imClient?.userId ?? ""
                    )
                    let user = try? self.environment.storage.users.user(uid: uid)
                    let conversationRow = ConversationRow(
                        conversationType: .single,
                        target: uid,
                        line: 0,
                        displayName: user?.displayName ?? user?.name ?? uid,
                        avatarURL: user?.portrait,
                        previewText: "",
                        timestamp: 0,
                        unreadCount: 0,
                        hasUnreadMention: false,
                        isTop: false,
                        isMuted: false,
                        lastMessageStatus: nil
                    )
                    let conversationVC = ConversationViewController(row: conversationRow, viewModel: conversationViewModel)
                    conversationVC.onCallTapped = { [weak self] audioOnly in
                        self?.startCallIfAuthorized(to: uid, audioOnly: audioOnly)
                    }
                    self.wireContactInfoNavigation(on: conversationVC, userId: uid)
                    groupInfoViewController?.navigationController?.pushViewController(conversationVC, animated: true)
                }
                userInfoVC.onVideoCall = { [weak self] in
                    self?.startCallIfAuthorized(to: uid, audioOnly: false)
                }
                groupInfoViewController?.navigationController?.pushViewController(userInfoVC, animated: true)
            }

            // 群二维码
            groupInfoViewController.onQRCodeTapped = { [weak self, weak groupInfoViewController] in
                guard let self else { return }
                let group = try? self.environment.storage.groups.group(groupId: groupId)
                let qrVC = GroupQRCodeViewController(
                    groupId: groupId,
                    groupName: group?.name ?? groupId,
                    portraitURL: group?.portrait
                )
                groupInfoViewController?.navigationController?.pushViewController(qrVC, animated: true)
            }

            // 群公告
            groupInfoViewController.onGroupNoticeTapped = { [weak self, weak groupInfoViewController] in
                guard let self else { return }
                let group = try? self.environment.storage.groups.group(groupId: groupId)
                let canEdit = group?.owner == self.environment.imClient?.userId
                let noticeVC = GroupNoticeViewController(notice: nil, canEdit: canEdit)
                groupInfoViewController?.navigationController?.pushViewController(noticeVC, animated: true)
            }

            // 查找聊天记录
            groupInfoViewController.onSearchMessagesTapped = { [weak groupInfoViewController] in
                let searchVC = SearchMessageViewController(searcher: groupInfoViewModel.searchMessages)
                groupInfoViewController?.navigationController?.pushViewController(searchVC, animated: true)
            }

            conversationViewController?.navigationController?.pushViewController(groupInfoViewController, animated: true)
        }
    }

    private func wireContactInfoNavigation(on conversationVC: ConversationViewController, userId: String) {
        conversationVC.onContactInfoTapped = { [weak self, weak conversationVC] in
            guard let self else { return }
            let vm = SingleConversationInfoViewModel(userId: userId, storage: self.environment.storage)
            let infoVC = SingleConversationInfoViewController(viewModel: vm)

            infoVC.onAvatarTapped = { [weak self, weak infoVC] in
                guard let self else { return }
                let userInfoVC = UserInfoViewController(userId: userId, storage: self.environment.storage)
                userInfoVC.onSendMessage = { [weak infoVC] in
                    infoVC?.navigationController?.popViewController(animated: true)
                }
                userInfoVC.onVideoCall = { [weak self] in
                    self?.startCallIfAuthorized(to: userId, audioOnly: false)
                }
                infoVC?.navigationController?.pushViewController(userInfoVC, animated: true)
            }

            infoVC.onSearchMessagesTapped = { [weak infoVC] in
                let searchVC = SearchMessageViewController(searcher: vm.searchMessages)
                infoVC?.navigationController?.pushViewController(searchVC, animated: true)
            }

            conversationVC?.navigationController?.pushViewController(infoVC, animated: true)
        }
    }

    /// `ConversationViewController` requires a `ConversationRow` purely for
    /// its nav-bar title/avatar — it has no backing `StoredConversation` row
    /// yet the first time you message a brand-new contact (one gets created
    /// automatically by `MessagingService.sendText`'s first send). The
    /// placeholder fields below (`previewText`/`timestamp`/etc.) are never
    /// read by `ConversationViewController`, which only uses `displayName`
    /// for its title.
    ///
    /// Takes `viewModel` as a parameter (rather than constructing it
    /// internally) so `makeMainTabBarController()` can subscribe to
    /// `viewModel.$unreadFriendRequestCount` for the tab bar badge after
    /// this method returns and the real `tabBarItem` has been assigned.
    private func makeContactListNavigationController(viewModel: ContactListViewModel) -> UINavigationController {
        let listViewController = ContactListViewController(viewModel: viewModel)
        listViewController.onContactSelected = { [weak self, weak listViewController] row in
            guard let self else { return }
            let userInfoVC = UserInfoViewController(userId: row.uid, storage: self.environment.storage)
            userInfoVC.onSendMessage = { [weak self, weak listViewController] in
                guard let self else { return }
                let conversationViewModel = ConversationViewModel(
                    storage: self.environment.storage,
                    messageSending: self.environment.messagingService,
                    imageUploading: self.environment.mediaUploadService,
                    voiceUploading: self.environment.mediaUploadService,
                    fileUploading: self.environment.mediaUploadService,
                    videoUploading: self.environment.mediaUploadService,
                    remoteHistory: self.environment.messagingService,
                    target: row.uid,
                    conversationType: .single,
                    currentUserId: self.environment.imClient?.userId ?? ""
                )
                let conversationRow = ConversationRow(
                    conversationType: .single,
                    target: row.uid,
                    line: 0,
                    displayName: row.displayName,
                    avatarURL: row.avatarURL,
                    previewText: "",
                    timestamp: 0,
                    unreadCount: 0,
                    hasUnreadMention: false,
                    isTop: false,
                    isMuted: false,
                    lastMessageStatus: nil
                )
                let conversationVC = ConversationViewController(row: conversationRow, viewModel: conversationViewModel)
                conversationVC.onCallTapped = { [weak self] audioOnly in
                    self?.startCallIfAuthorized(to: row.uid, audioOnly: audioOnly)
                }
                self.wireContactInfoNavigation(on: conversationVC, userId: row.uid)
                listViewController?.navigationController?.pushViewController(conversationVC, animated: true)
            }
            userInfoVC.onVideoCall = { [weak self] in
                self?.startCallIfAuthorized(to: row.uid, audioOnly: false)
            }
            listViewController?.navigationController?.pushViewController(userInfoVC, animated: true)
        }
        listViewController.onGroupEntryTapped = { [weak self, weak listViewController] in
            guard let self else { return }
            let favGroupVC = FavGroupListViewController(storage: self.environment.storage)
            favGroupVC.onGroupTapped = { [weak self, weak listViewController] groupId in
                guard let self else { return }
                let conversationViewModel = ConversationViewModel(
                    storage: self.environment.storage,
                    messageSending: self.environment.messagingService,
                    imageUploading: self.environment.mediaUploadService,
                    voiceUploading: self.environment.mediaUploadService,
                    fileUploading: self.environment.mediaUploadService,
                    videoUploading: self.environment.mediaUploadService,
                    remoteHistory: self.environment.messagingService,
                    target: groupId,
                    conversationType: .group,
                    line: 0,
                    currentUserId: self.environment.imClient?.userId ?? ""
                )
                let group = try? self.environment.storage.groups.group(groupId: groupId)
                let conversationRow = ConversationRow(
                    conversationType: .group,
                    target: groupId,
                    line: 0,
                    displayName: group?.name ?? groupId,
                    avatarURL: group?.portrait,
                    previewText: "",
                    timestamp: 0,
                    unreadCount: 0,
                    hasUnreadMention: false,
                    isTop: false,
                    isMuted: false,
                    lastMessageStatus: nil
                )
                let conversationVC = ConversationViewController(row: conversationRow, viewModel: conversationViewModel)
                self.wireGroupInfoNavigation(on: conversationVC, groupId: groupId)
                listViewController?.navigationController?.pushViewController(conversationVC, animated: true)
            }
            listViewController?.navigationController?.pushViewController(favGroupVC, animated: true)
        }
        listViewController.onNewFriendsEntryTapped = { [weak self, weak listViewController] in
            guard let self else { return }
            let newFriendsViewModel = NewFriendsViewModel(
                friendRequestSyncing: self.environment.contactSyncService,
                friendRequestSending: self.environment.contactSyncService,
                storage: self.environment.storage
            )
            let newFriendsViewController = NewFriendsViewController(viewModel: newFriendsViewModel)
            newFriendsViewController.onAddFriendTapped = { [weak self, weak newFriendsViewController] in
                guard let self else { return }
                let searchUserViewModel = SearchUserViewModel(
                    userSearching: self.environment.contactSyncService,
                    friendRequestSending: self.environment.contactSyncService,
                    storage: self.environment.storage
                )
                let searchUserViewController = SearchUserViewController(viewModel: searchUserViewModel)
                newFriendsViewController?.navigationController?.pushViewController(searchUserViewController, animated: true)
            }
            listViewController?.navigationController?.pushViewController(newFriendsViewController, animated: true)
        }
        return UINavigationController(rootViewController: listViewController)
    }

    private func makeLoginViewController() -> UIViewController {
        let viewModel = LoginViewModel(
            apiClient: LoginAPIClient(baseURL: environment.config.apiBaseURL),
            credentialsStore: environment.credentialsStore,
            deviceIdentifierProvider: environment.deviceIdentifierProvider
        )
        viewModel.onLoginSucceeded = { [weak self] _ in
            guard let self else { return }
            self.environment.connectIfPossible()
            self.wireCallManagerIfReady()
            self.window?.rootViewController = self.makeMainTabBarController()
        }
        return LoginViewController(viewModel: viewModel)
    }

    private func wireCallManagerIfReady() {
        guard let callManager = environment.callManager, !callManagerWired else { return }
        callManagerWired = true
        callManager.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.handleCallStateChange(state) }
            .store(in: &cancellables)
    }

    /// 任何非 idle 状态都保证通话页在场(incoming 弹应用内来电页 ——
    /// 国行 iPhone 无系统级来电 UI 可用,这是唯一的来电 UI),回到 idle 收掉。
    private func handleCallStateChange(_ state: IMCall.CallState) {
        guard let callManager = environment.callManager else { return }
        if state == .idle {
            presentedCallViewController?.dismiss(animated: true)
            presentedCallViewController = nil
            return
        }
        guard presentedCallViewController == nil, let webRTCClient = environment.webRTCClient, let peerUid = callManager.peerUid else { return }
        let displayName = (try? environment.storage.users.user(uid: peerUid))?.displayName ?? peerUid
        let callViewController = CallViewController(callManager: callManager, webRTCClient: webRTCClient, peerDisplayName: displayName)
        presentedCallViewController = callViewController
        // Present from whatever's actually on top, not blindly from the
        // root — a call must be able to interrupt any other modal flow
        // (e.g. `CreateGroupViewController`/`AddGroupMemberViewController`)
        // already presented, or `UIKit` silently drops the presentation and
        // this VC would never appear despite `presentedCallViewController`
        // being set (permanently blocking this guard for the rest of the call).
        topmostPresentedViewController()?.present(callViewController, animated: true)
    }

    private func topmostPresentedViewController() -> UIViewController? {
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// Gates `CallManager.startCall` on the design spec's permission check
    /// (§5 edge-case table) — denied mic/camera access must redirect to
    /// Settings and must NOT enter the dialing state, so `startCall` is only
    /// reached in the `true` branch below.
    private func startCallIfAuthorized(to peerUid: String, audioOnly: Bool) {
        CallPermissions.ensureAuthorized(audioOnly: audioOnly) { [weak self] authorized in
            guard let self else { return }
            guard authorized else {
                self.presentPermissionDeniedAlert(audioOnly: audioOnly)
                return
            }
            try? self.environment.callManager?.startCall(to: peerUid, audioOnly: audioOnly)
        }
    }

    /// Presented instead of starting the call when `CallPermissions`
    /// reports the mic (or, for video calls, camera) is not authorized —
    /// since the system never re-prompts once denied, the only way forward
    /// is the Settings app.
    private func presentPermissionDeniedAlert(audioOnly: Bool) {
        let message = audioOnly
            ? "需要访问麦克风才能进行语音通话,请前往系统设置开启权限"
            : "需要访问麦克风和摄像头才能进行视频通话,请前往系统设置开启权限"
        let alert = UIAlertController(title: "无法发起通话", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "前往设置", style: .default) { _ in
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(settingsURL)
        })
        topmostPresentedViewController()?.present(alert, animated: true)
    }
}
