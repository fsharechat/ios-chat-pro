// App/MyQRCodeViewController.swift
import UIKit
import CoreImage
import IMKit

final class MyQRCodeViewController: UIViewController {
    private let uid: String
    private let qrImageView = UIImageView()
    private let captionLabel = UILabel()

    init(uid: String) {
        self.uid = uid
        super.init(nibName: nil, bundle: nil)
        title = "我的二维码"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        qrImageView.image = Self.makeQRCodeImage(content: QRCodeContent.userQRCodeString(uid: uid))
    }

    private func layoutViews() {
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.text = "扫一扫上面的二维码,加我为好友"
        captionLabel.font = .systemFont(ofSize: 14)
        captionLabel.textColor = Theme.textPrimary
        captionLabel.textAlignment = .center
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(qrImageView)
        view.addSubview(captionLabel)
        NSLayoutConstraint.activate([
            qrImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            qrImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            qrImageView.widthAnchor.constraint(equalToConstant: 240),
            qrImageView.heightAnchor.constraint(equalToConstant: 240),

            captionLabel.topAnchor.constraint(equalTo: qrImageView.bottomAnchor, constant: 16),
            captionLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            captionLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    private static func makeQRCodeImage(content: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
