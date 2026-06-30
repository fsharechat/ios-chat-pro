import UIKit

final class ExtPanelView: UIView {
    static let panelHeight: CGFloat = 260

    var onAlbum: (() -> Void)?
    var onCamera: (() -> Void)?
    var onFile: (() -> Void)?
    var onLocation: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundSecondary
        let items: [(icon: String, title: String, action: Selector)] = [
            ("photo.on.rectangle", "相册", #selector(albumTapped)),
            ("camera", "拍摄", #selector(cameraTapped)),
            ("doc", "文件", #selector(fileTapped)),
            ("location.fill", "位置", #selector(locationTapped)),
        ]
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.heightAnchor.constraint(equalToConstant: 100),
        ])
        for item in items {
            let btn = makeButton(icon: item.icon, title: item.title, action: item.action)
            stack.addArrangedSubview(btn)
        }
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
}
