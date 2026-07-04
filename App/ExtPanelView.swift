import UIKit

final class ExtPanelView: UIView {
    static let panelHeight: CGFloat = 260

    var onAlbum: (() -> Void)?
    var onCamera: (() -> Void)?
    var onFile: (() -> Void)?
    var onLocation: (() -> Void)?
    var onAudioCall: (() -> Void)?
    var onVideoCall: (() -> Void)?

    /// 音视频通话仅单聊可用(与 CallManager 一对一通话的能力一致)——
    /// 群聊会话把整行隐藏。
    var showsCallItems: Bool {
        get { !callRow.isHidden }
        set { callRow.isHidden = !newValue }
    }

    private let callRow = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary

        let firstRow = UIStackView()
        for row in [firstRow, callRow] {
            row.axis = .horizontal
            row.distribution = .fillEqually
        }
        let firstRowItems: [(icon: String, title: String, action: Selector)] = [
            ("photo.on.rectangle", "相册", #selector(albumTapped)),
            ("camera", "拍摄", #selector(cameraTapped)),
            ("doc", "文件", #selector(fileTapped)),
            ("location.fill", "位置", #selector(locationTapped)),
        ]
        for item in firstRowItems {
            firstRow.addArrangedSubview(makeButton(icon: item.icon, title: item.title, action: item.action))
        }
        callRow.addArrangedSubview(makeButton(icon: "phone.fill", title: "语音通话", action: #selector(audioCallTapped)))
        callRow.addArrangedSubview(makeButton(icon: "video.fill", title: "视频通话", action: #selector(videoCallTapped)))
        // 占位:保持与第一行相同的 4 等分,让两个通话按钮左对齐同宽。
        callRow.addArrangedSubview(UIView())
        callRow.addArrangedSubview(UIView())

        let grid = UIStackView(arrangedSubviews: [firstRow, callRow])
        grid.axis = .vertical
        grid.spacing = 16
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            firstRow.heightAnchor.constraint(equalToConstant: 100),
            callRow.heightAnchor.constraint(equalToConstant: 100),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func makeButton(icon: String, title: String, action: Selector) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 8

        let iconContainer = UIView()
        iconContainer.backgroundColor = Theme.backgroundTertiary
        iconContainer.layer.cornerRadius = 12
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 60),
            iconContainer.heightAnchor.constraint(equalToConstant: 60),
        ])

        let img = UIImageView(image: UIImage(systemName: icon))
        img.tintColor = Theme.accent
        img.contentMode = .scaleAspectFit
        img.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(img)
        NSLayoutConstraint.activate([
            img.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            img.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 30),
            img.heightAnchor.constraint(equalToConstant: 30),
        ])

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel

        let tap = UITapGestureRecognizer(target: self, action: action)
        iconContainer.addGestureRecognizer(tap)
        iconContainer.isUserInteractionEnabled = true

        container.addArrangedSubview(iconContainer)
        container.addArrangedSubview(label)
        return container
    }

    @objc private func albumTapped() { onAlbum?() }
    @objc private func cameraTapped() { onCamera?() }
    @objc private func fileTapped() { onFile?() }
    @objc private func locationTapped() { onLocation?() }
    @objc private func audioCallTapped() { onAudioCall?() }
    @objc private func videoCallTapped() { onVideoCall?() }
}
