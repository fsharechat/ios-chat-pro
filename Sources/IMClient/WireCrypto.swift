import CommonCrypto
import Foundation

/// Port of `com.comsince.github.push.util.AES` (identical in
/// android-chat-pro and chat-server-pro, confirmed via `diff`). AES/CBC,
/// IV = key, PKCS7 padding (Java's "PKCS5Padding" name for a 16-byte block
/// cipher is PKCS7 padding — same algorithm, different historical name).
public enum WireCrypto {
    public static let defaultKey: [UInt8] = [
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F,
    ]

    public enum Error: Swift.Error, Equatable {
        case cryptoFailed(status: Int32)
        case payloadTooShortForTimestampPrefix
    }

    /// Mirrors `AES.convertUserKey`: the first 16 UTF-16 code units of
    /// `secret`, each truncated to its low byte. Only meaningful for ASCII
    /// secrets, which is what the server actually issues — this is a literal
    /// port, not a "better" Unicode-aware version.
    public static func key(fromSecret secret: String) -> [UInt8] {
        Array(secret.utf16.prefix(16)).map { UInt8($0 & 0xFF) }
    }

    /// Raw AES/CBC/PKCS7 encrypt, IV = key.
    public static func encryptRaw(_ data: Data, key: [UInt8]) throws -> Data {
        try crypt(operation: CCOperation(kCCEncrypt), data: data, key: key)
    }

    /// Raw AES/CBC/PKCS7 decrypt, IV = key.
    public static func decryptRaw(_ data: Data, key: [UInt8]) throws -> Data {
        try crypt(operation: CCOperation(kCCDecrypt), data: data, key: key)
    }

    private static func crypt(operation: CCOperation, data: Data, key: [UInt8]) throws -> Data {
        var outBuffer = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyPtr.baseAddress, key.count,
                    keyPtr.baseAddress, // IV = key, per AES.java's `new IvParameterSpec(aesKey)`
                    dataPtr.baseAddress, data.count,
                    &outBuffer, outBuffer.count,
                    &outLength
                )
            }
        }
        guard status == kCCSuccess else { throw Error.cryptoFailed(status: status) }
        return Data(outBuffer.prefix(outLength))
    }

    /// Hours since 2018-01-01T00:00:00Z — matches
    /// `(System.currentTimeMillis()/1000 - 1514736000)/3600` in `AES.AESEncrypt`.
    public static func hoursSinceEpochAnchor(now: Date = Date()) -> Int32 {
        let anchor: TimeInterval = 1_514_736_000
        return Int32((now.timeIntervalSince1970 - anchor) / 3600)
    }

    /// Prepends the 4-byte timestamp prefix used by `AES.AESEncrypt`.
    /// Faithfully reproduces the original's bug where the most-significant
    /// byte is always written as 0 — masking to 8 bits before an unsigned
    /// right-shift by 24 always yields 0 in the Java source. Not "fixed"
    /// here: the server's decoder expects this exact (buggy) layout.
    public static func prependTimestampPrefix(_ payload: Data, hours: Int32) -> Data {
        var prefixed = Data()
        prefixed.append(UInt8(truncatingIfNeeded: hours))
        prefixed.append(UInt8(truncatingIfNeeded: hours >> 8))
        prefixed.append(UInt8(truncatingIfNeeded: hours >> 16))
        prefixed.append(0) // always 0 — see doc comment above
        prefixed.append(payload)
        return prefixed
    }

    /// Strips the 4-byte timestamp prefix. Does not validate staleness —
    /// matches the client's only real call site, `AES.AESDecrypt(token, "", false)`
    /// (`checkTime = false`).
    public static func stripTimestampPrefix(_ data: Data) throws -> Data {
        guard data.count > 4 else { throw Error.payloadTooShortForTimestampPrefix }
        return Data(data.dropFirst(4))
    }

    /// Full encrypt: embed the current-hour timestamp prefix, then AES/CBC/PKCS7 encrypt.
    public static func encrypt(_ plaintext: Data, key: [UInt8], now: Date = Date()) throws -> Data {
        let prefixed = prependTimestampPrefix(plaintext, hours: hoursSinceEpochAnchor(now: now))
        return try encryptRaw(prefixed, key: key)
    }

    /// Full decrypt: AES/CBC/PKCS7 decrypt, then strip the timestamp prefix.
    public static func decrypt(_ ciphertext: Data, key: [UInt8]) throws -> Data {
        try stripTimestampPrefix(try decryptRaw(ciphertext, key: key))
    }
}
