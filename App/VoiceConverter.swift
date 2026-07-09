import AMRCodec
import AudioToolbox
import Foundation

/// Converts an audio file (e.g. M4A/AAC) to AMR-NB format. AMR-NB is the
/// format expected by Android/Web SoundMessageContent receivers.
///
/// Apple platforms ship an AMR *decoder* but no *encoder* — ExtAudioFile can
/// create an AMR container but writes zero frames (a 6-byte `#!AMR\n` file).
/// Encoding therefore goes through the vendored opencore-amr encoder:
/// ExtAudioFile decodes/resamples the input to 8 kHz mono PCM, and
/// `Encoder_Interface_Encode` produces the AMR frames.
enum VoiceConverter {
    /// AMR-NB single-channel magic header (RFC 4867).
    private static let amrMagic = Data("#!AMR\n".utf8)
    /// One AMR frame encodes 160 samples = 20 ms at 8 kHz.
    private static let samplesPerFrame = 160

    static func convertToAMR(from inputURL: URL) -> Data? {
        var inputRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(inputURL as CFURL, &inputRef) == noErr,
              let inputRef else { return nil }
        defer { ExtAudioFileDispose(inputRef) }

        // Client format: 16-bit signed PCM at 8 kHz mono.
        // ExtAudioFile resamples the input automatically to match.
        var pcmASBD = AudioStreamBasicDescription(
            mSampleRate: 8000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        guard ExtAudioFileSetProperty(inputRef, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout.size(ofValue: pcmASBD)), &pcmASBD) == noErr
        else { return nil }

        // Decode the whole file to PCM.
        var pcm = [Int16]()
        let bufByteSize: UInt32 = 8192
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: Int(bufByteSize) / 2)
        defer { buf.deallocate() }

        while true {
            var frames: UInt32 = bufByteSize / 2 // mono 16-bit: 2 bytes/frame
            var abl = AudioBufferList(mNumberBuffers: 1,
                                     mBuffers: AudioBuffer(mNumberChannels: 1,
                                                           mDataByteSize: bufByteSize,
                                                           mData: buf))
            guard ExtAudioFileRead(inputRef, &frames, &abl) == noErr, frames > 0 else { break }
            pcm.append(contentsOf: UnsafeBufferPointer(start: buf, count: Int(frames)))
        }
        guard !pcm.isEmpty else { return nil }

        // Zero-pad the tail so the last partial frame still encodes.
        let remainder = pcm.count % samplesPerFrame
        if remainder != 0 {
            pcm.append(contentsOf: repeatElement(0, count: samplesPerFrame - remainder))
        }

        guard let encoder = Encoder_Interface_init(0) else { return nil }
        defer { Encoder_Interface_exit(encoder) }

        var amr = amrMagic
        var frameOut = [UInt8](repeating: 0, count: 64)
        pcm.withUnsafeBufferPointer { samples in
            var offset = 0
            while offset + samplesPerFrame <= samples.count {
                let n = Encoder_Interface_Encode(encoder, MR122,
                                                 samples.baseAddress! + offset, &frameOut, 0)
                if n > 0 { amr.append(contentsOf: frameOut[0..<Int(n)]) }
                offset += samplesPerFrame
            }
        }
        return amr.count > amrMagic.count ? amr : nil
    }

    /// Decodes an AMR-NB data blob to a temporary WAV file that AVAudioPlayer
    /// can play. iOS can always decode AMR (it's a cellular telephony codec),
    /// but AVAudioPlayer on recent iOS versions refuses to open the raw .amr
    /// container — decoding via ExtAudioFile sidesteps that restriction.
    /// The caller must delete the returned URL after playback completes.
    static func convertAMRToWAV(data: Data) -> URL? {
        let amrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".amr")
        guard (try? data.write(to: amrURL)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: amrURL) }

        var inputRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(amrURL as CFURL, &inputRef) == noErr,
              let inputRef else { return nil }
        defer { ExtAudioFileDispose(inputRef) }

        var pcmASBD = AudioStreamBasicDescription(
            mSampleRate: 8000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        ExtAudioFileSetProperty(inputRef, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout.size(ofValue: pcmASBD)), &pcmASBD)

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        var outputRef: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(wavURL as CFURL, kAudioFileWAVEType, &pcmASBD, nil,
                                        AudioFileFlags.eraseFile.rawValue, &outputRef) == noErr,
              let outputRef else { return nil }

        let bufByteSize: UInt32 = 8192
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: Int(bufByteSize) / 2)
        defer { buf.deallocate() }

        while true {
            var frames: UInt32 = bufByteSize / 2
            var abl = AudioBufferList(mNumberBuffers: 1,
                                     mBuffers: AudioBuffer(mNumberChannels: 1,
                                                           mDataByteSize: bufByteSize,
                                                           mData: buf))
            guard ExtAudioFileRead(inputRef, &frames, &abl) == noErr, frames > 0 else { break }
            abl.mBuffers.mDataByteSize = frames * 2
            guard ExtAudioFileWrite(outputRef, frames, &abl) == noErr else { break }
        }

        ExtAudioFileDispose(outputRef)
        return wavURL
    }
}
