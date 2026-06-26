// App/TimeHeaderCell.swift
import UIKit

final class TimeHeaderCell: UITableViewCell {
    static let reuseIdentifier = "TimeHeaderCell"

    private let pill = UIView()
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
        pill.backgroundColor = UIColor(white: 0.5, alpha: 0.2)
        pill.layer.cornerRadius = 10
        pill.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11)
        label.textColor = UIColor(white: 0.35, alpha: 1)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(pill)
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            pill.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
        ])
    }

    func configure(with text: String) {
        label.text = text
    }
}
