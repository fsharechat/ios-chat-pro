// App/ConversationViewController.swift
import UIKit
import QuickLook
import Photos
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import AVKit
import Combine
import IMKit

final class ConversationViewController: UIViewController {
    private let row: ConversationRow
    private let viewModel: ConversationViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, ChatMessageRow>!
    private let fileDownloadManager = FileDownloadManager()
    private var previewURL: URL?
    private var audioPlayer: AVAudioPlayer?
    private var voicePlayer: AVPlayer?
    private var currentPlaybackTempURL: URL?
    private weak var currentPlayingCell: VoiceMessageCell?
    /// Maps filename stem (e.g. "voice-1234567890") → local M4A URL for
    /// outgoing voice messages recorded this session. Lets iOS play back its
    /// own recordings without needing to decode the uploaded AMR file.
    private static var localVoiceM4ACache: [String: URL] = [:]

    private let tableView = UITableView()
    private let refreshControl = UIRefreshControl()
    private let inputBar = MessageInputBar()
    private var inputBarBottomConstraint: NSLayoutConstraint!
    private var previousRawRows: [ChatMessageRow] = []
    private var tableReady = false
    /// 流式输出完成后保持全文展开的消息(占位行被真实消息替换时继承),
    /// 用户点"收起"后移除,回到普通的缩略+查看全文形态。
    private var expandedMessageIds: Set<Int64> = []
    /// 正处于选字状态的文本气泡及其菜单；菜单关闭时清空。
    private weak var selectingTextCell: TextMessageCell?
    private weak var selectionMenu: PlusMenuView?
    /// 每次进入选字自增。旧菜单的关闭动画晚于新一次选字结束时，凭它认出自己已过期，
    /// 不去清掉新的选区。
    private var selectionSession = 0
    /// 选字状态下点列表任意处退出选字。它要先于气泡自己的点按（打开链接、看图等）识别，
    /// 所以单独一个手势、只在选字时启用。
    private lazy var selectionDismissTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectionDismissTapped))
        tap.delegate = self
        tap.isEnabled = false
        return tap
    }()
    /// done 占位行阶段就被用户手动收起的流——替换后的真实消息不再展开。
    private var collapsedDoneStreamIds: Set<String> = []
    /// UIRefreshControl fires .valueChanged mid-drag, the moment the pull
    /// crosses the threshold. Loading then would prepend rows while the pan
    /// gesture still owns contentOffset, so the keep-position adjustment in
    /// applySnapshot gets overwritten every frame. Instead we only note the
    /// request here and start the real load on finger lift.
    private var pendingHistoryRefresh = false
    private var isLoadingHistory = false

    var onGroupInfoTapped: (() -> Void)?
    var onContactInfoTapped: (() -> Void)?
    var onCallTapped: ((_ audioOnly: Bool) -> Void)?
    /// Set by SceneDelegate. Called each time the user initiates a forward to
    /// produce a fresh ConversationListViewModel for the picker screen.
    var forwardViewModelFactory: (() -> ConversationListViewModel)?

    init(row: ConversationRow, viewModel: ConversationViewModel) {
        self.row = row
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = row.displayName
        // Push as full-screen: hides the tab bar so the chat owns the whole screen.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 首次 viewWillAppear 不做任何数据库/行重建工作——VM init 刚同步建完
    /// 全部行,此时 push 动画正要开始,任何主线程开销都会直接变成转场卡顿。
    /// 从资料页等下级页面返回时(hasAppearedOnce)才需要 reprocess:期间
    /// 「显示群成员昵称」开关或用户资料可能已变化。
    private var hasAppearedOnce = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.markActive()
        if hasAppearedOnce {
            viewModel.reprocessMessages()
        }
    }

    /// clearUnread 是同步写事务(DatabaseQueue 串行,可能被后台入库阻塞),
    /// 挪到转场动画完成后执行,不挡首帧;markActive 已保证期间到达的新消息
    /// 不计未读,晚清几百毫秒无感知差异。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppearedOnce = true
        viewModel.clearUnread()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 离开(pop、push 出资料页等)即恢复计数;回来时 viewWillAppear
        // 会重新标记并 clearUnread,覆盖期间产生的未读。
        viewModel.markInactive()
    }


    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundPrimary
        layoutViews()
        configureDataSource()
        bindViewModel()
        bindInputBar()
        observeKeyboard()

        // Right-side info button (person icon for single, group icon for group)
        let infoIconName = row.conversationType == .group ? "person.2.fill" : "person.fill"
        let infoItem = UIBarButtonItem(
            image: UIImage(systemName: infoIconName),
            style: .plain, target: self, action: #selector(infoTapped)
        )

        // 音视频通话入口在输入框 "+" 扩展面板里(仅单聊,见 bindInputBar),
        // 导航栏只保留信息按钮。
        navigationItem.rightBarButtonItems = [infoItem]
    }

    @objc private func infoTapped() {
        if row.conversationType == .group {
            onGroupInfoTapped?()
        } else {
            onContactInfoTapped?()
        }
    }

    @objc private func messageAreaTapped() {
        inputBar.collapseInput()
    }

    @objc private func refreshTriggered() {
        if tableView.isDragging {
            pendingHistoryRefresh = true
        } else {
            startHistoryLoad()
        }
    }

    private func startHistoryLoad() {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        viewModel.loadMoreHistory { [weak self] in
            guard let self else { return }
            self.isLoadingHistory = false
            // One hop later than the rows sink, so the prepend snapshot (and
            // its contentOffset restoration) is applied before the refresh
            // control's inset-collapse animation starts.
            DispatchQueue.main.async { self.refreshControl.endRefreshing() }
        }
    }

    private func layoutViews() {
        tableView.register(TextMessageCell.self, forCellReuseIdentifier: TextMessageCell.reuseIdentifier)
        tableView.register(ImageMessageCell.self, forCellReuseIdentifier: ImageMessageCell.reuseIdentifier)
        tableView.register(VideoMessageCell.self, forCellReuseIdentifier: VideoMessageCell.reuseIdentifier)
        tableView.register(VoiceMessageCell.self, forCellReuseIdentifier: VoiceMessageCell.reuseIdentifier)
        tableView.register(FileMessageCell.self, forCellReuseIdentifier: FileMessageCell.reuseIdentifier)
        tableView.register(LocationMessageCell.self, forCellReuseIdentifier: LocationMessageCell.reuseIdentifier)
        tableView.register(SystemTipMessageCell.self, forCellReuseIdentifier: SystemTipMessageCell.reuseIdentifier)
        tableView.register(TimeHeaderCell.self, forCellReuseIdentifier: TimeHeaderCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorStyle = .none
        // Pull-to-top + release loads older history — the iOS counterpart of
        // Android's SwipeRefreshLayout.setOnRefreshListener(loadMoreOldMessages).
        refreshControl.addTarget(self, action: #selector(refreshTriggered), for: .valueChanged)
        tableView.refreshControl = refreshControl
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.alpha = 0
        // 点消息区域收起键盘/面板；cancelsTouchesInView 保持 false，
        // 气泡上的点按（看图、播放语音等）不受影响。
        let tap = UITapGestureRecognizer(target: self, action: #selector(messageAreaTapped))
        tap.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tap)
        tableView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(messageLongPressed(_:))))
        tableView.addGestureRecognizer(selectionDismissTap)
        tableView.keyboardDismissMode = .onDrag

        inputBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(inputBar)

        inputBarBottomConstraint = inputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBarBottomConstraint,
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, ChatMessageRow>(tableView: tableView) { [weak self] tableView, indexPath, row in
            switch row {
            case .message(let message) where message.text?.hasPrefix("[语音]") == true:
                let cell = tableView.dequeueReusableCell(withIdentifier: VoiceMessageCell.reuseIdentifier, for: indexPath) as! VoiceMessageCell
                let engine = self?.viewModel.transcripts
                let entry = engine?.entry(for: message.messageUid)
                let showPill = engine.map {
                    VoiceTranscriptRules.showPill(isIncoming: !message.isOutgoing, isPlayed: message.status == .played,
                                                  messageUid: message.messageUid, entry: entry, auto: $0.isAutoTranscribe)
                } ?? false
                cell.configure(with: message, transcript: entry, showPill: showPill)
                cell.onTapped = { [weak self, weak cell] in
                    self?.viewModel.markPlayed(row: message)
                    self?.playVoice(urlString: message.imageRemoteURL, cell: cell)
                }
                cell.onTranscribeTapped = { [weak self] in self?.transcribe(message) }
                cell.onTranscriptRetryTapped = { [weak self] in self?.viewModel.transcripts?.request(message.messageUid) }
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onAvatarLongPressed = { [weak self] in self?.insertMentionFromAvatar(message) }
                return cell
            case .message(let message) where message.fileName != nil:
                let cell = tableView.dequeueReusableCell(withIdentifier: FileMessageCell.reuseIdentifier, for: indexPath) as! FileMessageCell
                cell.configure(with: message, state: self?.fileDownloadManager.state(for: message) ?? .notDownloaded)
                cell.onTapped = { [weak self] in self?.handleFileTap(message: message) }
                cell.onAvatarLongPressed = { [weak self] in self?.insertMentionFromAvatar(message) }
                return cell
            case .message(let message) where message.locationLat != nil:
                let cell = tableView.dequeueReusableCell(withIdentifier: LocationMessageCell.reuseIdentifier, for: indexPath) as! LocationMessageCell
                cell.configure(with: LocationBubbleData(
                    thumbnail: message.imageThumbnail,
                    title: message.text ?? "",
                    isOutgoing: message.isOutgoing,
                    senderDisplayName: message.senderDisplayName,
                    senderAvatarURL: message.senderAvatarURL
                ))
                cell.onTapped = { [weak self] in
                    guard let lat = message.locationLat, let lng = message.locationLng else { return }
                    self?.presentLocationPreview(lat: lat, lng: lng, title: message.text ?? "位置")
                }
                cell.onAvatarLongPressed = { [weak self] in self?.insertMentionFromAvatar(message) }
                return cell
            case .message(let message) where message.text != nil:
                let cell = tableView.dequeueReusableCell(withIdentifier: TextMessageCell.reuseIdentifier, for: indexPath) as! TextMessageCell
                // 刚结束的流式消息保持全文展开,"收起"后回到缩略+查看全文。
                let expanded = self?.expandedMessageIds.contains(message.storageId) ?? false
                cell.configure(with: message, displayMode: expanded ? .fullText(showCollapse: true) : .folded)
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onExpandTapped = { [weak self] in
                    guard let self else { return }
                    if expanded {
                        self.expandedMessageIds.remove(message.storageId)
                        self.reloadRow(row)
                    } else {
                        guard let text = message.text else { return }
                        self.navigationController?.pushViewController(TextPreviewViewController(text: text), animated: true)
                    }
                }
                cell.onAvatarLongPressed = { [weak self] in self?.insertMentionFromAvatar(message) }
                cell.onLinkTapped = { url in UIApplication.shared.open(url) }
                return cell
            case .message(let message) where message.videoDuration != nil:
                let cell = tableView.dequeueReusableCell(withIdentifier: VideoMessageCell.reuseIdentifier, for: indexPath) as! VideoMessageCell
                cell.configure(with: VideoBubbleData(thumbnail: message.imageThumbnail, duration: message.videoDuration ?? 0, isOutgoing: message.isOutgoing, isUploading: message.status == .sending, isFailed: message.status == .sendFailure, senderDisplayName: message.senderDisplayName, senderAvatarURL: message.senderAvatarURL))
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onTapped = { [weak self] in self?.presentVideoPlayer(urlString: message.imageRemoteURL) }
                cell.onAvatarLongPressed = { [weak self] in self?.insertMentionFromAvatar(message) }
                return cell
            case .message(let message):
                let cell = tableView.dequeueReusableCell(withIdentifier: ImageMessageCell.reuseIdentifier, for: indexPath) as! ImageMessageCell
                cell.configure(with: ImageBubbleData(thumbnail: message.imageThumbnail, remoteURL: message.imageRemoteURL, isOutgoing: message.isOutgoing, isUploading: message.status == .sending, isFailed: message.status == .sendFailure, senderDisplayName: message.senderDisplayName, senderAvatarURL: message.senderAvatarURL))
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onTapped = { [weak self] in self?.presentImageGallery(from: row) }
                cell.onAvatarLongPressed = { [weak self] in self?.insertMentionFromAvatar(message) }
                return cell
            case .pendingImage(let pending):
                let cell = tableView.dequeueReusableCell(withIdentifier: ImageMessageCell.reuseIdentifier, for: indexPath) as! ImageMessageCell
                cell.configure(with: ImageBubbleData(thumbnail: pending.thumbnail, isOutgoing: true, isUploading: pending.state == .uploading, isFailed: pending.state == .failed))
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onTapped = { [weak self] in self?.presentImageGallery(from: row) }
                return cell
            case .pendingVideo(let pending):
                let cell = tableView.dequeueReusableCell(withIdentifier: VideoMessageCell.reuseIdentifier, for: indexPath) as! VideoMessageCell
                cell.configurePending(pending)
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                return cell
            case .pendingVoice(let pending):
                let cell = tableView.dequeueReusableCell(withIdentifier: VoiceMessageCell.reuseIdentifier, for: indexPath) as! VoiceMessageCell
                cell.configurePending(pending)
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                return cell
            case .streaming(let streamingRow):
                let cell = tableView.dequeueReusableCell(withIdentifier: TextMessageCell.reuseIdentifier, for: indexPath) as! TextMessageCell
                // 复用 TextMessageCell:拼一个未入库的合成行,流式中尾部带 ▌ 光标
                //(对齐 Android TextMessageContentViewHolder 的 displayText)。
                // 流式输出全程不折叠(产品要求新增文字始终可见);done 后给
                // "收起",点击回到普通的缩略+查看全文形态。
                let manuallyCollapsed = self?.collapsedDoneStreamIds.contains(streamingRow.streamId) ?? false
                let displayMode: TextMessageCell.TextDisplayMode =
                    manuallyCollapsed ? .folded : .fullText(showCollapse: streamingRow.done)
                cell.configure(with: StoredMessageRow(
                    storageId: -1,
                    localMessageId: -1,
                    isOutgoing: false,
                    status: .unread,
                    timestamp: 0,
                    text: streamingRow.done ? streamingRow.text : streamingRow.text + "▌",
                    imageThumbnail: nil,
                    imageRemoteURL: nil,
                    senderAvatarURL: streamingRow.senderAvatarURL
                ), displayMode: displayMode)
                cell.setWaitingCursorBlink(!streamingRow.done && streamingRow.text.isEmpty)
                if streamingRow.done, !manuallyCollapsed {
                    cell.onExpandTapped = { [weak self] in
                        self?.collapsedDoneStreamIds.insert(streamingRow.streamId)
                        self?.reloadRow(row)
                    }
                } else {
                    cell.onExpandTapped = { [weak self] in
                        self?.navigationController?.pushViewController(TextPreviewViewController(text: streamingRow.text), animated: true)
                    }
                }
                cell.onLinkTapped = { url in UIApplication.shared.open(url) }
                return cell
            case .systemTip(let tip):
                let cell = tableView.dequeueReusableCell(withIdentifier: SystemTipMessageCell.reuseIdentifier, for: indexPath) as! SystemTipMessageCell
                cell.configure(with: tip)
                return cell
            case .timeHeader(let text, _):
                let cell = tableView.dequeueReusableCell(withIdentifier: TimeHeaderCell.reuseIdentifier, for: indexPath) as! TimeHeaderCell
                cell.configure(with: text)
                return cell
            }
        }
    }

    /// 点「转文字」视为已读：消红点
    private func transcribe(_ message: StoredMessageRow) {
        viewModel.markPlayed(row: message)
        viewModel.transcripts?.request(message.messageUid)
    }

    /// 转文字结果变化时只重配对应气泡（ChatMessageRow 本身未变，diffable 不会自动刷新）
    private func reconfigureVoiceRow(messageUid: Int64) {
        var snapshot = dataSource.snapshot()
        let targets = snapshot.itemIdentifiers.filter {
            if case .message(let m) = $0 { return m.messageUid == messageUid }
            return false
        }
        guard !targets.isEmpty else { return }
        snapshot.reconfigureItems(targets)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func bindViewModel() {
        viewModel.$rows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rows in self?.applySnapshot(rows: rows) }
            .store(in: &cancellables)
        viewModel.transcripts?.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uid in self?.reconfigureVoiceRow(messageUid: uid) }
            .store(in: &cancellables)
    }

    /// 展开/收起切换时就地重建单行:行值本身没变(展开态存在 VC 而非行里),
    /// diffable 不会自己刷新,需要显式 reload。
    private func reloadRow(_ row: ChatMessageRow) {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(row) else { return }
        snapshot.reloadItems([row])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Distinguishes three update shapes so scroll position behaves
    /// sensibly: a prepend (loaded older history — keep the user's current
    /// reading position by offsetting `contentOffset` by the inserted
    /// height), an append (a new message arrived — scroll to the bottom),
    /// or an in-place update elsewhere (e.g. an ack status flip — whether on
    /// the last row or any other — leave scroll position untouched). Append
    /// detection compares row *identity*, not full equality, so a status
    /// flip on the last row (same message, new value) isn't mistaken for a
    /// new row being appended.
    private func applySnapshot(rows: [ChatMessageRow]) {
        let oldRows = previousRawRows
        let isPrepend = !oldRows.isEmpty && rows.count > oldRows.count && Array(rows.suffix(oldRows.count)) == oldRows
        let isAppend = Self.rowIdentity(rows.last) != Self.rowIdentity(oldRows.last)
        // 流式增量:同一占位行原地长文本,始终跟底(产品要求:输出过程
        // 中不管多长都保持最新内容可见)。
        let isStreamingUpdate: Bool = {
            guard !isAppend, case .streaming = rows.last else { return false }
            return rows.last != oldRows.last
        }()
        // 流式占位被真实消息替换:若用户未在 done 阶段手动收起,替换后的
        // 消息继承"全文展开"形态,直到用户点"收起"。
        if case .streaming(let oldStream) = oldRows.last,
           !rows.contains(where: { if case .streaming = $0 { return true }; return false }) {
            if !collapsedDoneStreamIds.contains(oldStream.streamId),
               let replacement = rows.last(where: { if case .message(let m) = $0, !m.isOutgoing { return true }; return false }),
               case .message(let replacementRow) = replacement {
                expandedMessageIds.insert(replacementRow.storageId)
            }
            collapsedDoneStreamIds.remove(oldStream.streamId)
        }
        previousRawRows = rows

        let displayRows = injectTimeHeaders(rows)
        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatMessageRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(displayRows, toSection: 0)
        if isPrepend {
            applyPreservingReadingPosition(snapshot, anchor: oldRows.first)
            return
        }
        // 微信风格：新消息（发出或收到）直接落到底部，状态翻转原地刷新，
        // 一律不带插入/切换动画。
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            if isAppend {
                if !self.tableReady {
                    // Force layout so self-sizing cells compute correct contentSize
                    // before the first scroll, then reveal the table in one shot.
                    self.view.layoutIfNeeded()
                    self.tableReady = true
                }
                self.scrollToBottom(animated: false)
                self.tableView.alpha = 1
            } else if isStreamingUpdate {
                self.scrollToBottom(animated: false)
            }
        }
    }

    /// Applies a snapshot that prepends older history while keeping the
    /// user's reading position. Anchors on the previously-oldest row: capture
    /// where it sits on screen, apply, force layout, then scroll it back to
    /// that exact spot — all synchronously within one frame. A contentSize
    /// delta can't do this reliably: with self-sizing cells a large
    /// non-animated apply rebuilds layout from *estimated* heights, so
    /// "after minus before" compares two incommensurable numbers (on device
    /// this overshot by the height of everything already loaded, teleporting
    /// the view near the bottom), and a completion-based adjustment lands a
    /// frame late, flashing the unpositioned prepended rows first.
    private func applyPreservingReadingPosition(
        _ snapshot: NSDiffableDataSourceSnapshot<Int, ChatMessageRow>,
        anchor: ChatMessageRow?
    ) {
        var anchorScreenY: CGFloat?
        if let anchor, let path = dataSource.indexPath(for: anchor) {
            anchorScreenY = tableView.rectForRow(at: path).minY - tableView.contentOffset.y
        }
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            tableView.layoutIfNeeded()
            guard let anchor, let screenY = anchorScreenY,
                  let newPath = dataSource.indexPath(for: anchor) else { return }
            let target = tableView.rectForRow(at: newPath).minY - screenY
            let minOffset = -tableView.adjustedContentInset.top
            tableView.setContentOffset(CGPoint(x: 0, y: max(target, minOffset)), animated: false)
        }
    }

    private func injectTimeHeaders(_ rows: [ChatMessageRow]) -> [ChatMessageRow] {
        let threshold: Int64 = 5 * 60 * 1000
        var result: [ChatMessageRow] = []
        var lastTimestamp: Int64? = nil
        for row in rows {
            guard let ts = row.timestamp else {
                result.append(row)
                continue
            }
            if let last = lastTimestamp, ts - last < threshold {
                result.append(row)
            } else {
                // anchorId makes the header globally unique even when two gaps
                // produce identical formatted time strings.
                let anchorId = row.storageId ?? ts
                result.append(.timeHeader(Self.formatMessageTime(ts), anchorId))
                result.append(row)
            }
            lastTimestamp = ts
        }
        return result
    }

    /// DateFormatter 创建成本高(首次数毫秒级),而 injectTimeHeaders 在每次
    /// 快照应用时都会格式化多个时间头——三个格式各建一次复用。仅主线程访问,
    /// 与本类其余部分同一线程契约,无需加锁。
    private static let hourMinuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()
    private static let yearMonthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    private static func formatMessageTime(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: date)
        let period: String
        switch hour {
        case 0..<6:  period = "凌晨"
        case 6..<12: period = "早上"
        case 12:     period = "中午"
        case 13..<18: period = "下午"
        default:     period = "晚上"
        }
        let timeStr = hourMinuteFormatter.string(from: date)
        if calendar.isDateInToday(date) {
            return "\(period) \(timeStr)"
        } else if calendar.isDateInYesterday(date) {
            return "昨天 \(period) \(timeStr)"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let weekday = calendar.component(.weekday, from: date) - 1
            return "\(weekdays[weekday]) \(period) \(timeStr)"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(monthDayFormatter.string(from: date)) \(period) \(timeStr)"
        } else {
            return "\(yearMonthDayFormatter.string(from: date)) \(period) \(timeStr)"
        }
    }

    /// Identifies a row by its underlying message/upload identity, ignoring
    /// any other field (e.g. `status`). Used to tell "the last row changed
    /// because a new one was appended" (identity differs) apart from "the
    /// last row is still the same message, just updated in place" (identity
    /// unchanged) — `Equatable` alone can't make that distinction since an
    /// in-place status flip changes the row's value but not its identity.
    private static func rowIdentity(_ row: ChatMessageRow?) -> String? {
        switch row {
        case .message(let message): return "message-\(message.storageId)"
        case .pendingImage(let pending): return "pending-\(pending.id)"
        case .pendingVideo(let pending): return "pendingVideo-\(pending.id)"
        case .pendingVoice(let pending): return "pendingVoice-\(pending.id)"
        case .systemTip(let tip): return "systemTip-\(tip.storageId)"
        case .timeHeader(let text, let anchorId): return "timeHeader-\(anchorId)-\(text)"
        case .streaming(let streamingRow): return "streaming-\(streamingRow.streamId)"
        case nil: return nil
        }
    }

    /// cell 分派 switch 兜底到 ImageMessageCell 的判定条件（非语音/文件/位置/
    /// 文本/视频消息）。configureDataSource 里的 switch 依次用 where 子句排除
    /// 语音（"[语音]" 前缀）、文件（"[文件]" 前缀）、位置（locationLat != nil）、
    /// 文本（text != nil）、视频（videoDuration != nil），落到最后一个无 where
    /// 的 .message case 即为图片消息——那个兜底分支就是本方法条件的逻辑补集，
    /// 是 switch 自身已经保证的权威定义，不需要（也不能）反过来调用本方法。
    /// presentImageGallery 复用同一判定，避免两处独立维护而在未来新增消息类型
    /// 时静默失配。
    private static func isImageMessage(_ message: StoredMessageRow) -> Bool {
        message.text == nil && message.videoDuration == nil && message.locationLat == nil
    }

    private func scrollToBottom(animated: Bool) {
        let rowCount = dataSource.snapshot().itemIdentifiers.count
        guard rowCount > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: rowCount - 1, section: 0), at: .bottom, animated: animated)
    }

    private func bindInputBar() {
        inputBar.onSendText = { [weak self] text, mentionedType, mentionedTargets in
            self?.viewModel.sendText(text, mentionedType: Int(mentionedType), mentionedTargets: mentionedTargets)
        }
        inputBar.onPickImage = { [weak self] in self?.presentImagePicker() }
        inputBar.onCamera = { [weak self] in self?.presentCamera() }
        inputBar.onPickFile = { [weak self] in self?.presentFilePicker() }
        inputBar.showsCallItems = row.conversationType == .single
        inputBar.onAudioCall = { [weak self] in self?.onCallTapped?(true) }
        inputBar.onVideoCall = { [weak self] in self?.onCallTapped?(false) }
        inputBar.onPickLocation = { [weak self] in
            guard let self else { return }
            let picker = LocationPickerViewController()
            picker.onPicked = { [weak self] lat, lng, title, thumbnail in
                self?.viewModel.sendLocation(lat: lat, lng: lng, title: title, thumbnail: thumbnail)
            }
            let nav = AppNavigationController(rootViewController: picker)
            nav.modalPresentationStyle = .fullScreen
            self.present(nav, animated: true)
        }
        inputBar.onSendVoice = { [weak self] audioData, duration, fileName, localM4AURL in
            if let localM4AURL {
                let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
                Self.localVoiceM4ACache[stem] = localM4AURL
            }
            self?.viewModel.sendVoice(audioData: audioData, duration: duration, fileName: fileName)
        }
        inputBar.onMentionTriggered = { [weak self] in self?.presentMentionPicker() }
        inputBar.onPanelShown = { [weak self] in self?.scrollToBottom(animated: true) }
    }

    private func presentMentionPicker() {
        // presentedViewController 防重入：removeTrailingMentionTrigger 会走
        // textViewDidChange，若删 "@" 后文本仍以 "@" 结尾（如粘贴 "@@"），
        // 会在 dismiss 进行中再次触发到这里。
        guard row.conversationType == .group, presentedViewController == nil else { return }
        let picker = MentionPickerViewController(members: viewModel.groupMemberCandidatesForMention())
        picker.onPicked = { [weak self] uid, displayName in
            // 用户敲的触发 "@" 还留在输入框里，先删掉再插入完整的
            // "@昵称 "，否则会出现 "@@昵称"。
            self?.inputBar.removeTrailingMentionTrigger()
            self?.inputBar.insertMention(uid: uid, displayName: displayName)
            self?.dismiss(animated: true)
        }
        picker.onCancelled = { [weak self] in self?.inputBar.removeTrailingMentionTrigger() }
        present(AppNavigationController(rootViewController: picker), animated: true)
    }

    /// 长按对方头像插入 @（对齐 Android）：仅群聊、仅接收方向生效 ——
    /// 自己发的消息 senderUid 为 nil，长按没有任何动作。
    private func insertMentionFromAvatar(_ message: StoredMessageRow) {
        guard row.conversationType == .group, let uid = message.senderUid else { return }
        // 长按确认的触感提醒——放在 guard 之后，只在真正插入 @ 时震动。
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // 行内昵称可能因「显示群成员昵称」开关关闭而为 nil，从 mention
        // 候选里兜底解析，再不行退回 uid。
        let displayName = message.senderDisplayName
            ?? viewModel.groupMemberCandidatesForMention().first(where: { $0.uid == uid })?.displayName
            ?? uid
        inputBar.insertMention(uid: uid, displayName: displayName)
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let camera = CameraCaptureViewController()
        camera.modalPresentationStyle = .fullScreen
        camera.onImage = { [weak self] image in self?.handlePickedImage(image) }
        camera.onVideo = { [weak self] url in self?.handlePickedVideo(at: url) }
        present(camera, animated: true)
    }

    private func presentFilePicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .pdf, .text, .image])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func presentImagePicker() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func handlePickedImage(_ image: UIImage) {
        guard let thumbnail = Self.makeThumbnailData(image),
              let fullImageData = image.jpegData(compressionQuality: 0.9) else { return }
        viewModel.sendImage(fullImageData: fullImageData, thumbnail: thumbnail)
    }

    private func handlePickedVideo(at url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let asset = AVAsset(url: url)
            let durationSeconds = Int(CMTimeGetSeconds(asset.duration).rounded())

            let thumbnailData: Data?
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                let uiImage = UIImage(cgImage: cgImage)
                thumbnailData = Self.makeThumbnailData(uiImage)
            } else {
                thumbnailData = nil
            }

            guard let videoData = try? Data(contentsOf: url) else { return }
            try? FileManager.default.removeItem(at: url)

            DispatchQueue.main.async {
                self.viewModel.sendVideo(videoData: videoData, thumbnail: thumbnailData ?? Data(), duration: durationSeconds)
            }
        }
    }

    /// Scales the image to at most 200px on its longest side, then iteratively
    /// lowers JPEG quality until the output is under 60 KB — staying safely
    /// inside the server's BLOB column limit of 64 KB.
    ///
    /// `format.scale = 1` is load-bearing: `UIImage.size` is in points, and a
    /// renderer left at its default screen scale would emit `maxDimension * 3`
    /// pixels on an @3x device. That made thumbnails 600px wide instead of
    /// 200px — small enough in bytes, but 1MB+ once a receiving client decodes
    /// them, which is over Android's binder transaction limit and broke
    /// forwarding there. Pixel size must not depend on the sender's screen.
    private static func makeThumbnailData(_ image: UIImage, maxDimension: CGFloat = 200, sizeLimit: Int = 60 * 1024) -> Data? {
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }

        var quality: CGFloat = 0.7
        while quality > 0.1 {
            if let data = scaled.jpegData(compressionQuality: quality), data.count <= sizeLimit {
                return data
            }
            quality -= 0.15
        }
        return scaled.jpegData(compressionQuality: 0.1)
    }

    /// 从当前 rows 收集全部图片消息组成画廊（含发送中的 pending 图），
    /// 用 rowIdentity 定位被点击的那张作为起始页。图片行的判定统一由
    /// isImageMessage(_:) 定义，与 configureDataSource 的 cell 分派规则
    /// （兜底到 ImageMessageCell 的那个 case）保持一致。
    private func presentImageGallery(from tappedRow: ChatMessageRow) {
        var items: [GalleryItem] = []
        var startIndex: Int?
        for row in viewModel.rows {
            let item: GalleryItem
            switch row {
            case .message(let message) where Self.isImageMessage(message):
                item = GalleryItem(thumbnail: message.imageThumbnail, remoteURL: message.imageRemoteURL)
            case .pendingImage(let pending):
                item = GalleryItem(thumbnail: pending.fullImageData, remoteURL: nil)
            default:
                continue
            }
            if Self.rowIdentity(row) == Self.rowIdentity(tappedRow) { startIndex = items.count }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        present(ImageGalleryViewController(items: items, startIndex: startIndex ?? 0), animated: true)
    }

    private func presentVideoPlayer(urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        let player = AVPlayer(url: url)
        let playerVC = AVPlayerViewController()
        playerVC.player = player
        present(playerVC, animated: true) { player.play() }
    }

    private func presentLocationPreview(lat: Double, lng: Double, title: String) {
        let vc = LocationPreviewViewController(lat: lat, lng: lng, title: title)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func stopCurrentVoicePlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        voicePlayer?.pause()
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: voicePlayer?.currentItem)
        voicePlayer = nil
        currentPlayingCell?.setPlaying(false)
        currentPlayingCell = nil
        if let old = currentPlaybackTempURL { try? FileManager.default.removeItem(at: old) }
        currentPlaybackTempURL = nil
    }

    private func playVoice(urlString: String?, cell: VoiceMessageCell?) {
        guard let urlString, let remoteURL = URL(string: urlString) else { return }
        stopCurrentVoicePlayback()

        // Outgoing messages recorded this session: play local M4A directly —
        // iOS cannot decode the uploaded AMR via any public API.
        let stem = remoteURL.deletingPathExtension().lastPathComponent
        if let localURL = Self.localVoiceM4ACache[stem],
           FileManager.default.fileExists(atPath: localURL.path) {
            currentPlayingCell = cell
            cell?.setPlaying(true)
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            audioPlayer = try? AVAudioPlayer(contentsOf: localURL)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            return
        }

        URLSession.shared.dataTask(with: remoteURL) { [weak self] data, _, _ in
            guard let data, let self else { return }
            let ext = remoteURL.pathExtension.lowercased()
            let fileExt = ext.isEmpty ? "amr" : ext
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + fileExt)
            guard (try? data.write(to: tempURL)) != nil else { return }

            DispatchQueue.main.async {
                self.currentPlaybackTempURL = tempURL
                self.currentPlayingCell = cell
                cell?.setPlaying(true)

                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)

                // AVPlayer uses CoreMedia's full decoder pipeline which supports
                // AMR-NB on device; AVAudioPlayer's format list excludes AMR on
                // recent iOS versions.
                let item = AVPlayerItem(url: tempURL)
                NotificationCenter.default.addObserver(self,
                    selector: #selector(self.voicePlaybackDidEnd),
                    name: .AVPlayerItemDidPlayToEndTime, object: item)
                self.voicePlayer = AVPlayer(playerItem: item)
                self.voicePlayer?.play()
            }
        }.resume()
    }

    @objc private func voicePlaybackDidEnd() {
        stopCurrentVoicePlayback()
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        let keyboardHeight = max(0, view.bounds.maxY - endFrame.minY - view.safeAreaInsets.bottom)
        inputBarBottomConstraint.constant = -keyboardHeight
        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
            // 键盘弹出时跟随滚到底部，最新消息不被键盘盖住。
            if keyboardHeight > 0 { self.scrollToBottom(animated: false) }
        }
    }

    @objc private func messageLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let indexPath = tableView.indexPathForRow(at: recognizer.location(in: tableView)),
              let item = dataSource.itemIdentifier(for: indexPath),
              case .message(let message) = item,
              let hostView = navigationController?.view else { return }
        // 横向跟随手指（区分左右气泡），纵向贴住被按的那一行。
        let rowRect = tableView.convert(tableView.rectForRow(at: indexPath), to: hostView)
        let touchX = recognizer.location(in: hostView).x
        let anchorRect = CGRect(x: touchX, y: rowRect.minY, width: 0, height: rowRect.height)
        // 选字状态下长按别的消息（或同一条）：先退出当前选字，再按新长按处理。
        endTextSelection()
        if isPlainText(message),
           let cell = tableView.cellForRow(at: indexPath) as? TextMessageCell,
           cell.beginSelection() {
            beginTextSelection(on: cell, message: message, hostView: hostView, fallbackAnchor: anchorRect)
            return
        }
        PlusMenuView.show(in: hostView, anchorRect: anchorRect, items: buildMenuItems(for: message))
    }

    /// 文本消息长按：全选 + 首尾手柄（微信式），菜单贴着选区；拖手柄时菜单先隐藏，
    /// 松手后按新选区重新定位。菜单关闭即退出选字。
    private func beginTextSelection(on cell: TextMessageCell, message: StoredMessageRow, hostView: UIView, fallbackAnchor: CGRect) {
        selectionSession += 1
        let session = selectionSession
        selectingTextCell = cell
        let menu = PlusMenuView.show(
            in: hostView,
            anchorRect: selectionMenuAnchor(for: cell, in: hostView) ?? fallbackAnchor,
            items: buildMenuItems(for: message, selectionCell: cell)
        )
        selectionMenu = menu
        selectionDismissTap.isEnabled = true
        // 列表区域的触摸放行：照常滑动、拖手柄；点一下由 selectionDismissTap 退出选字。
        // 导航栏、输入栏等列表外区域仍由遮罩接住，点一下关闭。
        menu.touchPassthrough = { [weak self] windowPoint in
            guard let self else { return false }
            return self.tableView.convert(self.tableView.bounds, to: nil).contains(windowPoint)
        }
        menu.onDismiss = { [weak self, weak cell] in
            guard let self, self.selectionSession == session else { return }
            cell?.clearSelection()
            self.selectingTextCell = nil
            self.selectionDismissTap.isEnabled = false
        }
        cell.onSelectionDragBegan = { [weak menu] in menu?.setCardHidden(true) }
        cell.onSelectionDragEnded = { [weak self] in self?.restoreSelectionMenu() }
        cell.onSelectionCleared = { [weak menu] in menu?.dismiss() }
    }

    /// 立即退出选字（清选区 + 关菜单）。
    private func endTextSelection() {
        selectingTextCell?.clearSelection()
        selectionMenu?.dismiss()
        selectingTextCell = nil
        selectionDismissTap.isEnabled = false
    }

    @objc private func selectionDismissTapped() {
        endTextSelection()
    }

    /// 拖手柄或滑动列表结束后，按选区的新位置把菜单放回来；选区已滑出可见区域则继续藏着，
    /// 滑回来停下时再出现（与微信一致）。
    private func restoreSelectionMenu() {
        guard let cell = selectingTextCell, let menu = selectionMenu, let hostView = menu.superview,
              let anchor = selectionMenuAnchor(for: cell, in: hostView) else { return }
        menu.reposition(anchorRect: anchor)
        menu.setCardHidden(false)
    }

    /// 选区外接矩形裁到列表可见区域内——长消息全选时选区比屏幕还高，
    /// 不裁的话菜单会被算到屏幕外。选区完全不可见时返回 nil。
    private func selectionMenuAnchor(for cell: TextMessageCell, in hostView: UIView) -> CGRect? {
        guard let bounds = cell.selectionBounds(in: hostView) else { return nil }
        let visible = tableView.convert(tableView.bounds, to: hostView)
        let clipped = bounds.intersection(visible)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    /// 纯文本消息（排除语音/文件/位置/视频这些也带 text 的消息）。
    private func isPlainText(_ message: StoredMessageRow) -> Bool {
        message.text != nil
            && message.voiceDuration == nil
            && message.fileName == nil
            && message.locationLat == nil
            && message.videoDuration == nil
    }

    private func buildMenuItems(for message: StoredMessageRow, selectionCell: TextMessageCell? = nil) -> [PlusMenuView.Item] {
        var items: [PlusMenuView.Item] = []

        // 转文字 / 隐藏文字 — 语音消息
        if message.voiceDuration != nil, let engine = viewModel.transcripts {
            let entry = engine.entry(for: message.messageUid)
            if VoiceTranscriptRules.showTranscribeMenu(messageUid: message.messageUid, entry: entry) {
                items.append(.init(symbolName: "text.bubble", title: "转文字") { [weak self] in
                    self?.transcribe(message)
                })
            } else if VoiceTranscriptRules.showHideMenu(messageUid: message.messageUid, entry: entry) {
                items.append(.init(symbolName: "eye.slash", title: "隐藏文字") {
                    engine.hide(message.messageUid)
                })
            }
        }

        // Copy — text-only (excludes voice/file prefixes, location, video)
        // 选字状态下只复制选中部分；全选时复制原文（菜单在复制之后才关闭、清选区）。
        if let text = message.text, isPlainText(message) {
            items.append(.init(symbolName: "doc.on.doc", title: "复制") { [weak selectionCell] in
                UIPasteboard.general.string = selectionCell?.partiallySelectedText ?? text
            })
        }

        // Forward
        items.append(.init(symbolName: "arrowshape.turn.up.right", title: "转发") { [weak self] in
            self?.handleForward(message: message)
        })

        // Recall
        if viewModel.canRecall(row: message) {
            items.append(.init(symbolName: "arrow.uturn.backward", title: "撤回") { [weak self] in
                self?.handleRecall(message: message)
            })
        }

        // Save image — image messages only (has thumbnail, no video/voice/file)
        if message.imageThumbnail != nil,
           message.videoDuration == nil,
           message.voiceDuration == nil,
           message.fileName == nil {
            items.append(.init(symbolName: "square.and.arrow.down", title: "保存图片") { [weak self] in
                self?.saveMedia(urlString: message.imageRemoteURL, isVideo: false)
            })
        }

        // Save video
        if message.videoDuration != nil {
            items.append(.init(symbolName: "square.and.arrow.down", title: "保存视频") { [weak self] in
                self?.saveMedia(urlString: message.imageRemoteURL, isVideo: true)
            })
        }

        // Delete
        items.append(.init(symbolName: "trash", title: "删除", isDestructive: true) { [weak self] in
            self?.handleDelete(message: message)
        })

        return items
    }

    private func handleForward(message: StoredMessageRow) {
        guard let factory = forwardViewModelFactory else { return }
        let pickerVC = ForwardPickerViewController(sourceMessage: message, viewModel: factory())
        pickerVC.onConfirmForward = { [weak self, weak pickerVC] targetRow, note in
            self?.viewModel.forward(row: message, to: targetRow, note: note)
            self?.navigationController?.popViewController(animated: true)
        }
        navigationController?.pushViewController(pickerVC, animated: true)
    }

    private func handleRecall(message: StoredMessageRow) {
        viewModel.recallMessage(row: message) { [weak self] success in
            DispatchQueue.main.async {
                guard !success else { return }
                let alert = UIAlertController(title: "撤回失败", message: "消息撤回失败，请稍后重试", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default))
                self?.present(alert, animated: true)
            }
        }
    }

    private func handleDelete(message: StoredMessageRow) {
        let alert = UIAlertController(title: "删除消息", message: "删除后无法恢复，确认删除？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.viewModel.deleteMessage(row: message)
        })
        present(alert, animated: true)
    }

    private func saveMedia(urlString: String?, isVideo: Bool) {
        guard let urlString, let url = URL(string: urlString) else { return }
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.center = view.center
        view.addSubview(indicator)
        indicator.startAnimating()

        if isVideo {
            URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, _ in
                DispatchQueue.main.async {
                    indicator.removeFromSuperview()
                    guard let tempURL, let self else { return }
                    let destURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + ".mp4")
                    try? FileManager.default.moveItem(at: tempURL, to: destURL)
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: destURL)
                    }) { success, _ in
                        DispatchQueue.main.async {
                            try? FileManager.default.removeItem(at: destURL)
                            self.showToast(success ? "视频已保存到相册" : "保存失败")
                        }
                    }
                }
            }.resume()
        } else {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                DispatchQueue.main.async {
                    indicator.removeFromSuperview()
                    guard let data, let image = UIImage(data: data), let self else { return }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }) { success, _ in
                        DispatchQueue.main.async { self.showToast(success ? "图片已保存到相册" : "保存失败") }
                    }
                }
            }.resume()
        }
    }

    private func showToast(_ message: String) {
        let toast = UILabel()
        toast.text = message
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        toast.textColor = .white
        toast.textAlignment = .center
        toast.font = .systemFont(ofSize: 14)
        toast.layer.cornerRadius = 8
        toast.clipsToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            toast.heightAnchor.constraint(equalToConstant: 36),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.5) { toast.alpha = 0 } completion: { _ in toast.removeFromSuperview() }
    }
}

