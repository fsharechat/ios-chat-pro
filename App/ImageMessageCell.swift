// App/ImageMessageCell.swift
import UIKit

struct ImageBubbleData: Equatable {
    let thumbnail: Data?
    let isOutgoing: Bool
    let isUploading: Bool
    let isFailed: Bool
}

final class ImageMessageCell: UITableViewCell {
    static let reuseIdentifier = "ImageMessageCell"

    private let bubbleImageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let bubbleColumn = UIStackView()
    private let rowStack = UIStackView()
    private let spacer = UIView()

    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTapped = nil
        onRetryTapped = nil
    }

    private func layoutViews() {
        bubbleImageView.contentMode = .scaleAspectFill
        bubbleImageView.clipsToBounds = true
        bubbleImageView.layer.cornerRadius = Theme.bubbleCornerRadius
        bubbleImageView.backgroundColor = Theme.backgroundTertiary
        bubbleImageView.isUserInteractionEnabled = true
        bubbleImageView.translatesAutoresizingMaskIntoConstraints = false
        bubbleImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        bubbleImageView.addSubview(activityIndicator)

        retryButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        retryButton.tintColor = .systemRed
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        bubbleColumn.axis = .vertical
        bubbleColumn.addArrangedSubview(bubbleImageView)

        rowStack.axis = .horizontal
        rowStack.alignment = .bottom
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            bubbleImageView.widthAnchor.constraint(equalToConstant: 160),
            bubbleImageView.heightAnchor.constraint(equalToConstant: 160),

            activityIndicator.centerXAnchor.constraint(equalTo: bubbleImageView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: bubbleImageView.centerYAnchor),
        ])
    }

    func configure(with data: ImageBubbleData) {
        bubbleImageView.image = data.thumbnail.flatMap { UIImage(data: $0) }
        activityIndicator.isHidden = !data.isUploading
        if data.isUploading { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        retryButton.isHidden = !data.isFailed

        rowStack.arrangedSubviews.forEach { rowStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        retryButton.removeFromSuperview()

        if data.isOutgoing {
            rowStack.addArrangedSubview(spacer)
            if data.isFailed { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(bubbleColumn)
        } else {
            rowStack.addArrangedSubview(bubbleColumn)
            if data.isFailed { rowStack.addArrangedSubview(retryButton) }
            rowStack.addArrangedSubview(spacer)
        }
    }

    @objc private func tapped() { onTapped?() }
    @objc private func retryTapped() { onRetryTapped?() }
}
