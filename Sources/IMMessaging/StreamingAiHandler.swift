import Foundation
import IMClient
import IMTransport

/// 一次流式 AI(官方客服)回复的累积状态,对齐 Android
/// `ChatManager.StreamingState`。由 `MessagingService` 持有并更新,
/// 供会话页中途退出重进时恢复占位气泡。
public struct StreamingState: Equatable {
    public let streamId: String
    public let target: String
    public let accumulatedText: String
    public let done: Bool

    public init(streamId: String, target: String, accumulatedText: String, done: Bool) {
        self.streamId = streamId
        self.target = target
        self.accumulatedText = accumulatedText
        self.done = done
    }
}

/// 解析服务端推送的流式 AI 增量帧(`PUBLISH`/`SAI`),对齐 Android
/// `StreamingAiHandler`。payload 为明文 JSON:
/// `{"i":"streamId","d":"delta","f":true/false,"t":"agentUserId"}`,
/// 任一字段缺失或非 JSON 时静默丢弃(与 Android 仅打日志的行为一致)。
public final class StreamingAiHandler: MessageHandler {
    public var onSaiToken: ((_ streamId: String, _ delta: String, _ done: Bool, _ target: String) -> Void)?

    public init() {}

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .publish && subSignal == .sai
    }

    public func handle(frame: Frame) {
        guard
            let obj = (try? JSONSerialization.jsonObject(with: frame.body)) as? [String: Any],
            let streamId = obj["i"] as? String,
            let delta = obj["d"] as? String,
            let done = obj["f"] as? Bool,
            let target = obj["t"] as? String
        else { return }
        onSaiToken?(streamId, delta, done, target)
    }
}
