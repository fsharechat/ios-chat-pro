import IMMessaging

/// `ConversationViewModel` 依赖的流式 AI(官方客服)窄接口,而非具体的
/// `MessagingService`——与 `MessageSending`/`ContactInfoFetching` 相同的
/// 可测性解耦模式。`onSaiToken` 是单监听者(同 Android
/// `setOnSaiTokenListener`):后打开的会话页覆盖先前的绑定,旧 ViewModel
/// 的闭包因 `[weak self]` 自动失效,故无需(也不能)在 deinit 里清空——
/// deinit 时机晚于新页 init 时会误清别人的绑定。
public protocol StreamingAiObserving: AnyObject {
    var onSaiToken: ((_ streamId: String, _ delta: String, _ done: Bool, _ target: String) -> Void)? { get set }
    var activeStream: StreamingState? { get }
    func clearActiveStream()
}

extension MessagingService: StreamingAiObserving {}
