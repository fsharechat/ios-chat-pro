import UIKit

final class ExtPanelView: UIView {
    static let panelHeight: CGFloat = 260
    var onAlbum: (() -> Void)?
    var onCamera: (() -> Void)?
    var onFile: (() -> Void)?
    var onLocation: (() -> Void)?
    var onAudioCall: (() -> Void)?
    var onVideoCall: (() -> Void)?
    var onVoiceMessage: (() -> Void)?

    var showsCallItems = true {
        didSet {
            for item in [audioItem, videoItem].compactMap({ $0 }) {
                item.alpha = showsCallItems ? 1 : 0
                item.isUserInteractionEnabled = showsCallItems
                item.isAccessibilityElement = showsCallItems
                item.accessibilityElementsHidden = !showsCallItems
            }
        }
    }
    private var audioItem: UIView!
    private var videoItem: UIView!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        layer.cornerRadius = 22
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 16
        grid.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(grid)
        let first = makeRow([
            makeButton(icon: "photo.on.rectangle", title: "相册", action: #selector(albumTapped)),
            makeButton(icon: "camera", title: "拍摄", action: #selector(cameraTapped)),
            makeButton(icon: "doc", title: "文件", action: #selector(fileTapped)),
            makeButton(icon: "location.fill", title: "位置", action: #selector(locationTapped))
        ])
        audioItem = makeButton(icon: "phone.fill", title: "语音通话", action: #selector(audioCallTapped))
        videoItem = makeButton(icon: "video.fill", title: "视频通话", action: #selector(videoCallTapped))
        // Voice messages remain available even while a text draft occupies the send slot.
        let second = makeRow([
            makeButton(icon: "waveform", title: "语音消息", action: #selector(voiceMessageTapped)),
            audioItem, videoItem, UIView()
        ])
        grid.addArrangedSubview(first)
        grid.addArrangedSubview(second)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            grid.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeRow(_ items: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: items)
        row.distribution = .fillEqually
        row.alignment = .top
        return row
    }

    private func makeButton(icon: String, title: String, action: Selector) -> UIView {
        let container = ComposerExtensionItem()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 7
        container.isAccessibilityElement = true
        container.accessibilityLabel = title
        container.accessibilityTraits = .button
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 25)), for: .normal)
        button.tintColor = Theme.accent
        button.backgroundColor = Theme.popupCard
        button.layer.cornerRadius = 16
        button.isAccessibilityElement = false
        button.isUserInteractionEnabled = false
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 56),
            button.heightAnchor.constraint(equalToConstant: 56)
        ])
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.textPrimary
        label.numberOfLines = 0
        label.textAlignment = .center
        label.isAccessibilityElement = false
        container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: action))
        container.onActivate = { [weak self] in _ = self?.perform(action) }
        container.addArrangedSubview(button)
        container.addArrangedSubview(label)
        label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -4).isActive = true
        return container
    }

    @objc private func albumTapped() { onAlbum?() }
    @objc private func cameraTapped() { onCamera?() }
    @objc private func fileTapped() { onFile?() }
    @objc private func locationTapped() { onLocation?() }
    @objc private func audioCallTapped() { onAudioCall?() }
    @objc private func videoCallTapped() { onVideoCall?() }
    @objc private func voiceMessageTapped() { onVoiceMessage?() }
}

private final class ComposerExtensionItem: UIStackView {
    var onActivate: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}
