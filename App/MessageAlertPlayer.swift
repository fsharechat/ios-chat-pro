import AudioToolbox
import UIKit
import AppCore

/// 新消息本地提醒：按 `MessageAlertPolicy` 给出的档位播放系统提示音或纯
/// 震动。由 `SceneDelegate` 持有，接到 `AppEnvironment.onIncomingMessageAlert`
/// 上（见该属性的文档——中继跨重登存活，这里只需要接一次）。
///
/// 不用 `AVAudioPlayer`：`AudioServicesPlaySystemSound` 播放系统音效，
/// 天然遵循静音拨片，不需要像 `CallRingtonePlayer` 那样手动管理
/// `AVAudioSession` 分类。
///
/// 震动用 `UINotificationFeedbackGenerator(.success)` 而不是
/// `kSystemSoundID_Vibrate`：后者只有单次统一节奏的"嗡"一下，装机实测
/// 手感和微信的"动动-动"双击节奏对不上；`.success` 触感反馈在 Taptic
/// Engine 设备上天然就是两下的节奏，不需要自己拼时间间隔。
final class MessageAlertPlayer {
    /// 系统 "SMS 收到 1" 三音效——遵循静音拨片。
    private static let messageSoundID: SystemSoundID = 1007

    private var policy = MessageAlertPolicy()
    private let feedbackGenerator = UINotificationFeedbackGenerator()

    func handle(isMuted: Bool, isActiveConversation: Bool, isGroupNotification: Bool) {
        switch policy.evaluate(isMuted: isMuted, isActiveConversation: isActiveConversation, isGroupNotification: isGroupNotification, now: Date()) {
        case .silent:
            break
        case .vibrate:
            feedbackGenerator.notificationOccurred(.success)
        case .vibrateAndSound:
            feedbackGenerator.notificationOccurred(.success)
            AudioServicesPlaySystemSound(Self.messageSoundID)
        }
    }
}
