import Foundation
import Combine

public protocol TranscriptPersistence: AnyObject {
    func loadDone() -> [Int64: TranscriptEngine.Saved]
    func saveDone(_ done: [Int64: TranscriptEngine.Saved])
    func loadAuto() -> Bool
    func saveAuto(_ on: Bool)
}

/// 语音转文字状态机。与 Android `TranscriptEngine` 行为一致：
/// 15 秒超时兜底（迟到结果丢弃）、识别中隐藏会保留、自动队列并发 2。
/// 线程约定：全部在主队列调用。
public final class TranscriptEngine {
    public static let timeout: TimeInterval = 15
    public static let autoConcurrency = 2

    public enum Status: Equatable { case loading, done, error }

    public struct Entry: Equatable {
        public let status: Status
        public let text: String
        public let hidden: Bool
        public init(status: Status, text: String, hidden: Bool) {
            self.status = status
            self.text = text
            self.hidden = hidden
        }
    }

    public struct Saved: Codable, Equatable {
        public let text: String
        public let hidden: Bool
        public init(text: String, hidden: Bool) {
            self.text = text
            self.hidden = hidden
        }
    }

    /// 变化的 messageUid，会话页据此刷新对应气泡
    public let changes = PassthroughSubject<Int64, Never>()

    private let fetcher: () -> SpeechToTextFetching?
    private let persistence: TranscriptPersistence
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    private var entries: [Int64: Entry] = [:]
    private var inflight: [Int64: Int] = [:]
    private var autoQueue: [Int64] = []
    private var autoRunning: Set<Int64> = []
    private var seq = 0

    public var isAutoTranscribe: Bool {
        didSet {
            persistence.saveAuto(isAutoTranscribe)
            if !isAutoTranscribe { autoQueue.removeAll() }
        }
    }

    /// - Parameter fetcher: 每次请求时取当前的 `MessagingService`（登出 / 重登会替换实例）
    public init(fetcher: @escaping () -> SpeechToTextFetching?,
                persistence: TranscriptPersistence,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.fetcher = fetcher
        self.persistence = persistence
        self.schedule = schedule
        self.isAutoTranscribe = persistence.loadAuto()
        for (uid, saved) in persistence.loadDone() {
            entries[uid] = Entry(status: .done, text: saved.text, hidden: saved.hidden)
        }
    }

    public func entry(for uid: Int64) -> Entry? { entries[uid] }

    public func request(_ uid: Int64) {
        if let cur = entries[uid] {
            if cur.status == .loading {
                if cur.hidden { put(uid, Entry(status: .loading, text: "", hidden: false)) }
                return
            }
            if cur.status == .done {
                if cur.hidden {
                    put(uid, Entry(status: .done, text: cur.text, hidden: false))
                    persist()
                }
                return
            }
        }
        seq += 1
        let gen = seq
        inflight[uid] = gen
        put(uid, Entry(status: .loading, text: "", hidden: false))
        guard let fetcher = fetcher() else {
            finish(uid, gen: gen, text: nil)
            return
        }
        schedule(Self.timeout) { [weak self] in self?.finish(uid, gen: gen, text: nil) }
        fetcher.speechToText(messageUid: uid) { [weak self] text in
            self?.finish(uid, gen: gen, text: text)
        }
    }

    public func hide(_ uid: Int64) {
        guard let cur = entries[uid] else { return }
        put(uid, Entry(status: cur.status, text: cur.text, hidden: true))
        persist()
    }

    /// 实时收到的他人语音：开关打开时排队自动识别，已有结果或已在队列中的跳过
    public func enqueueAuto(_ uid: Int64) {
        guard isAutoTranscribe, entries[uid] == nil, !autoQueue.contains(uid), !autoRunning.contains(uid) else { return }
        autoQueue.append(uid)
        drain()
    }

    private func drain() {
        while autoRunning.count < Self.autoConcurrency, !autoQueue.isEmpty {
            let uid = autoQueue.removeFirst()
            // 已被手动识别（存在且非 error）的不占自动槽位，否则 request 提前返回、finish 永不释放
            if let cur = entries[uid], cur.status != .error { continue }
            autoRunning.insert(uid)
            request(uid)
        }
    }

    private func finish(_ uid: Int64, gen: Int, text: String?) {
        guard inflight[uid] == gen else { return }
        inflight[uid] = nil
        let hidden = entries[uid]?.hidden ?? false
        if let text {
            put(uid, Entry(status: .done, text: text, hidden: hidden))
        } else {
            put(uid, Entry(status: .error, text: "", hidden: hidden))
        }
        persist()
        if autoRunning.remove(uid) != nil { drain() }
    }

    private func put(_ uid: Int64, _ entry: Entry) {
        entries[uid] = entry
        changes.send(uid)
    }

    private func persist() {
        var done: [Int64: Saved] = [:]
        for (uid, e) in entries where e.status == .done {
            done[uid] = Saved(text: e.text, hidden: e.hidden)
        }
        persistence.saveDone(done)
    }
}
