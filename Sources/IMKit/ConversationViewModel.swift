import Foundation
import Combine
import IMStorage

/// 输入框 @ 选人页的候选成员。
public struct MentionCandidate: Equatable {
    public let uid: String
    public let displayName: String
    public let avatarURL: String?

    public init(uid: String, displayName: String, avatarURL: String?) {
        self.uid = uid
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class ConversationViewModel {
    @Published public private(set) var rows: [ChatMessageRow] = []
    @Published public private(set) var canLoadMore: Bool = true

    private let storage: IMStorage
    private let messageSending: MessageSending?
    private let contactSync: ContactInfoFetching?
    private let imageUploading: ImageUploading?
    private let voiceUploading: VoiceUploading?
    private let fileUploading: FileUploading?
    private let videoUploading: VideoUploading?
    private let remoteHistory: RemoteHistoryFetching?
    /// 语音转文字引擎，由 `SceneDelegate` 注入；为 nil 时会话页不显示转文字入口
    public let transcripts: TranscriptEngine?
    private let activeTracking: ActiveConversationTracking?
    private let streaming: StreamingAiObserving?
    /// Set once the server confirms there's nothing older than what's
    /// stored locally — stops `loadMoreHistory` from re-asking every pull.
    private var remoteHistoryExhausted = false
    private let target: String
    private let conversationType: ConversationType
    private let line: Int
    private let pageSize: Int
    private let currentUserId: String

    /// Older history loaded via `loadMore`, strictly before the live window.
    /// One-shot (not reactive). Source of truth is `olderMessages` (raw
    /// `StoredMessage`s); `olderRows` is re-derived from it on every rebuild
    /// so presentation-affecting state (nickname toggle, profile updates)
    /// reaches paged-in history too — deriving rows once and keeping them
    /// was how `reprocessMessages` ended up refreshing only the live window.
    private var olderMessages: [StoredMessage] = []
    private var olderRows: [ChatMessageRow] = []
    private var liveRows: [ChatMessageRow] = []
    private var pendingImages: [PendingImageUpload] = []
    private var pendingVideos: [PendingVideoUpload] = []
    private var pendingVoices: [PendingVoiceUpload] = []
    private var streamingRow: StreamingRow?
    private var lastMessages: [StoredMessage] = []
    private var cancellable: AnyCancellable?
    private var usersCancellable: AnyCancellable?
    /// Per-batch user lookup, filled by `makeRows` with one bulk
    /// `users(uids:)` query — `buildStoredMessageRow`/`resolveDisplayName`
    /// read from here instead of issuing one `dbQueue.read` per message,
    /// which serialized 30+ round-trips through the database queue on every
    /// rows rebuild (the dominant cost of opening a conversation).
    private var userCache: [String: StoredUser] = [:]
    /// Every uid the current rows resolve a name or avatar for — the exact
    /// key set `makeRows` just looked up. `handleUsersUpdate` filters the
    /// whole-table `usersPublisher` feed against this so an unrelated
    /// profile write doesn't trigger a rows rebuild.
    private var referencedUids: Set<String> = []
    /// uids already asked for over `UPUI`. Rows rebuild on every message
    /// change and every relevant profile change; without this, each rebuild
    /// would re-request the same still-unresolved uid (a profile the server
    /// simply has no `displayName` for never stops looking unresolved — see
    /// `ContactSyncService.fetchUserInfo`'s own note on that trade-off).
    private var requestedProfileUids: Set<String> = []

    public init(
        storage: IMStorage,
        messageSending: MessageSending?,
        imageUploading: ImageUploading?,
        contactSync: ContactInfoFetching? = nil,
        voiceUploading: VoiceUploading? = nil,
        fileUploading: FileUploading? = nil,
        videoUploading: VideoUploading? = nil,
        remoteHistory: RemoteHistoryFetching? = nil,
        activeTracking: ActiveConversationTracking? = nil,
        streaming: StreamingAiObserving? = nil,
        target: String,
        conversationType: ConversationType = .single,
        line: Int = 0,
        pageSize: Int = 30,
        currentUserId: String,
        transcripts: TranscriptEngine? = nil
    ) {
        self.storage = storage
        self.transcripts = transcripts
        self.messageSending = messageSending
        self.contactSync = contactSync
        self.imageUploading = imageUploading
        self.voiceUploading = voiceUploading
        self.fileUploading = fileUploading
        self.videoUploading = videoUploading
        self.remoteHistory = remoteHistory
        self.activeTracking = activeTracking
        self.streaming = streaming
        self.target = target
        self.conversationType = conversationType
        self.line = line
        self.pageSize = pageSize
        self.currentUserId = currentUserId

        cancellable = storage.messages
            .messagesPublisher(conversationType: conversationType, target: target, line: line, limit: pageSize)
            .replaceError(with: [])
            .sink { [weak self] messages in self?.handleMessagesUpdate(messages) }
        // Subscribed *after* the messages feed on purpose: with `.immediate`
        // scheduling the first emission arrives synchronously here, and it
        // needs `referencedUids`/`userCache` already filled by the initial
        // `makeRows` to decide whether anything changed.
        usersCancellable = storage.users.usersPublisher()
            .replaceError(with: [])
            .sink { [weak self] users in self?.handleUsersUpdate(users) }
        bindStreaming()
        fillTailGapIfNeeded()
    }

    /// 尾部断层：该会话上次增量拉取一条都没下发，本地缺的是最新的一段。
    /// 打开会话时立即补拉，补完后断层会下移成普通断层，由 `loadMoreHistory` 接着补。
    private func fillTailGapIfNeeded() {
        guard let remoteHistory,
              (try? storage.gaps.hasTailGap(conversationType: conversationType, target: target, line: line)) == true else { return }
        remoteHistory.fillGap(
            conversationType: conversationType, target: target, line: line,
            beforeUid: Int64.max, count: pageSize
        ) { [weak self] _ in
            self?.reprocessMessages()
        }
    }

    /// 最高的那个普通断层：`messageUid` 低于它的消息与上面的消息不连续，补完前不显示。
    private func visibleFloorUid() -> Int64? {
        try? storage.gaps.visibleFloorUid(conversationType: conversationType, target: target, line: line)
    }

    /// 尚未 ack 的消息（uid 为 0）总是最新的，永远显示。
    private func isVisible(_ message: StoredMessage, floor: Int64?) -> Bool {
        guard let floor else { return true }
        return message.messageUid == 0 || message.messageUid >= floor
    }

    /// A sender's profile resolves asynchronously — the `UPUI` round trip
    /// `requestUnresolvedProfiles` kicks off lands with no accompanying
    /// message event. Driving rows off `messagesPublisher` alone left the
    /// bubble frozen on its uid/no-avatar fallback until a new message
    /// arrived or the screen was popped and re-pushed (`reprocessMessages`
    /// on the second `viewWillAppear`), which is exactly what made this look
    /// intermittent. Only a profile this screen actually renders triggers a
    /// rebuild: `usersPublisher()` observes the entire `user` table, and a
    /// friend-list sync writes hundreds of rows at once.
    private func handleUsersUpdate(_ users: [StoredUser]) {
        guard !referencedUids.isEmpty else { return }
        let changed = users.contains { user in
            guard referencedUids.contains(user.uid) else { return false }
            let cached = userCache[user.uid]
            return cached?.displayName != user.displayName
                || cached?.name != user.name
                || cached?.portrait != user.portrait
        }
        guard changed else { return }
        reprocessMessages()
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
        let pending = PendingVoiceUpload(id: UUID(), audioData: audioData, duration: duration, fileName: fileName, state: .uploading)
        pendingVoices.append(pending)
        publishRows()
        startVoiceUpload(pending)
    }

    private func startVoiceUpload(_ pending: PendingVoiceUpload) {
        voiceUploading?.uploadVoice(pending.audioData, fileName: pending.fileName) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                try? self.messageSending?.sendVoice(to: self.target, conversationType: self.conversationType, line: self.line, remoteURL: url, duration: pending.duration)
                self.pendingVoices.removeAll { $0.id == pending.id }
            case .failure:
                if let index = self.pendingVoices.firstIndex(where: { $0.id == pending.id }) {
                    self.pendingVoices[index].state = .failed
                }
            }
            self.publishRows()
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

    public func sendLocation(lat: Double, lng: Double, title: String, thumbnail: Data?) {
        try? messageSending?.sendLocation(
            to: target, conversationType: conversationType, line: line,
            lat: lat, lng: lng, title: title, thumbnail: thumbnail
        )
    }

    public func sendVideo(videoData: Data, thumbnail: Data, duration: Int) {
        let pending = PendingVideoUpload(id: UUID(), thumbnail: thumbnail, videoData: videoData, duration: duration, state: .uploading)
        pendingVideos.append(pending)
        publishRows()
        startVideoUpload(pending)
    }

    private func startVideoUpload(_ pending: PendingVideoUpload) {
        let fileName = "\(UUID().uuidString).mp4"
        videoUploading?.uploadVideo(pending.videoData, fileName: fileName) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let remoteURL):
                try? self.messageSending?.sendVideo(
                    to: self.target, conversationType: self.conversationType, line: self.line,
                    thumbnail: pending.thumbnail, remoteURL: remoteURL, duration: pending.duration
                )
                self.pendingVideos.removeAll { $0.id == pending.id }
            case .failure:
                if let index = self.pendingVideos.firstIndex(where: { $0.id == pending.id }) {
                    self.pendingVideos[index].state = .failed
                }
            }
            self.publishRows()
        }
    }

    /// Candidate members for the composer's "@" picker — empty for a
    /// non-group conversation. Excludes `.removed` members (same filter
    /// `GroupStore.members(groupId:)` already applies).
    public func groupMemberCandidatesForMention() -> [MentionCandidate] {
        guard conversationType == .group else { return [] }
        let members = (try? storage.groups.members(groupId: target)) ?? []
        return members.map { member in
            let user = try? storage.users.user(uid: member.memberId)
            return MentionCandidate(
                uid: member.memberId,
                displayName: user?.displayName ?? user?.name ?? member.memberId,
                avatarURL: user?.portrait
            )
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
        case .pendingVideo(let pending):
            guard let index = pendingVideos.firstIndex(where: { $0.id == pending.id }) else { return }
            pendingVideos[index].state = .uploading
            publishRows()
            startVideoUpload(pendingVideos[index])
        case .pendingVoice(let pending):
            guard let index = pendingVoices.firstIndex(where: { $0.id == pending.id }) else { return }
            pendingVoices[index].state = .uploading
            publishRows()
            startVoiceUpload(pendingVoices[index])
        case .message(let message):
            guard message.status == .sendFailure else { return }
            try? messageSending?.resend(localMessageId: message.localMessageId)
        case .systemTip, .timeHeader, .streaming:
            break
        }
    }

    public func clearUnread() {
        try? storage.conversations.clearUnread(conversationType: conversationType, target: target, line: line)
    }

    /// 会话详情页可见期间调用(viewWillAppear)——期间到达的新消息不计未读。
    public func markActive() {
        activeTracking?.markConversationActive(conversationType: conversationType, target: target, line: line)
        bindStreaming()
    }

    /// 会话详情页离开时调用(viewWillDisappear),与 `markActive` 成对。
    public func markInactive() {
        activeTracking?.markConversationInactive(conversationType: conversationType, target: target, line: line)
    }

    /// 绑定 SAI 单监听者并恢复未完成的流(init 与 markActive 都调:
    /// 后打开的会话页会覆盖绑定,viewWillAppear 时需要抢回来)。
    private func bindStreaming() {
        guard conversationType == .single, let streaming else { return }
        streaming.onSaiToken = { [weak self] streamId, delta, done, target in
            self?.handleSaiToken(streamId: streamId, delta: delta, done: done, target: target)
        }
        if streamingRow == nil, let stream = streaming.activeStream,
           stream.target == target, !stream.done {
            streamingRow = StreamingRow(streamId: stream.streamId, text: stream.accumulatedText, done: false, senderAvatarURL: agentAvatarURL())
            publishRows()
        }
    }

    /// 占位行头像与真实消息同源(`buildStoredMessageRow` 同样查
    /// `UserStore`);单聊 target 即客服 uid。
    private func agentAvatarURL() -> String? {
        (try? storage.users.user(uid: target))?.portrait
    }

    /// 占位行状态机,分支条件与 Android `ConversationActivity` 的
    /// `setOnSaiTokenListener` 逐条对齐;done 后保留占位行,等真实消息
    /// 入库时在 `handleMessagesUpdate` 里移除。
    private func handleSaiToken(streamId: String, delta: String, done: Bool, target tokenTarget: String) {
        guard tokenTarget == target else { return }
        if !done, delta.isEmpty, streamingRow == nil {
            streamingRow = StreamingRow(streamId: streamId, text: "", done: false, senderAvatarURL: agentAvatarURL())
        } else if !done, !delta.isEmpty, let row = streamingRow, row.streamId == streamId {
            streamingRow = StreamingRow(streamId: streamId, text: row.text + delta, done: false, senderAvatarURL: row.senderAvatarURL)
        } else if done, let row = streamingRow, row.streamId == streamId {
            streamingRow = StreamingRow(streamId: streamId, text: row.text, done: true, senderAvatarURL: row.senderAvatarURL)
        } else {
            return
        }
        publishRows()
    }

    /// Loads one older page of history before the currently-oldest loaded
    /// message. A no-op if nothing is loaded yet or a previous call already
    /// determined there's no more history (`canLoadMore == false`).
    public func loadMore() {
        loadMoreLocalPage()
    }

    /// The pull-to-refresh entry point — mirrors Android's
    /// `ConversationViewModel.loadOldMessages`: page in older history from
    /// local storage first; only when local history is exhausted, fall back
    /// to fetching from the server (`RemoteHistoryFetching`), then page the
    /// newly persisted rows in. `completion` always fires exactly once (on
    /// the main queue), so the caller can end its refresh spinner.
    public func loadMoreHistory(completion: @escaping () -> Void) {
        if loadMoreLocalPage() > 0 { completion(); return }
        // 本地往上翻到了断层：先补断层，补完（或判定已接上）再继续翻本地
        if let remoteHistory, let floor = visibleFloorUid() {
            remoteHistory.fillGap(
                conversationType: conversationType, target: target, line: line,
                beforeUid: floor, count: pageSize
            ) { [weak self] inserted in
                guard let self else { completion(); return }
                if inserted != nil {
                    self.canLoadMore = true
                    self.reprocessMessages()
                    self.loadMoreLocalPage()
                }
                completion()
            }
            return
        }
        guard let remoteHistory, !remoteHistoryExhausted else { completion(); return }
        remoteHistory.loadRemoteMessages(
            conversationType: conversationType, target: target, line: line,
            beforeUid: oldestKnownMessageUid(), count: pageSize
        ) { [weak self] inserted in
            guard let self else { completion(); return }
            switch inserted {
            case .some(let inserted) where inserted > 0:
                // Local paging had just concluded "no more" — the remote
                // fetch disproved that by persisting older rows, so re-arm
                // it and page them in.
                self.canLoadMore = true
                self.loadMoreLocalPage()
            case .some:
                // A successful-but-empty page: history truly ends here.
                self.remoteHistoryExhausted = true
            case .none:
                // The request failed (timeout, server error) — that says
                // nothing about whether older history exists, so leave the
                // latch alone and let the next pull retry.
                break
            }
            completion()
        }
    }

    /// Returns how many rows were prepended (0 when nothing older exists
    /// locally, or nothing is loaded yet to page before).
    @discardableResult
    private func loadMoreLocalPage() -> Int {
        guard canLoadMore, let oldest = (olderRows.first ?? liveRows.first),
              let oldestTimestamp = oldest.timestamp, let oldestId = oldest.storageId else { return 0 }
        let older = (try? storage.messages.olderMessages(
            conversationType: conversationType, target: target, line: line,
            beforeTimestamp: oldestTimestamp, beforeId: oldestId, limit: pageSize
        )) ?? []
        let floor = visibleFloorUid()
        let visible = older.filter { isVisible($0, floor: floor) }
        // 有被断层挡住的消息时不能判定"本地没有更多"，断层补完后还要接着翻
        if older.count < pageSize, visible.count == older.count { canLoadMore = false }
        guard !visible.isEmpty else { return 0 }
        olderMessages.insert(contentsOf: visible, at: 0)
        olderRows = makeRows(olderMessages)
        publishRows()
        return visible.count
    }

    /// The `beforeUid` cursor for a remote-history request: the uid of the
    /// oldest loaded persisted message, whatever it renders as — a recall or
    /// group-notification `.systemTip` line counts too, or a conversation
    /// whose oldest rows are all tips would page "from the newest" and never
    /// reach real history. Pending/unacked rows carry no uid and are skipped;
    /// 0 (an empty conversation) means "from the newest", matching Android's
    /// `loadMoreOldMessages` seeding.
    private func oldestKnownMessageUid() -> Int64 {
        for row in olderRows + liveRows {
            if let uid = row.messageUid { return uid }
        }
        return 0
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

    /// Returns true if the current user may recall this message.
    /// Rule: outgoing acked messages always; incoming group messages when current
    /// user is .manager or .owner of the group.
    public func canRecall(row: StoredMessageRow) -> Bool {
        guard row.messageUid != 0 else { return false }
        if row.isOutgoing { return true }
        guard conversationType == .group else { return false }
        let members = (try? storage.groups.members(groupId: target)) ?? []
        let myMember = members.first { $0.memberId == currentUserId }
        return myMember?.memberType == .manager || myMember?.memberType == .owner
    }

    /// Sends a recall request to the server. On success the message content is
    /// updated to `.recalled` in storage. Calls `completion(false)` immediately
    /// when `messageSending` is nil.
    public func recallMessage(row: StoredMessageRow, completion: @escaping (Bool) -> Void) {
        guard let sending = messageSending else { completion(false); return }
        sending.recall(
            messageUid: row.messageUid,
            storageId: row.storageId,
            conversationType: conversationType,
            target: target,
            line: line,
            completion: completion
        )
    }

    /// Deletes a single message from local storage only. No server request.
    public func deleteMessage(row: StoredMessageRow) {
        try? storage.write { db in
            try storage.messages.deleteMessage(id: row.storageId, db: db)
            try storage.conversations.touchConversation(
                conversationType: conversationType, target: target, line: line, db: db
            )
        }
    }

    /// 他人语音置为已播放（播放或点「转文字」时调用），GRDB 观察会刷新气泡
    public func markPlayed(row: StoredMessageRow) {
        guard !row.isOutgoing, row.status != .played else { return }
        try? storage.messages.markPlayed(id: row.storageId)
    }

    /// Forwards a message to a different conversation, then sends an optional
    /// note as a separate text message. Determines message type by inspecting
    /// the row's fields in priority order: file → voice → video → location →
    /// image → text/call-record.
    public func forward(row: StoredMessageRow, to targetConv: ConversationRow, note: String?) {
        let t = targetConv.target
        let ct = targetConv.conversationType
        let l = targetConv.line

        if let name = row.fileName, let size = row.fileSize, let url = row.imageRemoteURL {
            try? messageSending?.sendFile(to: t, conversationType: ct, line: l, name: name, size: size, remoteURL: url)
        } else if let duration = row.voiceDuration, let url = row.imageRemoteURL {
            try? messageSending?.sendVoice(to: t, conversationType: ct, line: l, remoteURL: url, duration: duration)
        } else if let duration = row.videoDuration, let url = row.imageRemoteURL {
            try? messageSending?.sendVideo(to: t, conversationType: ct, line: l, thumbnail: row.imageThumbnail, remoteURL: url, duration: duration)
        } else if let lat = row.locationLat, let lng = row.locationLng {
            try? messageSending?.sendLocation(to: t, conversationType: ct, line: l, lat: lat, lng: lng, title: row.text ?? "", thumbnail: row.imageThumbnail)
        } else if let url = row.imageRemoteURL {
            try? messageSending?.sendImage(to: t, conversationType: ct, line: l, thumbnail: row.imageThumbnail, remoteURL: url)
        } else if let text = row.text {
            try? messageSending?.sendText(to: t, conversationType: ct, line: l, text: text, mentionedType: 0, mentionedTargets: [])
        }

        if let note, !note.isEmpty {
            try? messageSending?.sendText(to: t, conversationType: ct, line: l, text: note, mentionedType: 0, mentionedTargets: [])
        }
    }

    public func reprocessMessages() {
        handleMessagesUpdate(lastMessages)
    }

    private func handleMessagesUpdate(_ messages: [StoredMessage]) {
        let previousLiveMessages = lastMessages
        lastMessages = messages
        let previousStorageIds = Set((olderMessages + previousLiveMessages).compactMap(\.id))
        // `messagesPublisher` always reports the full current "latest
        // pageSize" window (already ascending), so it wholesale-replaces
        // the live window rather than merging — see `olderMessages`'s doc
        // comment. But once `loadMore()` has paged in real history
        // (`olderMessages` non-empty), anything that was visible in the OLD
        // live window and isn't in the NEW one (because a newer message
        // pushed the window forward) must not simply vanish — migrate it
        // into `olderMessages` instead. Before any paging has happened,
        // `olderMessages` is empty and this migration is skipped on purpose:
        // early on, a burst of writes (e.g. initial backlog sync) can make
        // the live window itself slide forward through several transient
        // intermediate states before the very first page has ever been
        // explicitly requested, and treating every one of those transient
        // slides as a permanent boundary crossing would defeat the "latest
        // pageSize" windowing entirely.
        let newStorageIds = Set(messages.compactMap(\.id))
        // The reverse of eviction: when the conversation holds fewer than
        // pageSize messages, persisting remote history *expands the live
        // window backward* over messages `loadMoreHistory` just paged into
        // `olderMessages`. Keep the two arrays disjoint or `publishRows`
        // emits the same storageId twice — a fatal "supplied item
        // identifiers are not unique" in the diffable data source downstream.
        olderMessages.removeAll { message in
            guard let id = message.id else { return false }
            return newStorageIds.contains(id)
        }
        if !olderMessages.isEmpty {
            let evicted = previousLiveMessages.filter { message in
                guard let id = message.id else { return false }
                return !newStorageIds.contains(id)
            }
            if !evicted.isEmpty {
                olderMessages.append(contentsOf: evicted)
                olderMessages.sort { lhs, rhs in
                    lhs.timestamp == rhs.timestamp
                        ? (lhs.id ?? 0) < (rhs.id ?? 0)
                        : lhs.timestamp < rhs.timestamp
                }
            }
        }
        // 断层补完前，断层下方的消息不显示（见 `visibleFloorUid`）
        let floor = visibleFloorUid()
        olderMessages.removeAll { !isVisible($0, floor: floor) }
        let visibleLive = messages.filter { isVisible($0, floor: floor) }
        // Older + live rebuilt together in one batch (a single bulk user
        // fetch) so `reprocessMessages` refreshes paged-in history too.
        let allRows = makeRows(olderMessages + visibleLive)
        olderRows = Array(allRows.prefix(olderMessages.count))
        liveRows = Array(allRows.suffix(from: olderMessages.count))
        // 真实消息入库到达 → 移除流式占位行(Android 的"原位替换"):
        // 单聊里 target 发来的任何一条新消息都视为流的最终落库形态。
        if streamingRow != nil {
            let hasNewIncoming = liveRows.contains { row in
                guard case .message(let message) = row, !message.isOutgoing else { return false }
                return !previousStorageIds.contains(message.storageId)
            }
            if hasNewIncoming {
                streamingRow = nil
                streaming?.clearActiveStream()
            }
        }
        publishRows()
    }

    private func publishRows() {
        rows = olderRows + liveRows + pendingImages.map { .pendingImage($0) } + pendingVideos.map { .pendingVideo($0) } + pendingVoices.map { .pendingVoice($0) } + (streamingRow.map { [ChatMessageRow.streaming($0)] } ?? [])
    }

    /// Batch entry point over `makeRow`: collects every uid the rows will
    /// resolve (sender avatars, group-notification operators/members, recall
    /// operators) and fetches them in a single `users(uids:)` query into
    /// `userCache` first. Callers must use this instead of mapping `makeRow`
    /// directly — per-row lookups were 30+ serialized reads per rebuild.
    private func makeRows(_ messages: [StoredMessage]) -> [ChatMessageRow] {
        guard !messages.isEmpty else { return [] }
        var uids: Set<String> = [currentUserId]
        for message in messages {
            uids.insert(message.from)
            switch message.content {
            case .groupNotification(_, let operatorUid, let memberUids, _):
                uids.insert(operatorUid)
                uids.formUnion(memberUids)
            case .recalled(let operatorId):
                uids.insert(operatorId)
            default:
                break
            }
        }
        let fetched = (try? storage.users.users(uids: Array(uids))) ?? []
        userCache = Dictionary(uniqueKeysWithValues: fetched.map { ($0.uid, $0) })
        referencedUids = uids
        requestUnresolvedProfiles(uids)
        return messages.map(makeRow)
    }

    /// Asks the server for any referenced profile `UserStore` can't render.
    /// Group senders are the case that matters: `IMGroups` only ever syncs
    /// membership (uid + role) and never writes `UserStore`, so a member who
    /// isn't a friend has no profile at all and nothing else on this screen's
    /// path would ever fetch one.
    ///
    /// `displayName == nil` (not row-absence) is the unresolved test, matching
    /// `ContactSyncService.fetchUserInfo`: `FriendSyncHandler` writes an
    /// all-nil placeholder row for a newly-flagged friend, and a
    /// presence-only check would mistake that for a resolved profile.
    private func requestUnresolvedProfiles(_ uids: Set<String>) {
        guard let contactSync else { return }
        let unresolved = uids.filter { uid in
            !requestedProfileUids.contains(uid) && userCache[uid]?.displayName == nil
        }
        guard !unresolved.isEmpty else { return }
        requestedProfileUids.formUnion(unresolved)
        contactSync.fetchUserInfo(uids: Array(unresolved), forceRefresh: false)
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
                messageUid: message.messageUid,
                text: renderSystemTipText(type: type, operatorUid: operatorUid, memberUids: memberUids, value: value),
                timestamp: message.timestamp
            ))
        case .callRecord(_, _, let audioOnly, let status, let connectTime, let endTime):
            return .message(buildStoredMessageRow(message, text: renderCallRecordText(isOutgoing: message.direction == .send, audioOnly: audioOnly, status: status, connectTime: connectTime, endTime: endTime), imageThumbnail: nil, imageRemoteURL: nil))
        case .voice(let remoteURL, _, let duration):
            return .message(buildStoredMessageRow(message, text: "[语音] \(duration)秒",
                imageThumbnail: nil, imageRemoteURL: remoteURL, voiceDuration: duration))
        case .file(let rawName, let size, let remoteURL, _):
            // 兄弟客户端（electron 等）会把「[文件] 名字」整串写进 searchableContent，
            // 行内只保留纯文件名（展示、下载路径、转发共用）
            let name = rawName.hasPrefix("[文件]")
                ? String(rawName.dropFirst("[文件]".count)).trimmingCharacters(in: .whitespaces)
                : rawName
            let sizeStr = size > 1024*1024 ? String(format: "%.1fMB", Double(size)/1024/1024) : "\(size/1024)KB"
            return .message(buildStoredMessageRow(message, text: "[文件] \(name) \(sizeStr)",
                imageThumbnail: nil, imageRemoteURL: remoteURL, fileSize: size, fileName: name))
        case .video(let thumbnail, let remoteURL, _, let duration):
            return .message(buildStoredMessageRow(message, text: nil, imageThumbnail: thumbnail, imageRemoteURL: remoteURL, videoDuration: duration))
        case .recalled(let operatorId):
            let displayName = resolveDisplayName(operatorId)
            return .systemTip(SystemTipRow(
                storageId: message.id ?? -1,
                messageUid: message.messageUid,
                text: "\(displayName)撤回了一条消息",
                timestamp: message.timestamp
            ))
        case .location(let lat, let lng, let title, let thumbnail):
            return .message(buildStoredMessageRow(
                message,
                text: title,
                imageThumbnail: thumbnail,
                imageRemoteURL: nil,
                locationLat: lat,
                locationLng: lng
            ))
        }
    }

    private func buildStoredMessageRow(
        _ message: StoredMessage,
        text: String?,
        imageThumbnail: Data?,
        imageRemoteURL: String?,
        videoDuration: Int? = nil,
        voiceDuration: Int? = nil,
        fileSize: Int? = nil,
        fileName: String? = nil,
        locationLat: Double? = nil,
        locationLng: Double? = nil
    ) -> StoredMessageRow {
        var senderDisplayName: String?
        // Always resolve the avatar — own portrait for outgoing, sender's for incoming.
        let avatarUid = message.direction == .send ? currentUserId : message.from
        let user = userCache[avatarUid]
        let senderAvatarURL = user?.portrait
        // Sender name only appears in group incoming bubbles, and only when the user hasn't turned off the setting.
        if conversationType == .group, message.direction == .receive {
            let key = "showMemberNicknames_\(target)"
            let showNicknames = UserDefaults.standard.object(forKey: key) as? Bool ?? true
            if showNicknames {
                senderDisplayName = user?.displayName ?? user?.name ?? message.from
            }
        }
        return StoredMessageRow(
            storageId: message.id ?? -1,
            localMessageId: message.localMessageId,
            messageUid: message.messageUid,
            isOutgoing: message.direction == .send,
            status: message.status,
            timestamp: message.timestamp,
            text: text,
            imageThumbnail: imageThumbnail,
            imageRemoteURL: imageRemoteURL,
            senderDisplayName: senderDisplayName,
            senderAvatarURL: senderAvatarURL,
            senderUid: message.direction == .receive ? message.from : nil,
            videoDuration: videoDuration,
            voiceDuration: voiceDuration,
            fileSize: fileSize,
            fileName: fileName,
            locationLat: locationLat,
            locationLng: locationLng
        )
    }

    /// `uid == currentUserId` renders as "您" — matches every Android
    /// group-notification template, which substitutes the first-person
    /// pronoun for the acting user's own actions.
    private func resolveDisplayName(_ uid: String) -> String {
        guard uid != currentUserId else { return "您" }
        guard let user = userCache[uid] else { return uid }
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
        case .text, .image, .video, .callStart, .voice, .file, .recalled, .location:
            return "" // unreachable: makeRow only calls this for .groupNotification content
        }
    }

    /// Bubble text for a `.callRecord` row — design doc §2's rule: status 2
    /// with a real `connectTime` shows duration; status 2 with no
    /// `connectTime` (call never connected) shows "已取消" from the caller's
    /// side, "未接听" from the callee's side. Status 0/1 rows are only ever
    /// momentarily on screen mid-call (this device's own `CallManager`
    /// updates them to status 2 the instant the call ends) and don't need
    /// distinct wording. Status 3 (对齐 Android `VoipMessageViewHolder`) is
    /// `CallManager.endSession`'s `.acceptedElsewhere` outcome — this device
    /// was still ringing when the account's other device answered, so it's
    /// wrong to show "未接听"(它其实被接听了,只是接在别处)。
    private func renderCallRecordText(isOutgoing: Bool, audioOnly: Bool, status: Int, connectTime: Int64, endTime: Int64) -> String {
        let icon = audioOnly ? "📞" : "📹"
        let kind = audioOnly ? "语音通话" : "视频通话"
        if status == 3 { return "\(icon) 已在其他设备接听" }
        guard status == 2 else { return "\(icon) \(kind)" }
        guard connectTime > 0 else { return isOutgoing ? "\(icon) 已取消" : "\(icon) 未接听" }
        let durationSeconds = Int(max(0, (endTime - connectTime) / 1000))
        return String(format: "\(icon) \(kind) %02d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
}
