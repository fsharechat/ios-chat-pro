# Plan J: 联系人列表(拼音索引) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现好友列表 + 拼音索引字母条,并把登录后的根导航结构从"单一会话列表"改为"Tab Bar(消息/联系人)";点击联系人进入与该好友的单聊。

**Architecture:** 不新增 SwiftPM target。`Sources/IMKit` 新增 `PinyinIndexer`(纯函数,用 iOS 原生 `applyingTransform` 做拼音转换,不引入第三方依赖)、`ContactRow`、`ContactListViewModel`;`App` 新增 `ContactListCell`、`ContactListViewController`(+ 一个小的 `UITableViewDiffableDataSource` 子类用来支持系统原生的字母索引条),并改造 `SceneDelegate.swift` 的根控制器为 `UITabBarController`。

**Tech Stack:** UIKit + Combine(已有),`String.applyingTransform(.toLatin/.stripDiacritics:)`(iOS 原生拼音转换 API)。

参考设计文档:`docs/superpowers/specs/2026-06-20-plan-j-contact-list-design.md`

---

## Task 1: `PinyinIndexer`

**Files:**
- Create: `Sources/IMKit/PinyinIndexer.swift`
- Test: `Tests/IMKitTests/PinyinIndexerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMKitTests/PinyinIndexerTests.swift
import XCTest
@testable import IMKit

final class PinyinIndexerTests: XCTestCase {
    func test_sectionLetter_englishName_returnsFirstLetterUppercased() {
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "alice"), "A")
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "Bob"), "B")
    }

    func test_sectionLetter_chineseName_returnsTransliteratedFirstLetter() {
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "张三"), "Z")
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "李雷"), "L")
    }

    func test_sectionLetter_nonLetterName_returnsHash() {
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "123"), "#")
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "👍"), "#")
    }

    func test_sectionLetter_emptyString_returnsHash() {
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: ""), "#")
    }

    func test_sectionLetter_alreadyLatinNameStartingWithDigit_findsFirstLetter() {
        // "starts with a letter somewhere" is the actual rule, not strictly
        // "first character is a letter" — a leading digit doesn't force "#"
        // if a real letter follows.
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "007zz"), "Z")
    }

    func test_sortKey_englishName_isLowercased() {
        XCTAssertEqual(PinyinIndexer.sortKey(for: "Alice"), "alice")
    }

    func test_sortKey_chineseName_startsWithLowercaseTransliteration() {
        XCTAssertTrue(PinyinIndexer.sortKey(for: "张三").hasPrefix("z"))
    }

    func test_sortKey_isDeterministic() {
        XCTAssertEqual(PinyinIndexer.sortKey(for: "张三"), PinyinIndexer.sortKey(for: "张三"))
    }
}
```

**Important note before implementing:** `applyingTransform(.toLatin:)`'s exact output formatting (spacing, capitalization) for Chinese text hasn't been empirically verified against this exact Swift toolchain/OS version yet — "张" (zhāng) and "李" (lǐ) are common, unambiguous surnames with no polyphone risk, so the FIRST-LETTER assertions above ("Z"/"L") are safe. If any single test fails after running once, print the actual raw value of `"张三".applyingTransform(.toLatin, reverse: false)` to a `print()` statement temporarily, observe the real output, and adjust ONLY that one assertion to match reality — don't change the implementation to work around a wrong expectation.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PinyinIndexerTests`
Expected: FAIL with `cannot find 'PinyinIndexer' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMKit/PinyinIndexer.swift
import Foundation

/// Converts a display name into an A-Z (or "#") section letter for the
/// contacts list's pinyin grouping/index sidebar, and a sort key for
/// ordering names within a section. Uses iOS's built-in Latin
/// transliteration (`applyingTransform(.toLatin:)`, backed by
/// `CFStringTransform`/`kCFStringTransformToLatin`) plus diacritic
/// stripping — no third-party pinyin library needed, unlike Android's
/// `pinyin4j`.
///
/// Accepted Phase-1 limitation: polyphonic Chinese characters (e.g. "重" can
/// be "chóng" or "zhòng") aren't guaranteed to match whichever reading
/// Android's `pinyin4j` would pick — this can make the same name sort under
/// a different letter than on Android. Sorting is still deterministic on
/// this platform: the same name always produces the same letter/key here.
public enum PinyinIndexer {
    public static func sectionLetter(for name: String) -> String {
        transliteratedFirstLetter(of: name) ?? "#"
    }

    public static func sortKey(for name: String) -> String {
        transliterate(name)?.lowercased() ?? name.lowercased()
    }

    private static func transliterate(_ name: String) -> String? {
        guard !name.isEmpty, let latin = name.applyingTransform(.toLatin, reverse: false) else { return nil }
        return latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    }

    private static func transliteratedFirstLetter(of name: String) -> String? {
        guard let latin = transliterate(name)?.uppercased(),
              let firstLetter = latin.first(where: { $0 >= "A" && $0 <= "Z" }) else { return nil }
        return String(firstLetter)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PinyinIndexerTests`
