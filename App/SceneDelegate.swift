// App/SceneDelegate.swift
import UIKit
import Combine
import AppCore
import IMStorage
import IMKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var environment: AppEnvironment!
    private var cancellables = Set<AnyCancellable>()

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
                line: row.line
            )
            listViewController?.navigationController?.pushViewController(
                ConversationViewController(row: row, viewModel: conversationViewModel),
                animated: true
            )
        }
        return UINavigationController(rootViewController: listViewController)
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
                line: 0
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
                isTop: false,
                isMuted: false,
                lastMessageStatus: nil
            )
            listViewController?.navigationController?.pushViewController(
                ConversationViewController(row: conversationRow, viewModel: conversationViewModel),
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
            self.window?.rootViewController = self.makeMainTabBarController()
        }
        return LoginViewController(viewModel: viewModel)
    }
}
