import Foundation
import IMMessaging

/// 语音转文字能力。completion 在主队列回调：成功为文本（可能为空串），失败为 nil。
public protocol SpeechToTextFetching: AnyObject {
    func speechToText(messageUid: Int64, completion: @escaping (String?) -> Void)
}

extension MessagingService: SpeechToTextFetching {}