Expected: `Executed 8 tests, with 0 failures`

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests pass (245 + 8 = 253).

- [ ] **Step 6: Commit**

```bash
git add Sources/IMKit/PinyinIndexer.swift Tests/IMKitTests/PinyinIndexerTests.swift
git commit -m "feat(IMKit): add PinyinIndexer for contact list section grouping"
```

---

## Task 2: `ContactRow` + `ContactListViewModel`

**Files:**
- Create: `Sources/IMKit/ContactRow.swift`
- Create: `Sources/IMKit/ContactListViewModel.swift`
- Test: `Tests/IMKitTests/ContactListViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMKitTests/ContactListViewModelTests.swift
import XCTest
import Combine
import IMStorage
@testable import IMKit

final class ContactListViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var viewModel: ContactListViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        viewModel = ContactListViewModel(storage: storage)
    }

    private func waitForNonEmptySections() {
        guard viewModel.sections.isEmpty else { return }
        let expectation = expectation(description: "sections appear")
        expectation.assertForOverFulfill = false
        viewModel.$sections.dropFirst().sink { sections in if !sections.isEmpty { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)
    }

    func test_initialState_emptySections() {
        XCTAssertEqual(viewModel.sections.count, 0)
    }

    func test_singleEnglishNameFriend_groupedUnderItsFirstLetter() throws {
        try storage.users.upsert(StoredUser(uid: "u1", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        waitForNonEmptySections()

        XCTAssertEqual(viewModel.sections.map { $0.letter }, ["A"])
        XCTAssertEqual(viewModel.sections.first?.rows.map { $0.displayName }, ["Alice"])
    }

    func test_nonFriendUser_excludedFromSections() throws {
        try storage.users.upsert(StoredUser(uid: "u1", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: false))

        let expectation = expectation(description: "no sections appear")
        expectation.isInverted = true
        viewModel.$sections.dropFirst().sink { sections in if !sections.isEmpty { expectation.fulfill() } }.store(in: &cancellables)
        wait(for: [expectation], timeout: 0.5)

        XCTAssertTrue(viewModel.sections.isEmpty)
    }

    func test_multipleFriends_sortedAlphabeticallyBySection() throws {
        try storage.users.upsert(StoredUser(uid: "u1", name: nil, displayName: "Bob", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))
        try storage.users.upsert(StoredUser(uid: "u2", name: nil, displayName: "Alice", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))
        try storage.users.upsert(StoredUser(uid: "u3", name: nil, displayName: "Adam", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        let expectation = expectation(description: "all three settle")
        expectation.assertForOverFulfill = false
        viewModel.$sections.sink { sections in
            let total = sections.reduce(0) { $0 + $1.rows.count }
            if total == 3 { expectation.fulfill() }
        }.store(in: &cancellables)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(viewModel.sections.map { $0.letter }, ["A", "B"])
        XCTAssertEqual(viewModel.sections.first?.rows.map { $0.displayName }, ["Adam", "Alice"])
        XCTAssertEqual(viewModel.sections.last?.rows.map { $0.displayName }, ["Bob"])
    }

    func test_unresolvedFriendName_fallsBackToUidForGroupingAndDisplay() throws {
        try storage.users.upsert(StoredUser(uid: "zz9", name: nil, displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        waitForNonEmptySections()

        XCTAssertEqual(viewModel.sections.first?.rows.first?.displayName, "zz9")
        XCTAssertEqual(viewModel.sections.map { $0.letter }, ["Z"])
    }

    func test_nonLetterName_groupedUnderHash() throws {
        try storage.users.upsert(StoredUser(uid: "u1", name: nil, displayName: "123", portrait: nil, mobile: nil, gender: 0, updateDt: 0, isFriend: true))

        waitForNonEmptySections()

        XCTAssertEqual(viewModel.sections.map { $0.letter }, ["#"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ContactListViewModelTests`
