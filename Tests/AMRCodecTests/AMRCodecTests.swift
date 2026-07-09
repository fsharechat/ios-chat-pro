import XCTest
import AMRCodec

final class AMRCodecTests: XCTestCase {
    /// 8 kHz mono PCM sine wave, `frames` × 160 samples (20 ms per AMR frame).
    private func makeSine(frames: Int, hz: Double = 440, amplitude: Double = 8000) -> [Int16] {
        (0..<(frames * 160)).map { i in
            Int16(amplitude * sin(2 * .pi * hz * Double(i) / 8000))
        }
    }

    func test_encode_producesOneMR122FrameOf32BytesPer160Samples() {
        let frames = 50
        let pcm = makeSine(frames: frames)
        guard let encoder = Encoder_Interface_init(0) else {
            return XCTFail("Encoder_Interface_init failed")
        }
        defer { Encoder_Interface_exit(encoder) }

        var out = [UInt8](repeating: 0, count: 64)
        var total = 0
        pcm.withUnsafeBufferPointer { buf in
            for f in 0..<frames {
                let n = Encoder_Interface_Encode(encoder, MR122, buf.baseAddress! + f * 160, &out, 0)
                XCTAssertEqual(n, 32, "MR122 frame should be 32 bytes (incl. 1 TOC byte)")
                total += Int(n)
            }
        }
        XCTAssertEqual(total, frames * 32)
    }

    func test_encodeDecodeRoundTrip_preservesSignalEnergy() {
        let frames = 50
        let pcm = makeSine(frames: frames)
        guard let encoder = Encoder_Interface_init(0),
              let decoder = Decoder_Interface_init() else {
            return XCTFail("codec init failed")
        }
        defer {
            Encoder_Interface_exit(encoder)
            Decoder_Interface_exit(decoder)
        }

        var amr = Data()
        var out = [UInt8](repeating: 0, count: 64)
        pcm.withUnsafeBufferPointer { buf in
            for f in 0..<frames {
                let n = Encoder_Interface_Encode(encoder, MR122, buf.baseAddress! + f * 160, &out, 0)
                amr.append(contentsOf: out[0..<Int(n)])
            }
        }

        var decoded = [Int16]()
        var pcmOut = [Int16](repeating: 0, count: 160)
        amr.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 32 <= raw.count {
                let framePtr = raw.baseAddress!.advanced(by: offset)
                    .assumingMemoryBound(to: UInt8.self)
                Decoder_Interface_Decode(decoder, framePtr, &pcmOut, 0)
                decoded.append(contentsOf: pcmOut)
                offset += 32
            }
        }

        XCTAssertEqual(decoded.count, frames * 160)
        // Lossy codec: don't compare sample-by-sample, just require the decoded
        // signal to be clearly non-silent (a broken pipeline yields ~0 energy).
        let meanSquare = decoded.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(decoded.count)
        XCTAssertGreaterThan(meanSquare, 100_000, "decoded audio should carry real signal energy")
    }
}
