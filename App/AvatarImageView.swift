// App/AvatarImageView.swift
import UIKit
import IMKit

/// Circular avatar view: shows a single-initial placeholder immediately,
/// then swaps in the real image once `AvatarLoader` resolves it.
/// Cell-reuse-safe: `setAvatar` generates a fresh token per call, and the
/// async load's completion checks the token is still current before
/// applying anything — a `UITableViewCell` can be reused for a different
/// row while a previous row's load is still in flight.
final class AvatarImageView: UIImageView {
    private let loader: AvatarLoading
    private var currentToken: UUID?
    private var currentURLString: String?
    private let initialsLabel = UILabel()

    init(loader: AvatarLoading) {
        self.loader = loader
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = Theme.backgroundTertiary

        initialsLabel.textAlignment = .center
        initialsLabel.textColor = Theme.textPrimary
        initialsLabel.font = .systemFont(ofSize: 16, weight: .medium)
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialsLabel)
        NSLayoutConstraint.activate([
            initialsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
    }

    func setAvatar(urlString: String?, displayName: String) {
        initialsLabel.text = String(displayName.prefix(1)).uppercased()

        // Reconfiguring with the same URL while the real image is already on
        // screen (e.g. a multi-select cell redrawn just to toggle its
        // checkmark) must not reset to the initials placeholder — that reset
        // is what flashes initials ↔ avatar.
        if urlString != nil, urlString == currentURLString, image != nil { return }

        let token = UUID()
        currentToken = token
        currentURLString = urlString
        image = nil
        initialsLabel.isHidden = false

        guard let urlString else { return }
        Task {
            let data = await loader.loadAvatarData(from: urlString)
            guard self.currentToken == token, let data, let uiImage = UIImage(data: data) else { return }
            self.image = uiImage
            self.initialsLabel.isHidden = true
        }
    }
}
