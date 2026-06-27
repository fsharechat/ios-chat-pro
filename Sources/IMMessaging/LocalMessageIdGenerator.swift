import Foundation

/// Generates the client-side `local_message_id` embedded in outgoing
/// messages (used for send/ack dedup — see `chat-proto`'s
/// `Message.local_message_id` and `IMStorage`'s partial-unique-index design
/// in Plan C Task 2/4).
///
/// **Format:** mirrors Android's `MessageShardingUtil.generateId()` exactly
/// so that iOS and Android IDs occupy the same numeric range and sort
/// correctly when Android orders messages by `message_id DESC`:
///
///   bit layout:  [ timestamp(43) | nodeId(6) | rotateId(15) ]
///   epoch:       2018-01-01 00:00:00 UTC (same constant as Android)
///   nodeId:      0 (mobile has no distributed-node concept)
///   rotateId:    monotonically increasing 15-bit counter, wraps at 32767
///
/// **Threading contract:** like the rest of this codebase (see `IMClient`'s
/// own threading-contract doc comment), this has no internal locking and
/// must be called from a single consistent queue.
public final class LocalMessageIdGenerator {
    // 2018-01-01 00:00:00 UTC — matches Android's T201801010000 constant.
    private static let epoch: Int64 = 1_514_736_000_000
    private static let nodeId: Int64 = 0
    private static let nodeIdWidth: Int = 6
    private static let rotateIdWidth: Int = 15
    private static let rotateIdMask: Int64 = 0x7FFF  // 32767

    private var rotateId: Int64 = 0

    public init() {}

    /// `now`-injectable for tests; production callers use the default.
    public func next(now: Date = Date()) -> Int64 {
        rotateId = (rotateId + 1) & Self.rotateIdMask
        var id = Int64(now.timeIntervalSince1970 * 1000) - Self.epoch
        id <<= Self.nodeIdWidth
        id += Self.nodeId
        id <<= Self.rotateIdWidth
        id += rotateId
        return id
    }
}
