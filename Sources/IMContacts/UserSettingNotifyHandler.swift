import Foundation
import IMClient
import IMTransport

/// `PUBLISH`/`UN`：服务端告知「你的设置变了」。body 是 8 字节大端 version，
/// 但这里不需要解析它 —— 直接触发一次增量拉取，由 UG 应答带回真正的数据。
/// 发起修改的那台设备也会收到自己的 UN，多拉一次是幂等的。
///
/// **Threading contract:** 与本代码库其余部分一致，没有内部加锁，
/// 必须从单一一致的队列调用。
public final class UserSettingNotifyHandler: MessageHandler {
    public var onUserSettingUpdateNotified: (() -> Void)?

    public init() {}

    public func canHandle(signal: Signal, subSignal: SubSignal) -> Bool {
        signal == .publish && subSignal == .un
    }

    public func handle(frame: Frame) {
        onUserSettingUpdateNotified?()
    }
}
