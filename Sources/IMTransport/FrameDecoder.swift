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

    public init() {}

    /// Feed newly-received bytes; returns zero or more frames that became
    /// complete as a result. Safe to call repeatedly with arbitrarily-sized
    /// chunks, including single bytes or many frames at once.
    public func feed(_ data: Data) -> [Frame] {
        buffer.append(contentsOf: data)
        var frames: [Frame] = []

        while true {
            guard buffer.count >= Header.length else { break }

            guard let header = Header.decode(Data(buffer.prefix(Header.length))) else {
                // Bad magic byte: the stream is desynchronized. There is no
                // safe resync point, so drop everything buffered so far
                // rather than spinning on the same invalid bytes forever.
                buffer.removeAll()
                break
            }

            let totalLength = Header.length + Int(header.bodyLength)
            guard buffer.count >= totalLength else { break }

            let body = Data(buffer[Header.length..<totalLength])
            frames.append(Frame(header: header, body: body))
            buffer.removeFirst(totalLength)
        }

        return frames
    }
}
