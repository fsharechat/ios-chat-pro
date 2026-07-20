// App/SearchMessageViewController.swift
import UIKit
import IMKit
import IMStorage

final class SearchMessageViewController: UIViewController {
    private let searcher: (String) -> [StoredMessage]
    private var results: [StoredMessage] = []

    private let searchBar = UISearchBar()
    private let tableView = UITableView()

    init(searcher: @escaping (String) -> [StoredMessage]) {
        self.searcher = searcher
        super.init(nibName: nil, bundle: nil)
        title = "查找聊天记录"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        searchBar.placeholder = "搜索"
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(SearchResultCell.self, forCellReuseIdentifier: SearchResultCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.tableHeaderView = nil
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func performSearch(keyword: String) {
        guard !keyword.isEmpty else {
            results = []
            tableView.reloadData()
            return
        }
        results = searcher(keyword)
        tableView.reloadData()
    }
}

extension SearchMessageViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        performSearch(keyword: searchText)
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

extension SearchMessageViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SearchResultCell.reuseIdentifier, for: indexPath) as! SearchResultCell
        cell.configure(with: results[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 60 }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

// MARK: - SearchResultCell

private final class SearchResultCell: UITableViewCell {
    static let reuseIdentifier = "SearchResultCell"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private let summaryLabel = UILabel()
    private let timeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        summaryLabel.font = .systemFont(ofSize: 14)
        summaryLabel.numberOfLines = 2
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = Theme.textSecondary
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(summaryLabel)
        contentView.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            summaryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 15),
            summaryLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -8),
            summaryLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -15),
            timeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 60),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with message: StoredMessage) {
        summaryLabel.text = message.searchableContent ?? ""
        let date = Date(timeIntervalSince1970: Double(message.timestamp) / 1000)
        timeLabel.text = SearchResultCell.dateFormatter.string(from: date)
    }
}
