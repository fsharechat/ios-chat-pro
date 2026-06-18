import Foundation

/// Generates the client-side `local_message_id` embedded in outgoing
/// messages (used for send/ack dedup — see `chat-proto`'s
/// `Message.local_message_id` and `IMStorage`'s partial-unique-index design
/// in Plan C Task 2/4). Loosely inspired by Android's
/// `MessageShardingUtil.generateId()` (timestamp + rotating counter), but
/// the exact bit layout does not need to match: this id is never parsed by
/// the server, only stored/echoed back opaquely as an `int64`, and
/// `IMStorage`'s uniqueness guarantee is already scoped per-sender (this
/// device), not global — see this plan's "Reference facts" above.
///
/// **Threading contract:** like the rest of this codebase (see `IMClient`'s
/// own threading-contract doc comment), this has no internal locking and
/// must be called from a single consistent queue.
public final class LocalMessageIdGenerator {
    private var lastTimestampMillis: Int64 = 0
    private var sequence: Int64 = 0

    public init() {}

    /// `now`-injectable for tests; production callers use the default.
    public func next(now: Date = Date()) -> Int64 {
        let currentMillis = Int64(now.timeIntervalSince1970 * 1000)
        if currentMillis == lastTimestampMillis {
            sequence += 1
        } else {
            lastTimestampMillis = currentMillis
            sequence = 0
        }
        // 12 low bits for the per-millisecond sequence (4096 ids/ms before
        // wrapping, at which point two ids within the same ms could collide
        // — acceptable for this app's send rate).
        return (currentMillis << 12) | (sequence & 0xFFF)
    }
}