Expected: FAIL with `cannot find 'ContactListViewModel' in scope`

- [ ] **Step 3: Implement**

```swift
// Sources/IMKit/ContactRow.swift
public struct ContactRow: Equatable, Hashable {
    public let uid: String
    public let displayName: String
    public let avatarURL: String?
    public let sectionLetter: String

    public init(uid: String, displayName: String, avatarURL: String?, sectionLetter: String) {
        self.uid = uid
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.sectionLetter = sectionLetter
    }
}
```

```swift
// Sources/IMKit/ContactListViewModel.swift
import Foundation
import Combine
import IMStorage

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ContactListViewModel {
    @Published public private(set) var sections: [(letter: String, rows: [ContactRow])] = []

    private let storage: IMStorage
    private var cancellable: AnyCancellable?

    public init(storage: IMStorage) {
        self.storage = storage
        cancellable = storage.users.friendsPublisher()
            .replaceError(with: [])
            .sink { [weak self] users in self?.handleFriendsUpdate(users) }
    }

    private func handleFriendsUpdate(_ users: [StoredUser]) {
        let rows = users.map { user -> ContactRow in
            let displayName = user.displayName ?? user.name ?? user.uid
            return ContactRow(
                uid: user.uid,
                displayName: displayName,
                avatarURL: user.portrait,
                sectionLetter: PinyinIndexer.sectionLetter(for: displayName)
            )
        }

        let grouped = Dictionary(grouping: rows, by: { $0.sectionLetter })
        let sortedLetters = grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        sections = sortedLetters.map { letter in
            let sortedRows = grouped[letter]!.sorted { PinyinIndexer.sortKey(for: $0.displayName) < PinyinIndexer.sortKey(for: $1.displayName) }
            return (letter: letter, rows: sortedRows)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ContactListViewModelTests`
Expected: all 6 tests pass.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests pass (253 + 6 = 259).

- [ ] **Step 6: Commit**

```bash
git add Sources/IMKit/ContactRow.swift Sources/IMKit/ContactListViewModel.swift Tests/IMKitTests/ContactListViewModelTests.swift
git commit -m "feat(IMKit): add ContactRow and ContactListViewModel"
```

---

## Task 3: `ContactListCell`

**Files:**
- Create: `App/ContactListCell.swift`

No automated tests — `App/` has no test target; verified by build only, same as every existing `App/*Cell.swift`.

- [ ] **Step 1: Create the cell**

```swift
// App/ContactListCell.swift
import UIKit
import IMKit

final class ContactListCell: UITableViewCell {
    static let reuseIdentifier = "ContactListCell"

    private let avatarImageView = AvatarImageView(loader: AvatarLoader())
    private let nameLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.backgroundSecondary
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutViews() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 16, weight: .regular)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarImageView)
        contentView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: 40),
            avatarImageView.heightAnchor.constraint(equalToConstant: 40),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            avatarImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    func configure(with row: ContactRow) {
        avatarImageView.setAvatar(urlString: row.avatarURL, displayName: row.displayName)
        nameLabel.text = row.displayName
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project and build**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`. `App/*.swift` uses an explicit file list in `project.pbxproj` — a new file here requires the regenerated pbxproj to be committed too.

