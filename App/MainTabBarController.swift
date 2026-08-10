// App/MainTabBarController.swift
import UIKit

/// 需要感知「正在横滑切 tab」的根页面。两个回调的生命周期不同，别合并：
///
/// - `setTabSwipeActive`：手势识别 → **转场动画结束**（完成或取消）。用于收起
///   横移途中会碍眼的悬浮装饰，装饰必须等页面停稳了才能放回来。
/// - `setTabSwipeTouchSuspended`：手势识别 → **手指抬起**。用于掐掉列表 cell
///   的按下态。手指一抬就该复位——没有触摸就不会再有高亮，而且手势的结束
///   回调一定会到达，不像转场回调那样依赖动画链路。
protocol TabSwipeAdapting: AnyObject {
    func setTabSwipeActive(_ active: Bool)
    func setTabSwipeTouchSuspended(_ suspended: Bool)
}

extension TabSwipeAdapting {
    /// 没有悬浮装饰的页面（如消息列表）不必实现。
    func setTabSwipeActive(_ active: Bool) {}
}

extension UITableView {
    /// 横滑期间挂起 cell 的高亮与选中。
    ///
    /// 光靠手势的 `cancelsTouchesInView` 不够：列表的滚动手势被横滑手势判失败
    /// 的那一刻，`UIScrollView` 会把 `delaysContentTouches` 攒下来的触摸立刻
    /// 下发给 cell，于是按下态先闪出来、再被撤销。手指按住停顿超过 0.15 秒再
    /// 横滑时更明显——那时延迟触摸已经超时下发，cell 早就亮着了。
    ///
    /// 所以两头都要堵：`allowsSelection = false` 挡住后面还会来的高亮（为 `false`
    /// 时 `shouldHighlightRowAt` 根本不会被问），再把此刻已经亮着的 cell 抹掉。
    /// 抹的时候不筛 `isHighlighted`——`selectedBackgroundView` 那条路走的是
    /// `isSelected`，筛掉就漏了。
    func setSelectionSuspendedForTabSwipe(_ suspended: Bool) {
        allowsSelection = !suspended
        guard suspended else { return }
        for cell in visibleCells {
            cell.setHighlighted(false, animated: false)
            cell.setSelected(false, animated: false)
        }
    }
}

/// 主 TabBarController：在系统默认点按切换之外，额外支持左右滑动在
/// 消息/联系人/我的三个 tab 间切换，滑动过程跟手（对齐 Android 版本的
/// ViewPager 手感）——两个页面一进一出地跟着手指同步位移，松手时按
/// 位移/速度阈值决定完成切换还是回弹。
///
/// 实现走 UIKit 官方的交互式转场（`UIPercentDrivenInteractiveTransition`
/// + 自定义 animator），而不是自己往 tabBarController.view 上搬 child
/// view：手势一开始就设 `selectedIndex`，由系统在自己的 containerView 里
/// 编排两个页面，tabBar 选中态随之立即变化，取消时系统自动回滚。
///
/// 只在当前 tab 处于导航栈根页面、且没有 modal 呈现时响应滑动，
/// 这样既不会跟子页面的右滑返回手势冲突，也不会影响 modal 内部
/// （如图片浏览器）自己的横向手势。
final class MainTabBarController: UITabBarController {
    /// 非 nil 表示正处于一次跟手切换中。
    private var interaction: UIPercentDrivenInteractiveTransition?
    /// 本次跟手的方向：-1 向左滑（切到后一个 tab），+1 向右滑（切到前一个）。
    private var dragDirection: CGFloat = 0
    /// 本次手势已判定为不可拖动（已到首/尾 tab），不再重复尝试建立转场。
    private var dragRejected = false
    /// 固定顶栏加号的点击动作，由 `SceneDelegate` 注入。
    var onPlusTapped: (() -> Void)?
    /// 顶栏标题的点击动作，由 `SceneDelegate` 注入。
    var onTitleTapped: (() -> Void)?
    /// 顶栏标题，连接状态变化时由 `SceneDelegate` 更新。
    var headerTitle: String? {
        get { headerBar.title }
        set { headerBar.title = newValue }
    }
    /// 加号按钮在本控制器 view 坐标系中的位置，供弹出菜单锚定。
    var headerPlusButtonFrame: CGRect { headerBar.plusButtonFrame(in: view) }

