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
    private let target: String
    private let conversationType: ConversationType
    private let line: Int
    private let pageSize: Int

    /// Older history loaded via `loadMore`, strictly before `liveRows` —
    /// `olderMessages` is one-shot (not reactive), so these are frozen at
    /// fetch time and only ever grow at the front via further `loadMore`
    /// calls. Once non-empty (i.e. paging has started), it also grows when
    /// `handleMessagesUpdate` evicts a row from `liveRows` (see that
    /// property's doc comment): once a message has ever been shown after
    /// paging began, it's migrated here rather than dropped, so it stays
    /// visible even after it falls out of the live window.
    ///
    /// Accepted Phase-1 gap: this uses `olderRows.isEmpty` as a proxy for
    /// "has the user ever paged via `loadMore`". A conversation that starts
    /// with fewer than `pageSize` messages and grows one at a time without
    /// the user ever scrolling up (nothing to page in yet) can still lose
    /// its earliest message the first time the live window naturally
    /// exceeds `pageSize` — `olderRows` is still empty at that point, so
    /// the eviction is (incorrectly) treated as transient cold-start churn
    /// rather than migrated. Narrow edge case (requires a fresh
    /// under-`pageSize` conversation that organically grows past it with
    /// no pagination in between); not fixed for Phase 1.
    private var olderRows: [StoredMessageRow] = []
    /// The current page from `messagesPublisher` — a sliding "latest
    /// `pageSize`" window, so each emission **replaces** this array wholesale
    /// (rather than merging into it). Before `loadMore` has ever paged in
    /// history (`olderRows` empty), a message that scrolls out of this
    /// window is simply dropped from here with no special handling — early
    /// on, a burst of writes (e.g. initial backlog sync) can slide the live
    /// window through several transient intermediate states before the user
    /// has done anything, and none of those transient rows were ever
    /// durably "shown". Once paging has started, though, a message that
    /// scrolls out is never simply dropped: `handleMessagesUpdate` detects
    /// rows present in the old `liveRows` but absent from the new emission
    /// and migrates them into `olderRows` first, so a message that has ever
    /// been visible since paging began can't silently disappear from `rows`.
    private var liveRows: [StoredMessageRow] = []
    private var pendingImages: [PendingImageUpload] = []
    private var cancellable: AnyCancellable?

    public init(
        storage: IMStorage,
        messageSending: MessageSending?,
        imageUploading: ImageUploading?,
        target: String,
        conversationType: ConversationType = .single,
        line: Int = 0,
        pageSize: Int = 30
    ) {
        self.storage = storage
        self.messageSending = messageSending
        self.imageUploading = imageUploading
        self.target = target
        self.conversationType = conversationType
        self.line = line
        self.pageSize = pageSize

        cancellable = storage.messages
            .messagesPublisher(conversationType: conversationType, target: target, line: line, limit: pageSize)
            .replaceError(with: [])
            .sink { [weak self] messages in self?.handleMessagesUpdate(messages) }
    }

    /// Failure (e.g. serialization, or no `messageSending` configured) is
    /// silently dropped — accepted Phase-1 gap, no logging facility yet,
    /// same as `ContactSyncService`/`FriendSyncHandler` elsewhere.
    public func sendText(_ text: String) {
        try? messageSending?.sendText(to: target, conversationType: conversationType, line: line, text: text, mentionedType: 0, mentionedTargets: [])
    }

    public func sendImage(fullImageData: Data, thumbnail: Data) {
        let pending = PendingImageUpload(id: UUID(), thumbnail: thumbnail, fullImageData: fullImageData, state: .uploading)
        pendingImages.append(pending)
        publishRows()
        startUpload(pending)
    }

    /// Retries a failed send: a `.pendingImage` row re-runs the upload from
    /// scratch; a `.message` row with `status == .sendFailure` re-sends the
    /// already-stored row via `MessageSending.resend(localMessageId:)`. A
    /// no-op for any other row/status combination.
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
        }
    }

    /// Loads one older page of history before the currently-oldest loaded
    /// message. A no-op if nothing is loaded yet or a previous call already
    /// determined there's no more history (`canLoadMore == false`).
    public func loadMore() {
        guard canLoadMore, let oldest = (olderRows.first ?? liveRows.first) else { return }
        let older = (try? storage.messages.olderMessages(
            conversationType: conversationType, target: target, line: line,
            beforeTimestamp: oldest.timestamp, beforeId: oldest.storageId, limit: pageSize
        )) ?? []
        if older.count < pageSize { canLoadMore = false }
        guard !older.isEmpty else { return }
        olderRows.insert(contentsOf: older.map(Self.makeRow), at: 0)
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
        let newLiveRows = messages.map(Self.makeRow)
        let newStorageIds = Set(newLiveRows.map { $0.storageId })
        if !olderRows.isEmpty {
            let evicted = liveRows.filter { !newStorageIds.contains($0.storageId) }
            if !evicted.isEmpty {
                olderRows.append(contentsOf: evicted)
                olderRows.sort { $0.timestamp == $1.timestamp ? $0.storageId < $1.storageId : $0.timestamp < $1.timestamp }
            }
        }
        liveRows = newLiveRows
        publishRows()
    }

    private func publishRows() {
        rows = olderRows.map { .message($0) } + liveRows.map { .message($0) } + pendingImages.map { .pendingImage($0) }
    }

    /// `message.id` is always non-nil for a row fetched back from the
    /// database (`FetchableRecord` only ever omits it before insertion) —
    /// the `-1` fallback is unreachable in practice, not a real sentinel.
    private static func makeRow(_ message: StoredMessage) -> StoredMessageRow {
        var text: String?
        var imageThumbnail: Data?
        var imageRemoteURL: String?
        switch message.content {
        case .text(let value):
            text = value
        case .image(let thumbnail, let remoteURL, _):
            imageThumbnail = thumbnail
            imageRemoteURL = remoteURL
        case .groupNotification:
            // No dedicated row field for group notifications yet (left to a
            // later task in this plan to design proper rendering) — fall
            // back to the same "[群通知]" digest already computed onto
            // `searchableContent` by `StoredMessage.init`, just so this
            // switch stays exhaustive and the row shows something sane.
            text = message.searchableContent
        }
        return StoredMessageRow(
            storageId: message.id ?? -1,
            localMessageId: message.localMessageId,
            isOutgoing: message.direction == .send,
            status: message.status,
            timestamp: message.timestamp,
            text: text,
            imageThumbnail: imageThumbnail,
            imageRemoteURL: imageRemoteURL
        )
    }
}