- [ ] **Step 3: Commit**

```bash
git add App/ContactListCell.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add ContactListCell"
```

---

## Task 4: `ContactListViewController` (with native section-index sidebar)

**Files:**
- Create: `App/ContactListViewController.swift`

No automated tests — same rationale as Task 3.

- [ ] **Step 1: Create the data source subclass and view controller**

```swift
// App/ContactListViewController.swift
import UIKit
import Combine
import IMKit

/// `UITableViewDiffableDataSource` doesn't provide section headers or the
/// native A-Z index sidebar by default — both require overriding these
/// three `UITableViewDataSource` methods on a subclass (per Apple's
/// documented pattern for diffable data sources + index titles).
final class ContactListDataSource: UITableViewDiffableDataSource<String, ContactRow> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        snapshot().sectionIdentifiers[section]
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        let titles = snapshot().sectionIdentifiers
        return titles.isEmpty ? nil : titles
    }

    override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        snapshot().sectionIdentifiers.firstIndex(of: title) ?? 0
    }
}

final class ContactListViewController: UIViewController {
    private let viewModel: ContactListViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: ContactListDataSource!

    private let tableView = UITableView()

    /// Set by `SceneDelegate` — pushes the chat screen for the tapped contact.
    var onContactSelected: ((ContactRow) -> Void)?

    init(viewModel: ContactListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "联系人"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutTableView()
        configureDataSource()
        bindViewModel()
    }

    private func layoutTableView() {
        tableView.register(ContactListCell.self, forCellReuseIdentifier: ContactListCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorColor = Theme.backgroundTertiary
        tableView.sectionIndexColor = Theme.accent
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = ContactListDataSource(tableView: tableView) { tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: ContactListCell.reuseIdentifier, for: indexPath) as! ContactListCell
            cell.configure(with: row)
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.$sections
            .sink { [weak self] sections in self?.applySnapshot(sections: sections) }
            .store(in: &cancellables)
    }

    private func applySnapshot(sections: [(letter: String, rows: [ContactRow])]) {
        var snapshot = NSDiffableDataSourceSnapshot<String, ContactRow>()
        snapshot.appendSections(sections.map { $0.letter })
        for section in sections {
            snapshot.appendItems(section.rows, toSection: section.letter)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

extension ContactListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        onContactSelected?(row)
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project and build**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/ContactListViewController.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add ContactListViewController with native section-index sidebar"
```

---

## Task 5: Tab Bar wiring in `SceneDelegate`

**Files:**
- Modify: `Sources/IMKit/ConversationRow.swift`
- Modify: `App/SceneDelegate.swift`

- [ ] **Step 1: Give `ConversationRow` a public initializer**

`Sources/IMKit/ConversationRow.swift` currently has no explicit `init` — its auto-synthesized memberwise initializer is only `internal` (Swift never auto-generates a `public` memberwise init for a `public struct`, regardless of whether every property is `public`). Every existing `ConversationRow` is constructed from inside `IMKit` itself (`ConversationListViewModel.handleConversationsUpdate`), so this has never mattered before — but Step 2 below needs to construct one from `App/SceneDelegate.swift`, a different module, which requires an explicit `public init`.

Read the current `Sources/IMKit/ConversationRow.swift`, then replace its content with:

```swift
import IMStorage

public struct ConversationRow: Equatable, Hashable {
    public let conversationType: ConversationType
    public let target: String
    public let line: Int
    public let displayName: String
    public let avatarURL: String?
    public let previewText: String
    public let timestamp: Int64
    public let unreadCount: Int
    public let isTop: Bool
    public let isMuted: Bool
    public let lastMessageStatus: MessageStatus?

    public init(
        conversationType: ConversationType,
        target: String,
        line: Int,
        displayName: String,
        avatarURL: String?,
        previewText: String,
        timestamp: Int64,
        unreadCount: Int,
        isTop: Bool,
        isMuted: Bool,
        lastMessageStatus: MessageStatus?
    ) {
        self.conversationType = conversationType
        self.target = target
        self.line = line
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.previewText = previewText
        self.timestamp = timestamp
        self.unreadCount = unreadCount
        self.isTop = isTop
        self.isMuted = isMuted
        self.lastMessageStatus = lastMessageStatus
    }
}
```

