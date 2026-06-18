// App/SceneDelegate.swift
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = .systemBackground
        window.rootViewController = placeholder
        window.makeKeyAndVisible()
        self.window = window
    }
}
