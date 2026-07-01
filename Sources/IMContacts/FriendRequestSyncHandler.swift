// Sources/IMContacts/FriendRequestSyncHandler.swift
import IMClient
import IMTransport
import IMProto
import IMStorage

/// Handles two distinct wire messages that both relate to keeping the
/// local `friendRequest` table in sync:
///
/// - `PUB_ACK`/`.frp`: the response to a `syncFriendRequests()` pull.
///   Standard "1 byte error code, then protobuf" format. Upserts every
///   entry, then advances `syncState.friendRequestHead` to the batch's max
///   `updateDt` — but only if the batch is non-empty (an empty pull result
///   carries no information about the true head, so leaving it alone is
///   the correct "do nothing" response).
/// - `PUBLISH`/`.frn`: an unprompted server push ("something about your
///   friend requests changed"), matching `NotifyMessageHandler`'s
///   `.publish`-not-`.pubAck` shape for unprompted pushes. The body is a
///   raw 8-byte big-endian `Int64`, with **no** leading error-code byte —
///   this is a `PUBLISH`, not a `PUB_ACK` response, so that convention
///   doesn't apply. Decoded via manual byte-shifting (mirroring
///   `Header.decode`'s big-endian field decoding) rather than
///   `withUnsafeBytes`, which would have alignment-UB risk on arbitrary
///   `Data` slices. The decoded value minus 1 is written directly to
///   `syncState.friendRequestHead` (matching Android's own client) — the
///   `-1` means the next `syncFriendRequests()` pull's strict
///   greater-than-style comparison on the server doesn't skip the request
///   that exactly produced this new head value. `onRemoteUpdateNotified`
///   is then invoked so the caller (`ContactSyncService`) can trigger a
///   follow-up `syncFriendRequests()` pull to fetch the actual content.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class FriendRequestSyncHandler: MessageHandler {
    public var onRemoteUpdateNotified: (() -> Void)?

    private let storage: IMStorage
    private let myUid: String

    public init(storage: IMStorage, myUid: String) {
        self.storage = storage
        self.myUid = myUid
    }

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        (signal == .pubAck && subSignal == .frp) || (signal == .publish && subSignal == .frn)
    }

    public func handle(frame: Frame) {
        if frame.header.signal == .pubAck {
            handlePullResponse(frame: frame)
        } else {
            handleRemoteNotify(frame: frame)
        }
    }

    private func handlePullResponse(frame: Frame) {
        guard let errorCode = frame.body.first, errorCode == 0 else { return }
        guard let result = try? Im_GetFriendRequestResult(serializedBytes: frame.body.dropFirst()) else { return }
        guard !result.entry.isEmpty else { return }

        // On the initial sync (head == 0), treat all imported requests as already
        // read locally so the badge doesn't show stale historical counts on first login.
        let isInitialSync = (try? storage.syncState.get())?.friendRequestHead == 0

        // The server may include outgoing requests (toUid != myUid) in the batch.
        // Only persist incoming requests to avoid duplicate fromUid rows in the table,
        // which would produce identical FriendRequestRow identifiers and crash the
        // DiffableDataSource. Still advance the head using ALL entries so we don't
        // re-fetch the filtered-out outgoing records on the next pull.
        for entry in result.entry where entry.toUid == myUid {
            let request = StoredFriendRequest(
                fromUid: entry.fromUid,
                toUid: entry.toUid,
                reason: entry.reason,
                status: Int(entry.status),
                updateDt: entry.updateDt,
                fromReadStatus: entry.fromReadStatus,
                toReadStatus: isInitialSync ? true : entry.toReadStatus
            )
            // Accepted Phase-2 gap: a failed upsert for one row is silently
            // dropped (no logging facility yet), same as every other
            // PUB_ACK handler in this codebase.
            try? storage.friendRequests.upsert(request)
        }

        guard let maxUpdateDt = result.entry.map(\.updateDt).max() else { return }
        guard var syncState = try? storage.syncState.get() else { return }
        syncState.friendRequestHead = maxUpdateDt
        try? storage.syncState.set(syncState)
    }

    private func handleRemoteNotify(frame: Frame) {
        guard frame.body.count >= 8 else { return }
        let bytes = [UInt8](frame.body.prefix(8))
        var value: Int64 = 0
        for byte in bytes {
            value = (value << 8) | Int64(byte)
        }

        guard var syncState = try? storage.syncState.get() else { return }
        syncState.friendRequestHead = value - 1
        try? storage.syncState.set(syncState)

        onRemoteUpdateNotified?()
    }
}
