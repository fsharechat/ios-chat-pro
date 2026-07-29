import Foundation

/// Buffers a raw incoming byte stream and emits complete `Frame`s as they
/// become available. Not thread-safe — callers must serialize access
/// (by convention, `IMClient` and its transport both default to delivering
/// on the main queue — see `IMClient`'s threading-contract doc comment).
///
/// Buffer is a plain `[UInt8]` rather than `Data` on purpose: `Data` does not
/// guarantee `startIndex == 0` after slicing/`removeSubrange`, which makes
/// absolute-offset indexing unsafe. `Array`'s `startIndex` is always `0`.
public final class FrameDecoder {
    private var buffer: [UInt8] = []

    /// Fired whenever `feed` returns with a *partially* received frame still
    /// in the buffer: its 10-byte header is complete (so `signal`,
    /// `subSignal` and `messageId` are already known) but its body isn't.
    /// Arguments: that header, and how many body bytes have arrived so far.
    ///
    /// This is the only place a large in-flight response is observable
    /// before it completes — a 180 KB history page takes seconds to stream
    /// in over a slow link, and without this the layers above see nothing at
    /// all until the very last byte lands. `IMMessaging` uses it to keep an
    /// idle-timeout alive while its response is demonstrably still arriving.
    public var onPartialFrameProgress: ((Header, Int) -> Void)?

    public init() {}

    /// Drops everything buffered so far. Call when the underlying byte
    /// stream is replaced (a new connection): leftover bytes from a frame
    /// that was cut off mid-transfer would otherwise be prepended to the new
    /// stream, desynchronising it until the magic-byte check below throws
    /// the whole buffer away — taking any healthy frames buffered behind it
    /// along with it.
    public func reset() {
        buffer.removeAll()
    }

    /// Feed newly-received bytes; returns zero or more frames that became
    /// complete as a result. Safe to call repeatedly with arbitrarily-sized
    /// chunks, including single bytes or many frames at once.
    public func feed(_ data: Data) -> [Frame] {
        buffer.append(contentsOf: data)
        print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] FrameDecoder.feed: +\(data.count) bytes, buffer now \(buffer.count) bytes")
        var frames: [Frame] = []

        while true {
            guard buffer.count >= Header.length else {
                print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] FrameDecoder: \(buffer.count) bytes left, waiting for more (need \(Header.length) header bytes)")
                break
            }

            guard let header = Header.decode(Data(buffer.prefix(Header.length))) else {
                // Bad magic byte: the stream is desynchronized. There is no
                // safe resync point, so drop everything buffered so far
                // rather than spinning on the same invalid bytes forever.
                print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] FrameDecoder: BAD MAGIC BYTE, discarding \(buffer.count) buffered bytes: \(buffer.prefix(16).map { String(format: "%02x", $0) }.joined())")
                buffer.removeAll()
                break
            }

            let totalLength = Header.length + Int(header.bodyLength)
            guard buffer.count >= totalLength else {
                print("[DEBUG-FP][\({ let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date()) }())] FrameDecoder: have \(buffer.count) bytes, need \(totalLength) for signal=\(header.signal) subSignal=\(header.subSignal) bodyLength=\(header.bodyLength) — waiting for more")
                onPartialFrameProgress?(header, buffer.count - Header.length)
                break
            }

            let body = Data(buffer[Header.length..<totalLength])
            frames.append(Frame(header: header, body: body))
            buffer.removeFirst(totalLength)
        }

        return frames
    }
}
