// App/GroupNoticeViewController.swift
import UIKit

final class GroupNoticeViewController: UIViewController {
    private let initialNotice: String?
    private let canEdit: Bool
    private let textView = UITextView()
    private var isShowingPlaceholder: Bool = false

    init(notice: String?, canEdit: Bool) {
        self.initialNotice = notice
        self.canEdit = canEdit
        super.init(nibName: nil, bundle: nil)
        title = "群公告"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.font = .systemFont(ofSize: 16)
        textView.text = initialNotice?.isEmpty == false ? initialNotice : "暂无公告"
        textView.textColor = initialNotice?.isEmpty == false ? .label : .secondaryLabel
        isShowingPlaceholder = !(initialNotice?.isEmpty == false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        if canEdit {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "编辑", style: .plain, target: self, action: #selector(editTapped))
        }
    }

    @objc private func editTapped() {
        if textView.isEditable {
            textView.isEditable = false
            textView.resignFirstResponder()
            navigationItem.rightBarButtonItem?.title = "编辑"
        } else {
            if isShowingPlaceholder {
                textView.text = ""
                textView.textColor = .label
                isShowingPlaceholder = false
            }
            textView.isEditable = true
            textView.becomeFirstResponder()
            navigationItem.rightBarButtonItem?.title = "完成"
        }
    }
}
