// App/GroupQRCodeViewController.swift
import UIKit
import CoreImage.CIFilterBuiltins
import IMKit

final class GroupQRCodeViewController: UIViewController {
    private let groupId: String
    private let groupName: String
    private let portraitURL: String?

    private let avatarView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()
    private let qrImageView = UIImageView()

    init(groupId: String, groupName: String, portraitURL: String?) {
        self.groupId = groupId
        self.groupName = groupName
        self.portraitURL = portraitURL
        super.init(nibName: nil, bundle: nil)
        title = "群二维码"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        layoutViews()
        avatarView.setAvatar(urlString: portraitURL, displayName: groupName)
        nameLabel.text = groupName
        qrImageView.image = generateQRCode(from: "group:\(groupId)")
    }

    private func layoutViews() {
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(avatarView)
        view.addSubview(nameLabel)
        view.addSubview(qrImageView)

        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            avatarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 72),
            avatarView.heightAnchor.constraint(equalToConstant: 72),

            nameLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            qrImageView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 32),
            qrImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: 200),
            qrImageView.heightAnchor.constraint(equalToConstant: 200),
        ])
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
