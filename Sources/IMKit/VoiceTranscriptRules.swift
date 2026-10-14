import Foundation

/// 语音气泡上转文字相关控件的显示规则，与 electron / web / android 一致
public enum VoiceTranscriptRules {
    public static let realtimeWindowMillis: Int64 = 120_000

    public enum Block: Equatable { case none, loading, text, empty, error }

    public static func showPill(isIncoming: Bool, isPlayed: Bool, messageUid: Int64, entry: TranscriptEngine.Entry?, auto: Bool) -> Bool {
        isIncoming && !isPlayed && messageUid > 0 && entry == nil && !auto
    }

    public static func block(_ entry: TranscriptEngine.Entry?) -> Block {
        guard let entry, !entry.hidden else { return .none }
        switch entry.status {
        case .loading: return .loading
        case .error: return .error
        case .done: return entry.text.isEmpty ? .empty : .text
        }
    }

    private static func showing(_ entry: TranscriptEngine.Entry?) -> Bool {
        guard let entry else { return false }
        return !entry.hidden && entry.status != .error
    }

    public static func showTranscribeMenu(messageUid: Int64, entry: TranscriptEngine.Entry?) -> Bool {
        messageUid > 0 && !showing(entry)
    }

    public static func showHideMenu(messageUid: Int64, entry: TranscriptEngine.Entry?) -> Bool {
        messageUid > 0 && showing(entry)
    }

    /// 长时间离线后积压的语音不自动识别，只识别 2 分钟内到达的
    public static func isRealtime(serverTimestamp: Int64, serverDelta: Int64, now: Int64) -> Bool {
        now - (serverTimestamp - serverDelta) <= realtimeWindowMillis
    }
}