    /// 无动画切换 tab：供「先切 tab 再 push」的跳转使用（顶栏加号菜单在
    /// 任意 tab 都能点，但它的目标页挂在「消息」tab 的导航栈上），避免 tab
    /// 转场动画和紧随其后的 push 动画叠在一起。
    func selectTabWithoutAnimation(_ index: Int) {
        guard viewControllers?.indices.contains(index) == true, index != selectedIndex else { return }
        suppressesTransitionAnimation = true
        selectedIndex = index
        suppressesTransitionAnimation = false
    }

    private var suppressesTransitionAnimation = false

    private let headerBar = AppHeaderBar(title: "飞享IM")

    /// 三个 tab 的根页面共用固定顶栏，各自的导航栏只在 push 出子页面后才
    /// 出现，所以根页面要额外让出顶栏高度。
    override var viewControllers: [UIViewController]? {
        didSet { configureNavigationControllers() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        setupHeaderBar()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        // 识别成功后必须把触摸从底下的视图上撤销（默认行为），否则横滑时
        // 列表 cell 会一路保持按下高亮、松手还可能真的走一次选中：列表的
        // 滚动手势被我们强制判失败了（见下面的失败依赖），UITableView 那套
        // 「一拖动就取消高亮」的逻辑跟着一起失效，触摸原样传到了 cell 上。
        // 横滑要先过 `gestureRecognizerShouldBegin` 的横向判定才会识别，
        // 所以普通点按不受影响。
        view.addGestureRecognizer(pan)
        swipePan = pan
    }

    /// 供 `beginSuppressingListTouches` 的兜底复位查状态。
    private weak var swipePan: UIPanGestureRecognizer?

    private func setupHeaderBar() {
        headerBar.onPlusTapped = { [weak self] in self?.onPlusTapped?() }
        headerBar.onTitleTapped = { [weak self] in self?.onTitleTapped?() }
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: AppHeaderBar.contentHeight),
        ])
    }

    private func configureNavigationControllers() {
        for nav in viewControllers?.compactMap({ $0 as? UINavigationController }) ?? [] {
            nav.delegate = self
            nav.isNavigationBarHidden = true
            nav.viewControllers.first?.additionalSafeAreaInsets.top = AppHeaderBar.contentHeight
        }
    }

    /// 顶栏只在 tab 的根页面显示；push 出子页面后交给该页自己的导航栏
    /// （返回按钮、页面标题都在那上面）。
    ///
    /// 淡入淡出必须挂到转场协调器上跟随进度联动：侧滑返回是交互式的，
    /// 用独立的 `UIView.animate` 会让顶栏停在半透明状态，把下面的列表
    /// 透出来；手势中途取消时还要回滚到原来的显隐状态。
    private func setHeaderHidden(_ hidden: Bool, coordinator: UIViewControllerTransitionCoordinator?) {
        let targetAlpha: CGFloat = hidden ? 0 : 1
        guard headerBar.alpha != targetAlpha else { return }
        guard let coordinator else {
            headerBar.alpha = targetAlpha
            return
        }
        let originalAlpha = headerBar.alpha
        coordinator.animate(alongsideTransition: { _ in
            self.headerBar.alpha = targetAlpha
        }, completion: { context in
            self.headerBar.alpha = context.isCancelled ? originalAlpha : targetAlpha
        })
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let width = view.bounds.width
        guard width > 0 else { return }
        let translation = gesture.translation(in: view).x

        switch gesture.state {
        case .began:
            dragRejected = false
            // 手势一识别就掐掉列表的按下态：此刻列表的滚动手势刚被判失败，
            // 攒下的触摸正要下发给 cell。
            setTabSwipeTouchSuspended(true)
            setTabSwipeActive(true)

        case .changed:
            if interaction == nil {
                guard !dragRejected, translation != 0 else { return }
                guard beginInteractiveSwitch(direction: translation > 0 ? 1 : -1) else {
                    dragRejected = true
                    return
                }
            }
            interaction?.update(progress(for: translation, width: width))

        case .ended, .cancelled, .failed:
            dragRejected = false
            // 手指已经抬起，列表不会再收到触摸，按下态的抑制到此为止——这一步
            // 不能推给转场收尾回调，那条路依赖动画链路，断了列表就永久点不动。
            setTabSwipeTouchSuspended(false)
            guard let interaction else {
                // 没建立转场（已在首/尾 tab，或手指没动过），没有转场收尾回调
                // 能帮忙复位，装饰这里立刻还原。
                setTabSwipeActive(false)
                return
            }
            self.interaction = nil
            // 滑过三分之一屏，或者快速甩动（方向与拖动一致）即判定为完成切换。
            let velocity = gesture.velocity(in: view).x * dragDirection
            let progress = progress(for: translation, width: width)
            if progress > 1.0 / 3 || velocity > 500 {
                interaction.completionSpeed = completionSpeed(remaining: 1 - progress, velocity: velocity, width: width)
                interaction.finish()
            } else {
                // 回弹时剩余的是已滑出的那段，手指速度取反向分量。
                interaction.completionSpeed = completionSpeed(remaining: progress, velocity: -velocity, width: width)
                interaction.cancel()
            }

        default:
            break
        }
    }

    /// 已在首/尾 tab 上继续往外滑时返回 false。否则设置 `selectedIndex`
    /// 触发转场，delegate 随即交出 animator 与这里创建的交互控制器。
    private func beginInteractiveSwitch(direction: CGFloat) -> Bool {
        let toIndex = selectedIndex + (direction < 0 ? 1 : -1)
        guard let viewControllers, viewControllers.indices.contains(toIndex) else { return false }
        dragDirection = direction
        let interaction = UIPercentDrivenInteractiveTransition()
        // 跟手阶段的线性推进由 animator 的 `.curveLinear` 保证（否则百分比和
        // 实际位移对不上、跟手会发飘）；`completionCurve` 只作用于松手之后的
        // 收尾段，用减速曲线更接近「甩到位」的手感。
        interaction.completionCurve = .easeOut
        self.interaction = interaction
        selectedIndex = toIndex
        return true
    }

    /// 手指位移换算成 0...1 的转场进度；反向拖动被夹到 0，不会越界翻成
    /// 反方向切换（那需要换一个目标页，交给下一次手势处理）。
    private func progress(for translation: CGFloat, width: CGFloat) -> CGFloat {
        min(1, max(0, translation * dragDirection / width))
    }

    /// 松手后那段收尾动画的播放倍速。
    ///
    /// 默认 1 倍是把「剩余进度 × 基准时长」匀速走完：手指飞快甩出去、只滑了
    /// 一小截就松手时，剩下的一大截仍按原速慢慢挪，观感就是「松手后拖泥带水」。
    /// 这里按松手瞬间的手指速度折算出这段本该花的时间，夹到 0.08...0.16 秒之间
    /// ——只加速不减速（倍速下限为 1），既不拖沓也不会快到闪现。
    private func completionSpeed(remaining: CGFloat, velocity: CGFloat, width: CGFloat) -> CGFloat {
        let defaultDuration = max(remaining, 0.01) * CGFloat(TabSlideAnimator.duration)
        let byFingerSpeed = velocity > 0 ? remaining * width / velocity : .greatestFiniteMagnitude
        let target = min(max(byFingerSpeed, 0.08), 0.16)
        return max(1, defaultDuration / target)
    }

    /// 把「正在横滑」的状态广播给三个 tab 的根页面。手势识别时置真，转场结束
    /// （完成或取消）复位；重复置同一个值是幂等的。
    private func setTabSwipeActive(_ active: Bool) {
        forEachRootPage { $0.setTabSwipeActive(active) }
    }

    /// 广播「手指还按在屏幕上横滑」，手指抬起即复位。
    private func setTabSwipeTouchSuspended(_ suspended: Bool) {
        forEachRootPage { $0.setTabSwipeTouchSuspended(suspended) }
    }

    private func forEachRootPage(_ body: (TabSwipeAdapting) -> Void) {
        for nav in viewControllers?.compactMap({ $0 as? UINavigationController }) ?? [] {
            if let page = nav.viewControllers.first as? TabSwipeAdapting { body(page) }
        }
    }
}

