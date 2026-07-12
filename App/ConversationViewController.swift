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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.clearUnread()
        viewModel.markActive()
        viewModel.reprocessMessages()
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
                cell.configure(with: message)
                cell.onTapped = { [weak self, weak cell] in self?.playVoice(urlString: message.imageRemoteURL, cell: cell) }
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
                cell.configure(with: message)
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onExpandTapped = { [weak self] in
                    guard let text = message.text else { return }
                    self?.navigationController?.pushViewController(TextPreviewViewController(text: text), animated: true)
                }
                cell.onAvatarLongPressed = { [weak self] in self?.insertMentionFromAvatar(message) }
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

    private func bindViewModel() {
        viewModel.$rows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rows in self?.applySnapshot(rows: rows) }
            .store(in: &cancellables)
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
        let timeStr: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }()
        if calendar.isDateInToday(date) {
            return "\(period) \(timeStr)"
        } else if calendar.isDateInYesterday(date) {
            return "昨天 \(period) \(timeStr)"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let weekday = calendar.component(.weekday, from: date) - 1
            return "\(weekdays[weekday]) \(period) \(timeStr)"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月d日"
            return "\(f.string(from: date)) \(period) \(timeStr)"
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "yyyy年M月d日"
            return "\(f.string(from: date)) \(period) \(timeStr)"
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
        case .systemTip(let tip): return "systemTip-\(tip.storageId)"
        case .timeHeader(let text, let anchorId): return "timeHeader-\(anchorId)-\(text)"
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
            let nav = UINavigationController(rootViewController: picker)
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
        present(UINavigationController(rootViewController: picker), animated: true)
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
    private static func makeThumbnailData(_ image: UIImage, maxDimension: CGFloat = 200, sizeLimit: Int = 60 * 1024) -> Data? {
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
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
        PlusMenuView.show(in: hostView, anchorRect: anchorRect, items: buildMenuItems(for: message))
    }

    private func buildMenuItems(for message: StoredMessageRow) -> [PlusMenuView.Item] {
        var items: [PlusMenuView.Item] = []

        // Copy — text-only (excludes voice/file prefixes, location, video)
        if let text = message.text,
           message.voiceDuration == nil,
           message.fileName == nil,
           message.locationLat == nil,
           message.videoDuration == nil {
            items.append(.init(symbolName: "doc.on.doc", title: "复制") {
                UIPasteboard.general.string = text
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
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if pendingHistoryRefresh {
            pendingHistoryRefresh = false
            startHistoryLoad()
        }
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

