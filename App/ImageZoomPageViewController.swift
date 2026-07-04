// App/ImageZoomPageViewController.swift
import UIKit
import IMKit

/// 画廊中的单页：可缩放（双击切换、捏合 1–4x）的一张图。先显示缩略图，
/// 异步经 ImageLoader 加载原图后替换。背景透明，由画廊容器统一铺黑，
/// 下拉关闭时容器才能整体调节背景 alpha。
final class ImageZoomPageViewController: UIViewController {
    let index: Int
    let scrollView = UIScrollView()

    private let item: GalleryItem
    private let loader: ImageLoading
    private let imageView = UIImageView()

    init(item: GalleryItem, index: Int, loader: ImageLoading) {
        self.item = item
        self.index = index
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        layoutViews()
        if let thumbnail = item.thumbnail, let image = UIImage(data: thumbnail) {
            imageView.image = image
        }
        if let remoteURL = item.remoteURL {
            Task { [weak self] in
                guard let self else { return }
                guard let data = await self.loader.loadImageData(from: remoteURL),
                      let image = UIImage(data: data) else { return }
                self.imageView.image = image
            }
        }
    }

    private func layoutViews() {
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            imageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    @objc private func handleDoubleTap() {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            scrollView.setZoomScale(scrollView.maximumZoomScale, animated: true)
        }
    }
}

extension ImageZoomPageViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}