extension MainTabBarController: UITabBarControllerDelegate {
    func tabBarController(
        _ tabBarController: UITabBarController,
        animationControllerForTransitionFrom fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard !suppressesTransitionAnimation,
              let viewControllers,
              let from = viewControllers.firstIndex(of: fromVC),
              let to = viewControllers.firstIndex(of: toVC) else {
            // 不走自定义动画就没有收尾回调，手势路径已经置真的状态在这里复位。
            setTabSwipeActive(false)
            return nil
        }
        // 目标在右边就让新页从右侧进、旧页向左出，点按切 tab 时同样走这套
        // 动画，跟滑动手感保持一致。
        // 点按切 tab 不经过手势，这里补一次置真（横滑时已经是真了，幂等）。
        setTabSwipeActive(true)
        return TabSlideAnimator(direction: to > from ? -1 : 1) { [weak self] in
            self?.setTabSwipeActive(false)
        }
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        interaction
    }

    /// 点按 tab 切换时，新 tab 可能停在 push 出来的子页面上，顶栏要跟着走。
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        guard let nav = viewController as? UINavigationController else { return }
        setHeaderHidden(nav.viewControllers.count > 1, coordinator: nil)
    }
}

extension MainTabBarController: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        let isRoot = viewController === navigationController.viewControllers.first
        navigationController.setNavigationBarHidden(isRoot, animated: animated)
        setHeaderHidden(!isRoot, coordinator: navigationController.transitionCoordinator)
    }
}

