// App/NavigationRowCell.swift
import UIKit

final class NavigationRowCell: UITableViewCell {
    static let reuseIdentifier = "NavigationRowCell"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var rightCustomView: UIView?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        titleLabel.font = .systemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = Theme.textSecondary
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 15),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            detailLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, detail: String? = nil, rightView: UIView? = nil) {
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = (detail == nil && rightView == nil)

        rightCustomView?.removeFromSuperview()
        rightCustomView = nil

        if let rv = rightView {
            accessoryType = .none
            rv.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(rv)
            NSLayoutConstraint.activate([
                rv.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -15),
                rv.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
            rightCustomView = rv
        } else {
            accessoryType = .disclosureIndicator
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rightCustomView?.removeFromSuperview()
        rightCustomView = nil
        accessoryType = .disclosureIndicator
        detailLabel.text = nil
    }
}
