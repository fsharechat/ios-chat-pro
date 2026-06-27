// App/ToggleSwitchCell.swift
import UIKit

final class ToggleSwitchCell: UITableViewCell {
    static let reuseIdentifier = "ToggleSwitchCell"

    var onToggle: ((Bool) -> Void)?

    private let titleLabel = UILabel()
    private let toggle = UISwitch()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.font = .systemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
        contentView.addSubview(titleLabel)
        contentView.addSubview(toggle)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 15),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -15),
            toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, isOn: Bool) {
        titleLabel.text = title
        toggle.isOn = isOn
    }

    @objc private func switchChanged() {
        onToggle?(toggle.isOn)
    }
}
