import XCTest
@testable import OpenWhispCore

/// Pure aggregation logic for local-only dictation stats (metadata only — no
/// transcript text). Folding events must accumulate lifetime totals, per-day
/// rollups, and per-dimension breakdowns deterministically.
final class DictationStatsTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func event(
        date: Date,
        words: Int = 3,
        chars: Int = 15,
        seconds: Double = 5,
        engine: String = "whisperKit",
        model: String? = "openai_whisper-small",
        outputMode: String = "preview",
        app: String? = "com.example.app",
        latency: Double? = 1.2
    ) -> DictationEvent {
        DictationEvent(
            date: date, wordCount: words, charCount: chars, durationSeconds: seconds,
            engine: engine, model: model, outputMode: outputMode,
            appBundleID: app, transcriptionLatencySeconds: latency
        )
    }

    // MARK: - Word counting

    func testWordCount() {
        XCTAssertEqual(DictationEvent.words(in: "hello world"), 2)
        XCTAssertEqual(DictationEvent.words(in: "  spaced   out \n words "), 3)
        XCTAssertEqual(DictationEvent.words(in: ""), 0)
        XCTAssertEqual(DictationEvent.words(in: "   "), 0)
        XCTAssertEqual(DictationEvent.words(in: "one"), 1)
    }

    // MARK: - Aggregation

    func testLifetimeTotalsAccumulate() {
        var s = DictationStats()
        s.record(event(date: date("2026-06-01T10:00:00Z"), words: 3, chars: 15, seconds: 5))
        s.record(event(date: date("2026-06-01T11:00:00Z"), words: 7, chars: 40, seconds: 12))
        XCTAssertEqual(s.totalSessions, 2)
        XCTAssertEqual(s.totalWords, 10)
        XCTAssertEqual(s.totalCharacters, 55)
        XCTAssertEqual(s.totalSeconds, 17, accuracy: 0.0001)
    }

    func testPerDayRollups() {
        var s = DictationStats()
        s.record(event(date: date("2026-06-01T10:00:00Z"), words: 3, seconds: 5))
        s.record(event(date: date("2026-06-01T23:30:00Z"), words: 2, seconds: 4))
        s.record(event(date: date("2026-06-02T08:00:00Z"), words: 5, seconds: 9))
        XCTAssertEqual(s.byDay["2026-06-01"]?.sessions, 2)
        XCTAssertEqual(s.byDay["2026-06-01"]?.words, 5)
        XCTAssertEqual(s.byDay["2026-06-01"]?.seconds ?? 0, 9, accuracy: 0.0001)
        XCTAssertEqual(s.byDay["2026-06-02"]?.sessions, 1)
        XCTAssertEqual(s.byDay["2026-06-02"]?.words, 5)
    }

    func testDayKeyIsUTC() {
        // 23:30 UTC on the 1st is still the 1st (the bucketing is UTC, not local).
        XCTAssertEqual(DictationStats.dayKey(for: date("2026-06-01T23:30:00Z")), "2026-06-01")
        XCTAssertEqual(DictationStats.dayKey(for: date("2026-06-02T00:30:00Z")), "2026-06-02")
    }

    func testBreakdownsByEngineAndApp() {
        var s = DictationStats()
        s.record(event(date: date("2026-06-01T10:00:00Z"), engine: "whisperKit", app: "com.a"))
        s.record(event(date: date("2026-06-01T10:05:00Z"), engine: "whisperKit", app: "com.b"))
        s.record(event(date: date("2026-06-01T10:10:00Z"), engine: "appleSpeech", app: "com.a"))
        XCTAssertEqual(s.sessionsByEngine["whisperKit"], 2)
        XCTAssertEqual(s.sessionsByEngine["appleSpeech"], 1)
        XCTAssertEqual(s.sessionsByApp["com.a"], 2)
        XCTAssertEqual(s.sessionsByApp["com.b"], 1)
    }

    func testMissingAppBucketsAsUnknown() {
        var s = DictationStats()
        s.record(event(date: date("2026-06-01T10:00:00Z"), app: nil))
        XCTAssertEqual(s.sessionsByApp["unknown"], 1)
    }

    func testLatencyAverage() {
        var s = DictationStats()
        XCTAssertNil(s.averageLatencySeconds)
        s.record(event(date: date("2026-06-01T10:00:00Z"), latency: 1.0))
        s.record(event(date: date("2026-06-01T10:01:00Z"), latency: 3.0))
        s.record(event(date: date("2026-06-01T10:02:00Z"), latency: nil)) // not counted
        XCTAssertEqual(s.latencySamples, 2)
        XCTAssertEqual(s.averageLatencySeconds ?? 0, 2.0, accuracy: 0.0001)
    }

    func testNegativeDurationClampedToZero() {
        var s = DictationStats()
        s.record(event(date: date("2026-06-01T10:00:00Z"), seconds: -5))
        XCTAssertEqual(s.totalSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(s.byDay["2026-06-01"]?.seconds ?? -1, 0, accuracy: 0.0001)
    }

    func testRoundTripCodable() throws {
        var s = DictationStats()
        s.record(event(date: date("2026-06-01T10:00:00Z")))
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(DictationStats.self, from: data)
        XCTAssertEqual(decoded, s)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }
}
