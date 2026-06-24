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
    private var callKitProvider: CallKitProvider?
    private var presentedCallViewController: CallViewController?

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
        wireCallManagerIfReady()
        window.makeKeyAndVisible()
        self.window = window
    }

    private func rootViewController() -> UIViewController {
        environment.connectIfPossible() ? makeMainTabBarController() : makeLoginViewController()
    }

    /// Two tabs: conversations (default landing tab) and contacts. Both are
    /// independent `UINavigationController`s, matching the standard
    /// WeChat-style IM navigation shape — a later phase adding a third
    /// "我的" tab is a purely additive change here.
    private func makeMainTabBarController() -> UIViewController {
        let tabBarController = UITabBarController()

        let conversationListNav = makeConversationListNavigationController()
        conversationListNav.tabBarItem = UITabBarItem(title: "消息", image: UIImage(systemName: "message"), tag: 0)

        let contactListViewModel = ContactListViewModel(storage: environment.storage)
        let contactListNav = makeContactListNavigationController(viewModel: contactListViewModel)
        contactListNav.tabBarItem = UITabBarItem(title: "联系人", image: UIImage(systemName: "person.2"), tag: 1)
        contactListViewModel.$unreadFriendRequestCount
            .sink { [weak contactListNav] count in
                contactListNav?.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil
            }
            .store(in: &cancellables)

        tabBarController.viewControllers = [conversationListNav, contactListNav]
        return tabBarController
    }

    private func makeConversationListNavigationController() -> UIViewController {
        let viewModel = ConversationListViewModel(storage: environment.storage, contactSync: environment.contactSyncService)
        let listViewController = ConversationListViewController(viewModel: viewModel)
        listViewController.onConversationSelected = { [weak self, weak listViewController] row in
            guard let self else { return }
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
                target: row.target,
                conversationType: row.conversationType,
                line: row.line,
                currentUserId: self.environment.imClient?.userId ?? ""
            )
            let conversationViewController = ConversationViewController(row: row, viewModel: conversationViewModel)
            self.wireGroupInfoNavigation(on: conversationViewController, groupId: row.target)
            conversationViewController.onCallTapped = { [weak self] audioOnly in
                self?.startCallIfAuthorized(to: row.target, audioOnly: audioOnly)
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
            groupInfoViewController.onAddMembersTapped = { [weak self, weak groupInfoViewController] in
                guard let self else { return }
                let addGroupMemberViewModel = AddGroupMemberViewModel(
                    groupId: groupId,
                    storage: self.environment.storage,
                    groupActing: self.environment.groupSyncService,
                    groupSyncing: self.environment.groupSyncService
                )
                let addGroupMemberViewController = AddGroupMemberViewController(viewModel: addGroupMemberViewModel)
                addGroupMemberViewController.onMembersAdded = { [weak addGroupMemberViewController] in
                    addGroupMemberViewController?.dismiss(animated: true)
                }
                groupInfoViewController?.present(UINavigationController(rootViewController: addGroupMemberViewController), animated: true)
            }
            conversationViewController?.navigationController?.pushViewController(groupInfoViewController, animated: true)
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
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
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
            let conversationViewController = ConversationViewController(row: conversationRow, viewModel: conversationViewModel)
            conversationViewController.onCallTapped = { [weak self] audioOnly in
                self?.startCallIfAuthorized(to: row.uid, audioOnly: audioOnly)
            }
            listViewController?.navigationController?.pushViewController(
                conversationViewController,
                animated: true
            )
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

    /// No-ops if `environment.callManager` is still `nil` (no stored
    /// credentials yet, login screen showing) — called again from
    /// `makeLoginViewController`'s `onLoginSucceeded` once it exists.
    /// Idempotent: a second call after `callKitProvider` already exists
    /// just re-runs harmlessly (re-creating a fresh `CallKitProvider` would
    /// be wrong — `CXProvider` is meant to be a singleton-ish per-app
    /// object — so this guards against that).
    private func wireCallManagerIfReady() {
        guard let callManager = environment.callManager, callKitProvider == nil else { return }
        let provider = CallKitProvider(callManager: callManager)
        callKitProvider = provider
        callManager.callKitAdapter = provider

        callManager.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.handleCallStateChange(state) }
            .store(in: &cancellables)
    }

    /// Presents `CallViewController` full-screen once a call is actually
    /// answered, and dismisses it once the call returns to `.idle`. One
    /// screen for the whole call lifecycle — see `CallViewController`'s own
    /// header comment for why.
    ///
    /// Deliberately does **not** present on `.incoming` — `CallManager.state`
    /// flips to `.incoming` synchronously (this `sink` runs) before
    /// `CallKitAdapting.reportIncomingCall` even calls
    /// `CXProvider.reportNewIncomingCall`, so presenting here would race the
    /// system incoming-call UI, or briefly show our screen first. `.outgoing`
    /// has no competing system UI (`CallKitProvider.reportOutgoingCallStarted`
    /// reports no ringing UI), so it presents immediately; `.connecting`
    /// covers the incoming-call case — by the time a call reaches it, the
    /// user has already answered via the system UI, which is dismissing.
    private func handleCallStateChange(_ state: IMCall.CallState) {
        guard let callManager = environment.callManager else { return }
        if state == .idle {
            presentedCallViewController?.dismiss(animated: true)
            presentedCallViewController = nil
            return
        }
        guard state == .outgoing || state == .connecting else { return }
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
