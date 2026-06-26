import AudioToolbox
import Foundation

/// Converts an audio file (e.g. M4A/AAC) to AMR-NB format using the
/// iOS ExtAudioFile API. AMR-NB is the format expected by Android/Web
/// SoundMessageContent receivers. Returns nil on devices or simulators
/// where the AMR encoder is unavailable — callers should fall back to
/// sending the original M4A in that case.
enum VoiceConverter {
    static func convertToAMR(from inputURL: URL) -> Data? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".amr")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var inputRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(inputURL as CFURL, &inputRef) == noErr,
              let inputRef else { return nil }
        defer { ExtAudioFileDispose(inputRef) }

        // AMR-NB: 8 kHz, mono, 160 frames/packet.
        // kAudioFileAMRType = 'amrf' = 0x616D7266
        var amrASBD = AudioStreamBasicDescription(
            mSampleRate: 8000, mFormatID: kAudioFormatAMR,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 160,
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        var outputRef: ExtAudioFileRef?
        let amrFileType: AudioFileTypeID = 0x616D7266 // 'amrf'
        guard ExtAudioFileCreateWithURL(tempURL as CFURL, amrFileType, &amrASBD, nil,
                                        AudioFileFlags.eraseFile.rawValue, &outputRef) == noErr,
              let outputRef else { return nil }

        // Client format: 16-bit signed PCM at 8 kHz.
        // ExtAudioFile resamples the input automatically to match.
        var pcmASBD = AudioStreamBasicDescription(
            mSampleRate: 8000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        ExtAudioFileSetProperty(inputRef, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout.size(ofValue: pcmASBD)), &pcmASBD)
        ExtAudioFileSetProperty(outputRef, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout.size(ofValue: pcmASBD)), &pcmASBD)

        // Pump PCM frames from input to AMR output.
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
            abl.mBuffers.mDataByteSize = frames * 2
            guard ExtAudioFileWrite(outputRef, frames, &abl) == noErr else { break }
        }

        // Dispose flushes and finalises the AMR file before we read it.
        ExtAudioFileDispose(outputRef)
        return try? Data(contentsOf: tempURL)
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
