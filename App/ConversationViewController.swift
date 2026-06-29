// App/ConversationViewController.swift
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import Combine
import IMKit

final class ConversationViewController: UIViewController {
    private let row: ConversationRow
    private let viewModel: ConversationViewModel
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UITableViewDiffableDataSource<Int, ChatMessageRow>!
    private var audioPlayer: AVAudioPlayer?
    private var voicePlayer: AVPlayer?
    private var currentPlaybackTempURL: URL?
    private weak var currentPlayingCell: VoiceMessageCell?
    /// Maps filename stem (e.g. "voice-1234567890") → local M4A URL for
    /// outgoing voice messages recorded this session. Lets iOS play back its
    /// own recordings without needing to decode the uploaded AMR file.
    private static var localVoiceM4ACache: [String: URL] = [:]

    private let tableView = UITableView()
    private let inputBar = MessageInputBar()
    private var inputBarBottomConstraint: NSLayoutConstraint!
    private var previousRawRows: [ChatMessageRow] = []

    var onGroupInfoTapped: (() -> Void)?
    var onContactInfoTapped: (() -> Void)?
    var onCallTapped: ((_ audioOnly: Bool) -> Void)?

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
        viewModel.reprocessMessages()
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

        if row.conversationType == .single {
            let videoItem = UIBarButtonItem(image: UIImage(systemName: "video.fill"), style: .plain, target: self, action: #selector(videoCallTapped))
            let audioItem = UIBarButtonItem(image: UIImage(systemName: "phone.fill"), style: .plain, target: self, action: #selector(audioCallTapped))
            navigationItem.rightBarButtonItems = [infoItem, videoItem, audioItem]
        } else {
            navigationItem.rightBarButtonItems = [infoItem]
        }
    }

    @objc private func infoTapped() {
        if row.conversationType == .group {
            onGroupInfoTapped?()
        } else {
            onContactInfoTapped?()
        }
    }
    @objc private func videoCallTapped() { onCallTapped?(false) }
    @objc private func audioCallTapped() { onCallTapped?(true) }

    private func layoutViews() {
        tableView.register(TextMessageCell.self, forCellReuseIdentifier: TextMessageCell.reuseIdentifier)
        tableView.register(ImageMessageCell.self, forCellReuseIdentifier: ImageMessageCell.reuseIdentifier)
        tableView.register(VideoMessageCell.self, forCellReuseIdentifier: VideoMessageCell.reuseIdentifier)
        tableView.register(VoiceMessageCell.self, forCellReuseIdentifier: VoiceMessageCell.reuseIdentifier)
        tableView.register(FileMessageCell.self, forCellReuseIdentifier: FileMessageCell.reuseIdentifier)
        tableView.register(SystemTipMessageCell.self, forCellReuseIdentifier: SystemTipMessageCell.reuseIdentifier)
        tableView.register(TimeHeaderCell.self, forCellReuseIdentifier: TimeHeaderCell.reuseIdentifier)
        tableView.delegate = self
        tableView.backgroundColor = Theme.backgroundPrimary
        tableView.separatorStyle = .none
        tableView.translatesAutoresizingMaskIntoConstraints = false

        inputBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(inputBar)

        inputBarBottomConstraint = inputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBarBottomConstraint,
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, ChatMessageRow>(tableView: tableView) { tableView, indexPath, row in
            switch row {
            case .message(let message) where message.text?.hasPrefix("[语音]") == true:
                let cell = tableView.dequeueReusableCell(withIdentifier: VoiceMessageCell.reuseIdentifier, for: indexPath) as! VoiceMessageCell
                cell.configure(with: message)
                cell.onTapped = { [weak self, weak cell] in self?.playVoice(urlString: message.imageRemoteURL, cell: cell) }
                return cell
            case .message(let message) where message.text?.hasPrefix("[文件]") == true:
                let cell = tableView.dequeueReusableCell(withIdentifier: FileMessageCell.reuseIdentifier, for: indexPath) as! FileMessageCell
                cell.configure(with: message)
                return cell
            case .message(let message) where message.text != nil:
                let cell = tableView.dequeueReusableCell(withIdentifier: TextMessageCell.reuseIdentifier, for: indexPath) as! TextMessageCell
                cell.configure(with: message)
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                return cell
            case .message(let message) where message.videoDuration != nil:
                let cell = tableView.dequeueReusableCell(withIdentifier: VideoMessageCell.reuseIdentifier, for: indexPath) as! VideoMessageCell
                cell.configure(with: VideoBubbleData(thumbnail: message.imageThumbnail, duration: message.videoDuration ?? 0, isOutgoing: message.isOutgoing, isUploading: message.status == .sending, isFailed: message.status == .sendFailure, senderDisplayName: message.senderDisplayName, senderAvatarURL: message.senderAvatarURL))
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                return cell
            case .message(let message):
                let cell = tableView.dequeueReusableCell(withIdentifier: ImageMessageCell.reuseIdentifier, for: indexPath) as! ImageMessageCell
                cell.configure(with: ImageBubbleData(thumbnail: message.imageThumbnail, isOutgoing: message.isOutgoing, isUploading: message.status == .sending, isFailed: message.status == .sendFailure, senderDisplayName: message.senderDisplayName, senderAvatarURL: message.senderAvatarURL))
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onTapped = { [weak self] in self?.presentImagePreview(thumbnail: message.imageThumbnail, remoteURL: message.imageRemoteURL) }
                return cell
            case .pendingImage(let pending):
                let cell = tableView.dequeueReusableCell(withIdentifier: ImageMessageCell.reuseIdentifier, for: indexPath) as! ImageMessageCell
                cell.configure(with: ImageBubbleData(thumbnail: pending.thumbnail, isOutgoing: true, isUploading: pending.state == .uploading, isFailed: pending.state == .failed))
                cell.onRetryTapped = { [weak self] in self?.viewModel.retry(row: row) }
                cell.onTapped = { [weak self] in self?.presentImagePreview(thumbnail: pending.thumbnail, remoteURL: nil) }
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
        let previousContentHeight = tableView.contentSize.height

        let displayRows = injectTimeHeaders(rows)
        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatMessageRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(displayRows, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: !isPrepend) { [weak self] in
            guard let self else { return }
            if isPrepend {
                let delta = self.tableView.contentSize.height - previousContentHeight
                self.tableView.contentOffset.y += delta
            } else if isAppend {
                self.scrollToBottom(animated: !oldRows.isEmpty)
            }
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
        inputBar.onSendVoice = { [weak self] audioData, duration, fileName, localM4AURL in
            if let localM4AURL {
                let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
                Self.localVoiceM4ACache[stem] = localM4AURL
            }
            self?.viewModel.sendVoice(audioData: audioData, duration: duration, fileName: fileName)
        }
        inputBar.onMentionTriggered = { [weak self] in self?.presentMentionPicker() }
    }

    private func presentMentionPicker() {
        guard row.conversationType == .group else { return }
        let picker = MentionPickerViewController(members: viewModel.groupMemberCandidatesForMention())
        picker.onPicked = { [weak self] uid, displayName in
            self?.inputBar.insertMention(uid: uid, displayName: displayName)
            self?.dismiss(animated: true)
        }
        picker.onCancelled = { [weak self] in self?.inputBar.removeTrailingMentionTrigger() }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentFilePicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .pdf, .text, .image])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func presentImagePicker() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
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

    private func presentImagePreview(thumbnail: Data?, remoteURL: String?) {
        present(ImagePreviewViewController(localThumbnail: thumbnail, remoteURL: remoteURL), animated: true)
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
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }
}

extension ConversationViewController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.contentOffset.y < 100 else { return }
        viewModel.loadMore()
    }
}

extension ConversationViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async { self?.handlePickedImage(image) }
        }
    }
}

extension ConversationViewController: UINavigationControllerDelegate, UIImagePickerControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let fullData = image.jpegData(compressionQuality: 0.8),
              let thumbnail = Self.makeThumbnailData(image) else { return }
        viewModel.sendImage(fullImageData: fullData, thumbnail: thumbnail)
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

