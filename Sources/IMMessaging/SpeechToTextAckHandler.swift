import Foundation
import IMClient
import IMProto
import IMTransport

/// Handles `PUB_ACK`/`ASR`(subSignal 44)：1 字节错误码 + 成功时 `SpeechToTextResult`。
/// 与 `RecallAckHandler` 同构，按 wireMessageId 回给 `MessagingService`。
public final class SpeechToTextAckHandler: MessageHandler {
    /// 参数：wireMessageId、识别文本（失败为 nil）
    var onResult: ((UInt16, String?) -> Void)?

    public init() {}

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .pubAck && subSignal == .asr
    }

    public func handle(frame: Frame) {
        guard let errorCode = frame.body.first else { return }
        guard errorCode == 0 else {
            onResult?(frame.header.messageId, nil)
            return
        }
        let text = try? Im_SpeechToTextResult(serializedBytes: frame.body.dropFirst()).text
        onResult?(frame.header.messageId, text)
    }
}
