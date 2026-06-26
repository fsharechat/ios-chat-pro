import Foundation
import Combine
import IMStorage

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ConversationViewModel {
    @Published public private(set) var rows: [ChatMessageRow] = []
    @Published public private(set) var canLoadMore: Bool = true

    private let storage: IMStorage
    private let messageSending: MessageSending?
    private let imageUploading: ImageUploading?
    private let voiceUploading: VoiceUploading?
    private let fileUploading: FileUploading?
    private let target: String
    private let conversationType: ConversationType
    private let line: Int
    private let pageSize: Int
    private let currentUserId: String

    /// Older history loaded via `loadMore`, strictly before `liveRows`.
    /// One-shot (not reactive) — see `liveRows`'s doc comment for the full
    /// eviction/migration contract, unchanged from Phase 1 except that both
    /// arrays now hold `ChatMessageRow` (so a `.systemTip` row can appear in
    /// the same paging window as ordinary messages) instead of
    /// `StoredMessageRow`.
    private var olderRows: [ChatMessageRow] = []
    private var liveRows: [ChatMessageRow] = []
    private var pendingImages: [PendingImageUpload] = []
    private var cancellable: AnyCancellable?

    public init(
        storage: IMStorage,
        messageSending: MessageSending?,
        imageUploading: ImageUploading?,
        voiceUploading: VoiceUploading? = nil,
        fileUploading: FileUploading? = nil,
        target: String,
        conversationType: ConversationType = .single,
        line: Int = 0,
        pageSize: Int = 30,
        currentUserId: String
    ) {
        self.storage = storage
        self.messageSending = messageSending
        self.imageUploading = imageUploading
        self.voiceUploading = voiceUploading
        self.fileUploading = fileUploading
        self.target = target
        self.conversationType = conversationType
        self.line = line
        self.pageSize = pageSize
        self.currentUserId = currentUserId

        cancellable = storage.messages
            .messagesPublisher(conversationType: conversationType, target: target, line: line, limit: pageSize)
            .replaceError(with: [])
            .sink { [weak self] messages in self?.handleMessagesUpdate(messages) }
    }

    /// Failure (e.g. serialization, or no `messageSending` configured) is
    /// silently dropped — accepted Phase-1 gap, no logging facility yet,
    /// same as `ContactSyncService`/`FriendSyncHandler` elsewhere.
    public func sendText(_ text: String, mentionedType: Int = 0, mentionedTargets: [String] = []) {
        try? messageSending?.sendText(to: target, conversationType: conversationType, line: line, text: text, mentionedType: Int32(mentionedType), mentionedTargets: mentionedTargets)
    }

    public func sendImage(fullImageData: Data, thumbnail: Data) {
        let pending = PendingImageUpload(id: UUID(), thumbnail: thumbnail, fullImageData: fullImageData, state: .uploading)
        pendingImages.append(pending)
        publishRows()
        startUpload(pending)
    }

    public func sendVoice(audioData: Data, duration: Int, fileName: String) {
        voiceUploading?.uploadVoice(audioData, fileName: fileName) { [weak self] result in
            guard let self else { return }
            if case .success(let url) = result {
                try? self.messageSending?.sendVoice(to: self.target, conversationType: self.conversationType, line: self.line, remoteURL: url, duration: duration)
            }
        }
    }

    public func sendFile(fileData: Data, fileName: String) {
        let size = fileData.count
        fileUploading?.uploadFile(fileData, fileName: fileName) { [weak self] result in
            guard let self else { return }
            if case .success(let url) = result {
                try? self.messageSending?.sendFile(to: self.target, conversationType: self.conversationType, line: self.line, name: fileName, size: size, remoteURL: url)
            }
        }
    }

    /// Candidate members for the composer's "@" picker — empty for a
    /// non-group conversation. Excludes `.removed` members (same filter
    /// `GroupStore.members(groupId:)` already applies).
    public func groupMemberCandidatesForMention() -> [(uid: String, displayName: String)] {
        guard conversationType == .group else { return [] }
        let members = (try? storage.groups.members(groupId: target)) ?? []
        return members.map { member in
            let user = try? storage.users.user(uid: member.memberId)
            return (uid: member.memberId, displayName: user?.displayName ?? user?.name ?? member.memberId)
        }
    }

    /// Retries a failed send: a `.pendingImage` row re-runs the upload from
    /// scratch; a `.message` row with `status == .sendFailure` re-sends the
    /// already-stored row via `MessageSending.resend(localMessageId:)`. A
    /// no-op for any other row/status combination, including `.systemTip` —
    /// a group notification was never "sent" by this client and has nothing
    /// to retry.
    public func retry(row: ChatMessageRow) {
        switch row {
        case .pendingImage(let pending):
            guard let index = pendingImages.firstIndex(where: { $0.id == pending.id }) else { return }
            pendingImages[index].state = .uploading
            publishRows()
            startUpload(pendingImages[index])
        case .message(let message):
            guard message.status == .sendFailure else { return }
            try? messageSending?.resend(localMessageId: message.localMessageId)
        case .systemTip, .timeHeader:
            break
        }
    }

    public func clearUnread() {
        try? storage.conversations.clearUnread(conversationType: conversationType, target: target, line: line)
    }

    /// Loads one older page of history before the currently-oldest loaded
    /// message. A no-op if nothing is loaded yet or a previous call already
    /// determined there's no more history (`canLoadMore == false`).
    public func loadMore() {
        guard canLoadMore, let oldest = (olderRows.first ?? liveRows.first),
              let oldestTimestamp = oldest.timestamp, let oldestId = oldest.storageId else { return }
        let older = (try? storage.messages.olderMessages(
            conversationType: conversationType, target: target, line: line,
            beforeTimestamp: oldestTimestamp, beforeId: oldestId, limit: pageSize
        )) ?? []
        if older.count < pageSize { canLoadMore = false }
        guard !older.isEmpty else { return }
        olderRows.insert(contentsOf: older.map(makeRow), at: 0)
        publishRows()
    }

    private func startUpload(_ pending: PendingImageUpload) {
        imageUploading?.uploadImage(pending.fullImageData) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let remoteURL):
                try? self.messageSending?.sendImage(to: self.target, conversationType: self.conversationType, line: self.line, thumbnail: pending.thumbnail, remoteURL: remoteURL)
                self.pendingImages.removeAll { $0.id == pending.id }
            case .failure:
                if let index = self.pendingImages.firstIndex(where: { $0.id == pending.id }) {
                    self.pendingImages[index].state = .failed
                }
            }
            self.publishRows()
        }
    }

    private func handleMessagesUpdate(_ messages: [StoredMessage]) {
        // `messagesPublisher` always reports the full current "latest
        // pageSize" window (already ascending), so it wholesale-replaces
        // `liveRows` rather than merging — see `liveRows`'s doc comment.
        // But once `loadMore()` has paged in real history (`olderRows`
        // non-empty), anything that was visible in the OLD `liveRows` and
        // isn't in the NEW one (because a newer message pushed the window
        // forward) must not simply vanish — migrate it into `olderRows`
        // instead. Before any paging has happened, `olderRows` is empty and
        // this migration is skipped on purpose: early on, a burst of writes
        // (e.g. initial backlog sync) can make the live window itself slide
        // forward through several transient intermediate states before the
        // very first page has ever been explicitly requested, and treating
        // every one of those transient slides as a permanent boundary
        // crossing would defeat the "latest pageSize" windowing entirely.
        let newLiveRows = messages.map(makeRow)
        let newStorageIds = Set(newLiveRows.compactMap(\.storageId))
        if !olderRows.isEmpty {
            let evicted = liveRows.filter { row in
                guard let id = row.storageId else { return false }
                return !newStorageIds.contains(id)
            }
            if !evicted.isEmpty {
                olderRows.append(contentsOf: evicted)
                olderRows.sort { lhs, rhs in
                    let lhsTime = lhs.timestamp ?? 0
                    let rhsTime = rhs.timestamp ?? 0
                    return lhsTime == rhsTime ? (lhs.storageId ?? 0) < (rhs.storageId ?? 0) : lhsTime < rhsTime
                }
            }
        }
        liveRows = newLiveRows
        publishRows()
    }

    private func publishRows() {
        rows = olderRows + liveRows + pendingImages.map { .pendingImage($0) }
    }

    /// `message.id` is always non-nil for a row fetched back from the
    /// database (`FetchableRecord` only ever omits it before insertion) —
    /// the `-1` fallback is unreachable in practice, not a real sentinel.
    private func makeRow(_ message: StoredMessage) -> ChatMessageRow {
        switch message.content {
        case .text(let text):
            return .message(buildStoredMessageRow(message, text: text, imageThumbnail: nil, imageRemoteURL: nil))
        case .image(let thumbnail, let remoteURL, _):
            return .message(buildStoredMessageRow(message, text: nil, imageThumbnail: thumbnail, imageRemoteURL: remoteURL))
        case .groupNotification(let type, let operatorUid, let memberUids, let value):
            return .systemTip(SystemTipRow(
                storageId: message.id ?? -1,
                text: renderSystemTipText(type: type, operatorUid: operatorUid, memberUids: memberUids, value: value),
                timestamp: message.timestamp
            ))
        case .callRecord(_, _, let audioOnly, let status, let connectTime, let endTime):
            return .message(buildStoredMessageRow(message, text: renderCallRecordText(isOutgoing: message.direction == .send, audioOnly: audioOnly, status: status, connectTime: connectTime, endTime: endTime), imageThumbnail: nil, imageRemoteURL: nil))
        case .voice(let remoteURL, _, let duration):
            return .message(buildStoredMessageRow(message, text: "[语音] \(duration)秒", imageThumbnail: nil, imageRemoteURL: remoteURL))
        case .file(let name, let size, _, _):
            let sizeStr = size > 1024*1024 ? String(format: "%.1fMB", Double(size)/1024/1024) : "\(size/1024)KB"
            return .message(buildStoredMessageRow(message, text: "[文件] \(name) \(sizeStr)", imageThumbnail: nil, imageRemoteURL: nil))
        }
    }

    private func buildStoredMessageRow(_ message: StoredMessage, text: String?, imageThumbnail: Data?, imageRemoteURL: String?) -> StoredMessageRow {
        var senderDisplayName: String?
        // Always resolve the avatar — own portrait for outgoing, sender's for incoming.
        let avatarUid = message.direction == .send ? currentUserId : message.from
        let user = try? storage.users.user(uid: avatarUid)
        let senderAvatarURL = user?.portrait
        // Sender name only appears in group incoming bubbles.
        if conversationType == .group, message.direction == .receive {
            senderDisplayName = user?.displayName ?? user?.name ?? message.from
        }
        return StoredMessageRow(
            storageId: message.id ?? -1,
            localMessageId: message.localMessageId,
            isOutgoing: message.direction == .send,
            status: message.status,
            timestamp: message.timestamp,
            text: text,
            imageThumbnail: imageThumbnail,
            imageRemoteURL: imageRemoteURL,
            senderDisplayName: senderDisplayName,
            senderAvatarURL: senderAvatarURL
        )
    }

    /// `uid == currentUserId` renders as "您" — matches every Android
    /// group-notification template, which substitutes the first-person
    /// pronoun for the acting user's own actions.
    private func resolveDisplayName(_ uid: String) -> String {
        guard uid != currentUserId else { return "您" }
        guard let user = try? storage.users.user(uid: uid) else { return uid }
        return user.displayName ?? user.name ?? uid
    }

    /// Wording transcribed verbatim from the design doc's wire-format
    /// table (itself transcribed from Android's `*NotificationContent
    /// .formatNotification()` methods).
    private func renderSystemTipText(type: MessageContentType, operatorUid: String, memberUids: [String], value: String?) -> String {
        let operatorName = resolveDisplayName(operatorUid)
        switch type {
        case .createGroup:
            return "\(operatorName)创建了群组"
        case .addGroupMember:
            let names = memberUids.map(resolveDisplayName).joined(separator: "、")
            return "\(operatorName)邀请\(names)加入了群组"
        case .kickoffGroupMember:
            let names = memberUids.map(resolveDisplayName).joined(separator: "、")
            return "\(operatorName)将\(names)移出了群组"
        case .quitGroup:
            return "\(operatorName)退出了群组"
        case .dismissGroup:
            return "\(operatorName)解散了群组"
        case .changeGroupName:
            return "\(operatorName)修改群名为「\(value ?? "")」"
        case .changeGroupPortrait:
            return "\(operatorName)修改了群头像"
        case .text, .image, .callStart, .voice, .file:
            return "" // unreachable: makeRow only calls this for .groupNotification content
        }
    }

    /// Bubble text for a `.callRecord` row — design doc §2's rule: status 2
    /// with a real `connectTime` shows duration; status 2 with no
    /// `connectTime` (call never connected) shows "已取消" from the caller's
    /// side, "未接听" from the callee's side. Status 0/1 rows are only ever
    /// momentarily on screen mid-call (this device's own `CallManager`
    /// updates them to status 2 the instant the call ends) and don't need
    /// distinct wording.
    private func renderCallRecordText(isOutgoing: Bool, audioOnly: Bool, status: Int, connectTime: Int64, endTime: Int64) -> String {
        let icon = audioOnly ? "📞" : "📹"
        let kind = audioOnly ? "语音通话" : "视频通话"
        guard status == 2 else { return "\(icon) \(kind)" }
        guard connectTime > 0 else { return isOutgoing ? "\(icon) 已取消" : "\(icon) 未接听" }
        let durationSeconds = Int(max(0, (endTime - connectTime) / 1000))
        return String(format: "\(icon) \(kind) %02d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
}
