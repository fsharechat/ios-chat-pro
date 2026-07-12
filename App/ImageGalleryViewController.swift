// App/ImageGalleryViewController.swift
import UIKit
import IMKit

/// 画廊的一项：气泡里携带的缩略图 + 原图远端 URL（pending 图为本地
/// 原数据 + nil URL）。
struct GalleryItem {
    let thumbnail: Data?
    let remoteURL: String?
}

/// 全屏图片画廊：UIPageViewController 横向翻页浏览会话内全部图片，
/// 顶部页码，右上角关闭；当前页未缩放时向下拖动可跟手缩小并关闭。
final class ImageGalleryViewController: UIViewController {
    private let items: [GalleryItem]
    private let loader: ImageLoading
    private var currentIndex: Int

    private let pageViewController = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: [.interPageSpacing: 16]
    )
    private let pageLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    init(items: [GalleryItem], startIndex: Int, loader: ImageLoading = ImageLoader.shared) {
        self.items = items
        self.currentIndex = min(max(0, startIndex), items.count - 1)
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
        // overFullScreen 保留底下的聊天界面视图，下拉关闭时背景 alpha
        // 渐变才能透出聊天界面，而不是黑色窗口。
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutViews()
        pageViewController.setViewControllers([makePage(at: currentIndex)], direction: .forward, animated: false)
        updatePageLabel()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    private func layoutViews() {
        addChild(pageViewController)
        pageViewController.dataSource = self
        pageViewController.delegate = self
        pageViewController.view.frame = view.bounds
        pageViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageViewController.view.backgroundColor = .clear
        view.addSubview(pageViewController.view)
        pageViewController.didMove(toParent: self)

        pageLabel.textColor = .white
        pageLabel.font = .systemFont(ofSize: 15)
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageLabel)

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            pageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func makePage(at index: Int) -> ImageZoomPageViewController {
        ImageZoomPageViewController(item: items[index], index: index, loader: loader)
    }

    private var currentPage: ImageZoomPageViewController? {
        pageViewController.viewControllers?.first as? ImageZoomPageViewController
    }

    private func updatePageLabel() {
        pageLabel.text = "\(currentIndex + 1) / \(items.count)"
        pageLabel.isHidden = items.count <= 1
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    // MARK: - 下拉关闭

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        let progress = max(0, translation.y) / max(1, view.bounds.height)

        switch pan.state {
        case .changed:
            let scale = max(0.5, 1 - progress * 0.5)
            pageViewController.view.transform = CGAffineTransform(translationX: translation.x, y: max(0, translation.y))
                .scaledBy(x: scale, y: scale)
            view.backgroundColor = UIColor.black.withAlphaComponent(max(0, 1 - progress * 1.5))
            pageLabel.alpha = max(0, 1 - progress * 3)
            closeButton.alpha = max(0, 1 - progress * 3)
        case .ended, .cancelled:
            if translation.y > 100 || pan.velocity(in: view).y > 800 {
                // 顺着拖动方向滑出再无动画 dismiss，比系统下滑转场更跟手。
                UIView.animate(withDuration: 0.2, animations: {
                    self.pageViewController.view.transform = CGAffineTransform(
                        translationX: translation.x,
                        y: self.view.bounds.height
                    ).scaledBy(x: 0.5, y: 0.5)
                    self.view.backgroundColor = .clear
                }, completion: { _ in
                    self.dismiss(animated: false)
                })
            } else {
                UIView.animate(withDuration: 0.25) {
                    self.pageViewController.view.transform = .identity
                    self.view.backgroundColor = .black
                    self.pageLabel.alpha = 1
                    self.closeButton.alpha = 1
                }
            }
        default:
            break
        }
    }
}

extension ImageGalleryViewController: UIPageViewControllerDataSource {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ImageZoomPageViewController, page.index > 0 else { return nil }
        return makePage(at: page.index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ImageZoomPageViewController, page.index < items.count - 1 else { return nil }
        return makePage(at: page.index + 1)
    }
}

extension ImageGalleryViewController: UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = currentPage else { return }
        currentIndex = page.index
        updatePageLabel()
    }
}

extension ImageGalleryViewController: UIGestureRecognizerDelegate {
    /// 只在当前页未放大、且手势明显向下时启动下拉关闭；
    /// 与翻页/缩放的内部手势并存，互不阻塞。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard let page = currentPage, page.scrollView.zoomScale <= page.scrollView.minimumZoomScale else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.y > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
