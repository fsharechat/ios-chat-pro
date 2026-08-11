// App/AppNavigationController.swift
import UIKit

/// 全局导航容器：把返回键文字统一成「返回」。
///
/// UIKit 默认拿上一页的 `title` 当返回键文案，标题一长就自动 fallback 到系统
/// 本地化的 "Back"/"返回"，同一个 App 里返回键忽而是「会话详情」、忽而是
/// 「返回」。这里在每次 push 前给**当前**栈顶页设置 `backButtonTitle`
/// （它描述的是"从下一页返回到我时显示什么"），使全局一致。
final class AppNavigationController: UINavigationController {
    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        topViewController?.navigationItem.backButtonTitle = "返回"
        super.pushViewController(viewController, animated: animated)
    }
}