extension MainTabBarController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 列表滚动与横滑必须互斥（见下面的失败依赖），否则斜向拖动时页面
        // 横移的同时列表还在上下滚。其余手势（长按等）放行。
        !isScrollPan(otherGestureRecognizer)
    }

    /// 让列表的滚动手势等横滑手势先失败：横向为主时横滑识别成功、列表被
    /// 判失败，全程不滚；竖向为主时 `gestureRecognizerShouldBegin` 直接让
    /// 横滑失败，列表照常滚动。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        isScrollPan(otherGestureRecognizer)
    }

    private func isScrollPan(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPanGestureRecognizer && gestureRecognizer.view is UIScrollView
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard shouldBeginSwipe(gestureRecognizer) else { return false }
        // 抑制必须抢在这里，不能等 `.began` 的 action：本方法返回 true 之后，
        // 手势状态立刻变成 `.began`，列表的滚动手势随即被判失败，`UIScrollView`
        // 当场把攒下的触摸下发给 cell。等到 action 里再关，高亮那一帧已经渲染
        // 出去了，只能看见它闪一下再被抹掉。
        beginSuppressingListTouches()
        return true
    }

    private func shouldBeginSwipe(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 转场收尾动画期间不接受新手势，避免两次切换叠加。
        guard transitionCoordinator == nil, presentedViewController == nil else { return false }
        // 竖向为主的拖动留给列表滚动，否则滚列表时会误触发转场。
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: view)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
        }
        guard let nav = selectedViewController as? UINavigationController else { return true }
        return nav.viewControllers.count == 1
    }

    private func beginSuppressingListTouches() {
        setTabSwipeTouchSuspended(true)
        // 这里放行不等于手势一定会识别（可能被别的手势挡掉），那种情况下
        // `.ended` 永远不会到达。下一轮 runloop 时手势该进 `.began` 了，
        // 没进就说明黄了，补一次复位，免得列表停在点不动的状态。
        DispatchQueue.main.async { [weak self] in
            guard let self, let pan = self.swipePan else { return }
            guard pan.state != .began, pan.state != .changed else { return }
            self.setTabSwipeTouchSuspended(false)
        }
    }
}

/// tab 之间的横向推移动画：两个页面一进一出，同步位移。
/// `direction` 为 -1 表示新页从右侧进入（切到后一个 tab），+1 为从左侧进入。
private final class TabSlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// 整屏横移的基准时长；跟手松手后的收尾在此基础上按剩余进度和手指速度折算
    /// （见 `MainTabBarController.completionSpeed(remaining:velocity:width:)`）。
    static let duration: TimeInterval = 0.22

    private let direction: CGFloat
    /// 转场收尾（完成或取消都会走到）后的回调。
    private let onTransitionEnd: () -> Void

    init(direction: CGFloat, onTransitionEnd: @escaping () -> Void) {
        self.direction = direction
        self.onTransitionEnd = onTransitionEnd
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        Self.duration
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let fromView = context.view(forKey: .from),
              let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to) else {
            context.completeTransition(false)
            onTransitionEnd()
            return
        }
        let container = context.containerView
        let width = container.bounds.width
        let direction = self.direction
        toView.frame = context.finalFrame(for: toVC)
        toView.transform = CGAffineTransform(translationX: -direction * width, y: 0)
        container.addSubview(toView)

        // 交互驱动要求线性曲线，UIPercentDrivenInteractiveTransition 才能把
        // 进度精确映射到位移上。
        UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: .curveLinear) {
            toView.transform = .identity
            fromView.transform = CGAffineTransform(translationX: direction * width, y: 0)
        } completion: { _ in
            fromView.transform = .identity
            toView.transform = .identity
            context.completeTransition(!context.transitionWasCancelled)
            self.onTransitionEnd()
        }
    }
}