Run `swift test` and confirm all 259 tests still pass (this is a purely additive change — every existing call site inside `IMKit` already passes arguments in this exact order/by-label, so the new explicit init doesn't change any existing behavior).

- [ ] **Step 2: Replace the root-controller logic**

Read the current `App/SceneDelegate.swift` first to confirm it still matches the content below (it was last touched in Plan I). Replace the entire file content with:

```swift
// App/SceneDelegate.swift
import UIKit
import AppCore
import IMStorage
import IMKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var environment: AppEnvironment!

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let storage: IMStorage
        do {
            storage = try IMStorage.open(atPath: AppEnvironment.defaultDatabasePath())
        } catch {
            // Phase 1 has no DB-corruption-recovery UX yet — fail loudly
            // rather than silently falling back to an in-memory store,
            // which would silently lose the user's message history with no
            // indication anything went wrong.
            fatalError("Failed to open local database: \(error)")
        }
        environment = AppEnvironment(storage: storage)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    private func rootViewController() -> UIViewController {
        environment.connectIfPossible() ? makeMainTabBarController() : makeLoginViewController()
    }

    /// Two tabs: conversations (default landing tab) and contacts. Both are
    /// independent `UINavigationController`s, matching the standard
    /// WeChat-style IM navigation shape — a later phase adding a third
    /// "我的" tab is a purely additive change here.
    private func makeMainTabBarController() -> UIViewController {
        let tabBarController = UITabBarController()

        let conversationListNav = makeConversationListNavigationController()
        conversationListNav.tabBarItem = UITabBarItem(title: "消息", image: UIImage(systemName: "message"), tag: 0)

        let contactListNav = makeContactListNavigationController()
        contactListNav.tabBarItem = UITabBarItem(title: "联系人", image: UIImage(systemName: "person.2"), tag: 1)

        tabBarController.viewControllers = [conversationListNav, contactListNav]
        return tabBarController
    }

    private func makeConversationListNavigationController() -> UIViewController {
        let viewModel = ConversationListViewModel(storage: environment.storage, contactSync: environment.contactSyncService)
        let listViewController = ConversationListViewController(viewModel: viewModel)
        listViewController.onConversationSelected = { [weak self, weak listViewController] row in
            guard let self else { return }
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
                target: row.target,
                conversationType: row.conversationType,
                line: row.line
            )
            listViewController?.navigationController?.pushViewController(
                ConversationViewController(row: row, viewModel: conversationViewModel),
                animated: true
            )
        }
        return UINavigationController(rootViewController: listViewController)
    }

    /// `ConversationViewController` requires a `ConversationRow` purely for
    /// its nav-bar title/avatar — it has no backing `StoredConversation` row
    /// yet the first time you message a brand-new contact (one gets created
    /// automatically by `MessagingService.sendText`'s first send). The
    /// placeholder fields below (`previewText`/`timestamp`/etc.) are never
    /// read by `ConversationViewController`, which only uses `displayName`
    /// for its title.
    private func makeContactListNavigationController() -> UIViewController {
        let viewModel = ContactListViewModel(storage: environment.storage)
        let listViewController = ContactListViewController(viewModel: viewModel)
        listViewController.onContactSelected = { [weak self, weak listViewController] row in
            guard let self else { return }
            let conversationViewModel = ConversationViewModel(
                storage: self.environment.storage,
                messageSending: self.environment.messagingService,
                imageUploading: self.environment.mediaUploadService,
                target: row.uid,
                conversationType: .single,
                line: 0
            )
            let conversationRow = ConversationRow(
                conversationType: .single,
                target: row.uid,
                line: 0,
                displayName: row.displayName,
                avatarURL: row.avatarURL,
                previewText: "",
                timestamp: 0,
                unreadCount: 0,
                isTop: false,
                isMuted: false,
                lastMessageStatus: nil
            )
            listViewController?.navigationController?.pushViewController(
                ConversationViewController(row: conversationRow, viewModel: conversationViewModel),
                animated: true
            )
        }
        return UINavigationController(rootViewController: listViewController)
    }

    private func makeLoginViewController() -> UIViewController {
        let viewModel = LoginViewModel(
            apiClient: LoginAPIClient(baseURL: environment.config.apiBaseURL),
            credentialsStore: environment.credentialsStore,
            deviceIdentifierProvider: environment.deviceIdentifierProvider
        )
        viewModel.onLoginSucceeded = { [weak self] _ in
            guard let self else { return }
            self.environment.connectIfPossible()
            self.window?.rootViewController = self.makeMainTabBarController()
        }
        return LoginViewController(viewModel: viewModel)
    }
}
```

The only changes from the current file: `rootViewController()`/`onLoginSucceeded` now call the new `makeMainTabBarController()` instead of `makeConversationListNavigationController()` directly, and two new methods (`makeMainTabBarController`, `makeContactListNavigationController`) are added. `makeConversationListNavigationController()` itself is unchanged.

- [ ] **Step 3: Regenerate the Xcode project and build**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/IMKit/ConversationRow.swift App/SceneDelegate.swift
git add -u ios-chat-pro.xcodeproj
git commit -m "feat(App): add a tab bar (conversations/contacts) as the post-login root controller"
```

---

## Task 6: End-to-end build/test verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full `swift test` suite**

```bash
swift test
```

Expected: all tests pass (259 from Tasks 1-2, no new SPM tests in Tasks 3-5 since those are `App/`-only UI files).

- [ ] **Step 2: Build the App target**

```bash
./Scripts/generate-xcodeproj.sh
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Simulator smoke test**

```bash
xcrun simctl boot "iPhone 15" 2>/dev/null || true
APP_PATH=$(find .build/xcode/Build/Products -name "App.app" -maxdepth 2 | head -1)
xcrun simctl install "iPhone 15" "$APP_PATH"
xcrun simctl launch "iPhone 15" com.fshare.ios-chat-pro.App
xcrun simctl io "iPhone 15" screenshot /tmp/plan-j-smoke-test.png
```

Manually confirm: the app launches into a tab bar with "消息"/"联系人" tabs; switching to "联系人" shows the friend list grouped by pinyin letter with a section-index sidebar on the right; tapping a contact pushes into the chat screen. This environment has repeatedly hit a `simctl install` hang in earlier plans — if it hangs again here, fall back to `swift test` + `xcodebuild` as the strongest available verification rather than re-litigating the known environment quirk.

No commit for this task — it's a verification gate, not new code.

---

## Plan Self-Review Notes

- **Spec coverage:** every section of `docs/superpowers/specs/2026-06-20-plan-j-contact-list-design.md` maps to a task — pinyin grouping (Task 1), ViewModel/row model (Task 2), UI (Tasks 3-4), navigation/Tab Bar (Task 5), verification (Task 6).
- **Out of scope, confirmed with user:** 好友请求("新的朋友")入口、群组/频道入口、搜索框、好友增删 — none of these are touched by any task above.
- **Pinyin approach:** iOS native `applyingTransform`, no third-party dependency, confirmed with user. Accepted polyphone-mismatch-vs-Android limitation documented in `PinyinIndexer`'s own doc comment.
- **Reused infrastructure, not duplicated:** `ContactListViewModel` reads `UserStore.friendsPublisher()` (Plan F, unchanged) and does no network calls of its own (Plan F's `ContactSyncService` already resolves friend profiles). `ContactListCell` reuses `AvatarImageView`/`AvatarLoader` (Plan G). Navigating to a contact's chat reuses `ConversationViewController`/`ConversationViewModel` verbatim (Plan I) — no new chat-screen code.
- **No placeholders:** every step has complete, runnable code; nothing is left as "TODO" or "similar to above."
