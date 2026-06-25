// App/MyProfileViewController.swift
import UIKit
import Combine
import PhotosUI
import IMKit

final class MyProfileViewController: UIViewController {
    private enum Row: Int, CaseIterable {
        case displayName
        case qrCode
    }

    private let viewModel: MyProfileViewModel
    private let imageUploading: ImageUploading
    private var cancellables = Set<AnyCancellable>()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerView = UIView()
    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let changeAvatarLabel = UILabel()

    init(viewModel: MyProfileViewModel, imageUploading: ImageUploading) {
        self.viewModel = viewModel
        self.imageUploading = imageUploading
        super.init(nibName: nil, bundle: nil)
        title = "我的资料"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        bindViewModel()
    }

    private func layoutViews() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.isUserInteractionEnabled = true
        avatarImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(changeAvatarTapped)))

        changeAvatarLabel.text = "点击更换头像"
        changeAvatarLabel.font = .systemFont(ofSize: 12)
        changeAvatarLabel.textColor = .secondaryLabel
        changeAvatarLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(avatarImageView)
        headerView.addSubview(changeAvatarLabel)
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 24),
            avatarImageView.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 80),
            avatarImageView.heightAnchor.constraint(equalToConstant: 80),

            changeAvatarLabel.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 8),
            changeAvatarLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            changeAvatarLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -16),
        ])
        headerView.frame = CGRect(x: 0, y: 0, width: 0, height: 140)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.tableHeaderView = headerView
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard tableView.tableHeaderView?.frame.width != tableView.bounds.width else { return }
        headerView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 140)
        tableView.tableHeaderView = headerView
    }

    private func bindViewModel() {
        viewModel.$displayName
            .combineLatest(viewModel.$avatarURL)
            .sink { [weak self] displayName, avatarURL in
                guard let self else { return }
                self.avatarImageView.setAvatar(urlString: avatarURL, displayName: displayName)
                self.tableView.reloadRows(at: [IndexPath(row: Row.displayName.rawValue, section: 0)], with: .none)
            }
            .store(in: &cancellables)
    }

    @objc private func changeAvatarTapped() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func handlePickedAvatar(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        imageUploading.uploadImage(data) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    self?.viewModel.updatePortrait(url) { result in
                        if case .failure = result {
                            self?.presentResultAlert(title: "修改失败", message: "请稍后重试")
                        }
                    }
                case .failure:
                    self?.presentResultAlert(title: "上传失败", message: "请稍后重试")
                }
            }
        }
    }

    private func editDisplayNameTapped() {
        let alert = UIAlertController(title: "修改昵称", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] textField in
            textField.text = self?.viewModel.displayName
            textField.placeholder = "昵称"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self?.viewModel.updateDisplayName(name) { result in
                if case .failure = result {
                    self?.presentResultAlert(title: "修改失败", message: "请稍后重试")
                }
            }
        })
        present(alert, animated: true)
    }

    private func presentResultAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

extension MyProfileViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Row.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .value1, reuseIdentifier: "cell")
        switch Row(rawValue: indexPath.row)! {
        case .displayName:
            cell.textLabel?.text = "昵称"
            cell.detailTextLabel?.text = viewModel.displayName
            cell.accessoryType = .disclosureIndicator
        case .qrCode:
            cell.textLabel?.text = "我的二维码"
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row)! {
        case .displayName:
            editDisplayNameTapped()
        case .qrCode:
            navigationController?.pushViewController(MyQRCodeViewController(uid: viewModel.myUid), animated: true)
        }
    }
}

extension MyProfileViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async { self?.handlePickedAvatar(image) }
        }
    }
}
