import Foundation
import IMStorage
import IMMessaging

/// 标记用户当前正停留在哪个会话详情页 —— `ReceiveMessageHandler` 对命中的
/// 会话不递增未读数/@提醒数(正在看的消息不算未读),避免退回会话列表时
/// 该会话与「消息」tab 角标重复计数。`ConversationViewController` 在
/// `viewWillAppear`/`viewWillDisappear` 里通过 `ConversationViewModel`
/// 成对调用。
public protocol ActiveConversationTracking: AnyObject {
    func markConversationActive(conversationType: ConversationType, target: String, line: Int)
    /// 带参数而非无参"清空":push 转场里两个会话页的 willDisappear/willAppear
    /// 交错触发时,只有仍指向自己的标记才允许清除,防止误清刚接棒的会话。
    func markConversationInactive(conversationType: ConversationType, target: String, line: Int)
}

extension MessagingService: ActiveConversationTracking {
    public func markConversationActive(conversationType: ConversationType, target: String, line: Int) {
        activeConversation = (conversationType, target, line)
    }

    public func markConversationInactive(conversationType: ConversationType, target: String, line: Int) {
        guard let active = activeConversation,
              active.conversationType == conversationType, active.target == target, active.line == line
        else { return }
        activeConversation = nil
    }
}