extension ConversationViewController: UITableViewDelegate {
    // 选字状态下滑动列表：滑动时菜单隐藏，静止后在选区旁重新出现（选区本身保留）。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        selectionMenu?.setCardHidden(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if pendingHistoryRefresh {
            pendingHistoryRefresh = false
            startHistoryLoad()
        }
        if !decelerate { restoreSelectionMenu() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        restoreSelectionMenu()
    }

}

extension ConversationViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }

        if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { self?.handlePickedImage(image) }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
                guard let url else { return }
                // Copy to a stable temp path — the provided URL is only valid
                // during this completion handler.
                let ext = url.pathExtension.lowercased().isEmpty ? "mp4" : url.pathExtension.lowercased()
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + ext)
                guard (try? FileManager.default.copyItem(at: url, to: tempURL)) != nil else { return }
                DispatchQueue.main.async { self?.handlePickedVideo(at: tempURL) }
            }
        }
    }
}

extension ConversationViewController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        currentPlayingCell?.setPlaying(false)
        currentPlayingCell = nil
        audioPlayer = nil
    }
}

extension ConversationViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        viewModel.sendFile(fileData: data, fileName: url.lastPathComponent)
    }
}

// MARK: - 文件消息下载与预览

extension ConversationViewController: QLPreviewControllerDataSource {
    /// 未下载 → 起下载并实时刷新进度；下载中 → 忽略；已下载 → QuickLook
    /// 预览（自带分享按钮，可存到「文件」或转发其他 App）。
    private func handleFileTap(message: StoredMessageRow) {
        switch fileDownloadManager.state(for: message) {
        case .downloading:
            return
        case .downloaded(let url):
            presentFilePreview(url: url)
        case .notDownloaded:
            fileDownloadManager.download(row: message) { [weak self] _ in
                self?.refreshFileCell(for: message)
            } completion: { [weak self] result in
                self?.refreshFileCell(for: message)
                if case .failure = result {
                    let alert = UIAlertController(title: "下载失败", message: "文件下载失败，请稍后重试", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default))
                    self?.present(alert, animated: true)
                }
            }
            refreshFileCell(for: message)
        }
    }

    /// 下载状态不参与 diffable 快照身份，直接刷新可见 cell 的状态行。
    private func refreshFileCell(for message: StoredMessageRow) {
        guard let indexPath = dataSource.indexPath(for: .message(message)),
              let cell = tableView.cellForRow(at: indexPath) as? FileMessageCell else { return }
        cell.update(state: fileDownloadManager.state(for: message))
    }

    private func presentFilePreview(url: URL) {
        previewURL = url
        let preview = QLPreviewController()
        preview.dataSource = self
        present(preview, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "")) as NSURL
    }
}

extension ConversationViewController: UIGestureRecognizerDelegate {
    /// 选字时的「点一下退出」要抢在气泡自己的点按（链接、看图、播放等）之前识别；
    /// 列表自身的滚动/长按、选区手柄的拖动不受影响。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === selectionDismissTap, selectionDismissTap.isEnabled else { return false }
        return otherGestureRecognizer.view !== tableView && !(otherGestureRecognizer.view is SelectionHandleView)
    }
}
