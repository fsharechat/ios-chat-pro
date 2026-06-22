// App/SystemTipMessageCell.swift
import UIKit
import IMKit

final class SystemTipMessageCell: UITableViewCell {
    static let reuseIdentifier = "SystemTipMessageCell"

    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.textPrimary.withAlphaComponent(0.6)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),
        ])
    }

    func configure(with row: SystemTipRow) {
        label.text = row.text
    }
}
