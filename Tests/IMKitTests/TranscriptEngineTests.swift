import XCTest
import Combine
@testable import IMKit

private final class FakeFetcher: SpeechToTextFetching {
    var calls: [(uid: Int64, completion: (String?) -> Void)] = []
    func speechToText(messageUid: Int64, completion: @escaping (String?) -> Void) {
        calls.append((messageUid, completion))
    }
}

private final class MemoryPersistence: TranscriptPersistence {
    var done: [Int64: TranscriptEngine.Saved] = [:]
    var auto = false
    func loadDone() -> [Int64: TranscriptEngine.Saved] { done }
    func saveDone(_ done: [Int64: TranscriptEngine.Saved]) { self.done = done }
    func loadAuto() -> Bool { auto }
    func saveAuto(_ on: Bool) { auto = on }
}

final class TranscriptEngineTests: XCTestCase {
    private var fetcher: FakeFetcher!
    private var persistence: MemoryPersistence!
    private var timers: [() -> Void] = []
    private var engine: TranscriptEngine!
    private var changed: [Int64] = []
    private var bag: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        fetcher = FakeFetcher()
        persistence = MemoryPersistence()
        timers = []
        changed = []
        engine = makeEngine()
    }

    private func makeEngine() -> TranscriptEngine {
        let e = TranscriptEngine(fetcher: { [unowned self] in self.fetcher }, persistence: persistence) { [unowned self] delay, block in
            XCTAssertEqual(delay, TranscriptEngine.timeout)
            self.timers.append(block)
        }
        e.changes.sink { [unowned self] in self.changed.append($0) }.store(in: &bag)
        return e
    }

    func test_successGoesLoadingThenDoneAndPersists() {
        engine.request(7)
        XCTAssertEqual(engine.entry(for: 7)?.status, .loading)

        fetcher.calls[0].completion("你好")

        XCTAssertEqual(engine.entry(for: 7), TranscriptEngine.Entry(status: .done, text: "你好", hidden: false))
        XCTAssertEqual(persistence.done[7]?.text, "你好")
        XCTAssertTrue(changed.count >= 2)
    }

    func test_failureIsErrorAndRetryable() {
        engine.request(7)
        fetcher.calls[0].completion(nil)
        XCTAssertEqual(engine.entry(for: 7)?.status, .error)
        XCTAssertNil(persistence.done[7])

        engine.request(7)
        XCTAssertEqual(fetcher.calls.count, 2)
    }

    func test_noFetcherIsError() {
        let e = TranscriptEngine(fetcher: { nil }, persistence: persistence) { _, _ in }
        e.request(7)
        XCTAssertEqual(e.entry(for: 7)?.status, .error)
    }

    func test_requestWhileLoadingIsNoop() {
        engine.request(7)
        engine.request(7)
        XCTAssertEqual(fetcher.calls.count, 1)
    }

    func test_timeoutTurnsLoadingIntoError() {
        engine.request(7)
        timers[0]()
        XCTAssertEqual(engine.entry(for: 7)?.status, .error)
    }

    func test_lateResultAfterTimeoutIsIgnored() {
        engine.request(7)
        timers[0]()
        fetcher.calls[0].completion("late")
        XCTAssertEqual(engine.entry(for: 7)?.status, .error)
    }

    func test_hideThenRequestUnhidesWithoutNetwork() {
        engine.request(7)
        fetcher.calls[0].completion("a")
        engine.hide(7)
        XCTAssertEqual(persistence.done[7]?.hidden, true)

        engine.request(7)

        XCTAssertEqual(engine.entry(for: 7)?.hidden, false)
        XCTAssertEqual(fetcher.calls.count, 1)
    }

    func test_hideWhileLoadingStaysHidden() {
        engine.request(7)
        engine.hide(7)
        fetcher.calls[0].completion("a")
        XCTAssertEqual(engine.entry(for: 7), TranscriptEngine.Entry(status: .done, text: "a", hidden: true))
    }

    func test_restoresDoneEntriesAndAutoFlag() {
        persistence.done = [9: .init(text: "旧", hidden: false)]
        persistence.auto = true

        let restored = makeEngine()

        XCTAssertEqual(restored.entry(for: 9)?.text, "旧")
        XCTAssertTrue(restored.isAutoTranscribe)
    }

    func test_enqueueAutoIgnoredWhenOff() {
        engine.enqueueAuto(1)
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    func test_enqueueAutoRunsTwoAtATimeAndDedupes() {
        engine.isAutoTranscribe = true
        XCTAssertTrue(persistence.auto)

        engine.enqueueAuto(1)
        engine.enqueueAuto(2)
        engine.enqueueAuto(3)
        engine.enqueueAuto(1)
        XCTAssertEqual(fetcher.calls.count, 2)

        fetcher.calls[0].completion("1")
        XCTAssertEqual(fetcher.calls.count, 3)
        XCTAssertEqual(fetcher.calls[2].uid, 3)
    }

    func test_autoSlotIsFreedOnTimeout() {
        engine.isAutoTranscribe = true
        engine.enqueueAuto(1)
        engine.enqueueAuto(2)
        engine.enqueueAuto(3)

        timers[0]()

        XCTAssertEqual(fetcher.calls.count, 3)
    }

    func test_requestWhileLoadingAndHiddenUnhidesWithoutNewFetch() {
        engine.request(7)
        engine.hide(7)
        XCTAssertEqual(engine.entry(for: 7)?.hidden, true)

        engine.request(7)

        XCTAssertEqual(engine.entry(for: 7), TranscriptEngine.Entry(status: .loading, text: "", hidden: false))
        XCTAssertEqual(fetcher.calls.count, 1)
        fetcher.calls[0].completion("a")
        XCTAssertEqual(engine.entry(for: 7), TranscriptEngine.Entry(status: .done, text: "a", hidden: false))
    }

    func test_drainSkipsQueuedUidAlreadyTranscribedManually() {
        engine.isAutoTranscribe = true
        engine.enqueueAuto(1)
        engine.enqueueAuto(2)
        engine.enqueueAuto(3)
        XCTAssertEqual(fetcher.calls.map { $0.uid }, [1, 2])

        engine.request(3)
        XCTAssertEqual(fetcher.calls.map { $0.uid }, [1, 2, 3])
        fetcher.calls[2].completion("three")
        XCTAssertEqual(engine.entry(for: 3)?.status, .done)

        fetcher.calls[0].completion("one")
        XCTAssertEqual(fetcher.calls.count, 3, "uid 3 must not fetch again")

        engine.enqueueAuto(4)
        engine.enqueueAuto(5)
        XCTAssertEqual(fetcher.calls.map { $0.uid }, [1, 2, 3, 4])

        fetcher.calls[1].completion("two")
        XCTAssertEqual(fetcher.calls.map { $0.uid }, [1, 2, 3, 4, 5])
    }

    func test_disablingAutoClearsPendingQueueButInflightFinish() {
        engine.isAutoTranscribe = true
        engine.enqueueAuto(1)
        engine.enqueueAuto(2)
        engine.enqueueAuto(3)

        engine.isAutoTranscribe = false
        XCTAssertFalse(persistence.auto)

        fetcher.calls[0].completion("1")
        fetcher.calls[1].completion("2")
        XCTAssertEqual(fetcher.calls.map { $0.uid }, [1, 2])
        XCTAssertEqual(engine.entry(for: 1)?.status, .done)
        XCTAssertEqual(engine.entry(for: 2)?.status, .done)
        XCTAssertNil(engine.entry(for: 3))
    }

    func test_userDefaultsPersistenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "TranscriptEngineTests-\(UUID().uuidString)")!
        let p = UserDefaultsTranscriptPersistence(defaults: defaults)
        p.saveDone([5: .init(text: "x", hidden: true)])
        p.saveAuto(true)

        XCTAssertEqual(p.loadDone()[5]?.text, "x")
        XCTAssertEqual(p.loadDone()[5]?.hidden, true)
        XCTAssertTrue(p.loadAuto())
    }
}
