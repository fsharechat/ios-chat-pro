// Sources/IMContacts/FriendNotifyHandler.swift
import IMClient
import IMTransport

/// Handles `PUBLISH`/`.fn` — an unprompted server push meaning "your friend
/// relationships changed" (e.g. someone accepted your friend request, or you
/// accepted theirs on another device). Mirrors Android's
/// `NotifyFriendHandler`, which re-pulls the full friend list and refreshes
/// friend requests on this signal. The 8-byte big-endian body (a head value,
/// same wire shape as `.frn`) carries nothing the full re-pull doesn't
/// already resolve, so it's intentionally not decoded — the `.frn` path owns
/// `syncState.friendRequestHead`.
///
/// **Threading contract:** like the rest of this codebase, this has no
/// internal locking and must be called from a single consistent queue.
public final class FriendNotifyHandler: MessageHandler {
    public var onFriendListUpdateNotified: (() -> Void)?

    public init() {}

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .publish && subSignal == .fn
    }

    public func handle(frame: Frame) {
        onFriendListUpdateNotified?()
    }
}
