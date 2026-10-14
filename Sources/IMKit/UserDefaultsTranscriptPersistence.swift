import Foundation

public final class UserDefaultsTranscriptPersistence: TranscriptPersistence {
    private static let entriesKey = "voiceTranscript.entries"
    private static let autoKey = "voiceTranscript.auto"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadDone() -> [Int64: TranscriptEngine.Saved] {
        guard let data = defaults.data(forKey: Self.entriesKey),
              let decoded = try? JSONDecoder().decode([String: TranscriptEngine.Saved].self, from: data) else { return [:] }
        var out: [Int64: TranscriptEngine.Saved] = [:]
        for (k, v) in decoded { if let uid = Int64(k) { out[uid] = v } }
        return out
    }

    public func saveDone(_ done: [Int64: TranscriptEngine.Saved]) {
        let keyed = Dictionary(uniqueKeysWithValues: done.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(keyed) {
            defaults.set(data, forKey: Self.entriesKey)
        }
    }

    public func loadAuto() -> Bool { defaults.bool(forKey: Self.autoKey) }

    public func saveAuto(_ on: Bool) { defaults.set(on, forKey: Self.autoKey) }
}
