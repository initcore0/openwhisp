import XCTest
@testable import OpenWhispCore

/// Pure aggregation logic behind the local Usage Insights dashboard (MAK-38).
/// Everything is derived from already-collected `DictationStats` metadata — no
/// transcript text — with an injected "today" so streaks/"today" are
/// deterministic. Covers empty stats, single day, streaks with gaps, and
/// timezone/DST edge cases in the UTC day-key math.
final class InsightsSummaryTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func event(
        date: Date, words: Int = 3, chars: Int = 15, seconds: Double = 5,
        engine: String = "whisperKit", app: String? = "com.example.app",
        latency: Double? = 1.2
    ) -> DictationEvent {
        DictationEvent(
            date: date, wordCount: words, charCount: chars, durationSeconds: seconds,
            engine: engine, model: nil, outputMode: "preview",
            appBundleID: app, transcriptionLatencySeconds: latency
        )
    }

    // MARK: - Empty stats

    func testEmptyStatsAreAllZeroOrNil() {
        let s = InsightsSummary(stats: DictationStats(), today: "2026-07-09")
        XCTAssertEqual(s.totalSessions, 0)
        XCTAssertEqual(s.totalWords, 0)
        XCTAssertNil(s.wordsPerMinute)
        XCTAssertNil(s.estimatedSecondsSaved)
        XCTAssertNil(s.averageLatencySeconds)
        XCTAssertEqual(s.currentStreakDays, 0)
        XCTAssertEqual(s.longestStreakDays, 0)
        XCTAssertEqual(s.activeDays, 0)
        XCTAssertEqual(s.wordsToday, 0)
        XCTAssertTrue(s.appBreakdown.isEmpty)
        XCTAssertTrue(s.engineBreakdown.isEmpty)
    }

    // MARK: - Passthrough totals + WPM

    func testTotalsAndWPM() {
        var stats = DictationStats()
        // 120 words over 120 seconds (2 min) = 60 WPM.
        stats.record(event(date: date("2026-07-01T10:00:00Z"), words: 60, seconds: 60))
        stats.record(event(date: date("2026-07-01T11:00:00Z"), words: 60, seconds: 60))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.totalWords, 120)
        XCTAssertEqual(s.totalSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(s.wordsPerMinute ?? 0, 60, accuracy: 0.001)
    }

    func testWPMNilWhenNoTime() {
        var stats = DictationStats()
        stats.record(event(date: date("2026-07-01T10:00:00Z"), words: 5, seconds: 0))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertNil(s.wordsPerMinute)
    }

    // MARK: - Time saved

    func testTimeSavedVsTypingBaseline() {
        var stats = DictationStats()
        // 40 words dictated in 30s. At the 40 WPM baseline, typing 40 words takes
        // 60s, so ~30s saved.
        stats.record(event(date: date("2026-07-01T10:00:00Z"), words: 40, seconds: 30))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.estimatedSecondsSaved ?? -1, 30, accuracy: 0.001)
    }

    func testTimeSavedFlooredAtZeroWhenSlowerThanTyping() {
        var stats = DictationStats()
        // 40 words but took 5 minutes — slower than typing; must floor at 0, not go
        // negative.
        stats.record(event(date: date("2026-07-01T10:00:00Z"), words: 40, seconds: 300))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.estimatedSecondsSaved ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - Streaks

    func testSingleDayStreak() {
        var stats = DictationStats()
        stats.record(event(date: date("2026-07-09T10:00:00Z")))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.activeDays, 1)
        XCTAssertEqual(s.currentStreakDays, 1)
        XCTAssertEqual(s.longestStreakDays, 1)
    }

    func testCurrentStreakConsecutiveDaysEndingToday() {
        var stats = DictationStats()
        for d in ["2026-07-07", "2026-07-08", "2026-07-09"] {
            stats.record(event(date: date("\(d)T10:00:00Z")))
        }
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.currentStreakDays, 3)
        XCTAssertEqual(s.longestStreakDays, 3)
    }

    func testCurrentStreakZeroWhenTodayHasNone() {
        var stats = DictationStats()
        stats.record(event(date: date("2026-07-07T10:00:00Z")))
        stats.record(event(date: date("2026-07-08T10:00:00Z")))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.currentStreakDays, 0)          // gap on the 9th
        XCTAssertEqual(s.longestStreakDays, 2)          // 7th–8th
    }

    func testLongestStreakPicksTheLongestRunAmongGaps() {
        var stats = DictationStats()
        // Run of 2 (Jun 1–2), gap, run of 4 (Jun 5–8), gap, single (Jun 20 = today).
        for d in ["2026-06-01", "2026-06-02",
                  "2026-06-05", "2026-06-06", "2026-06-07", "2026-06-08",
                  "2026-06-20"] {
            stats.record(event(date: date("\(d)T10:00:00Z")))
        }
        let s = InsightsSummary(stats: stats, today: "2026-06-20")
        XCTAssertEqual(s.longestStreakDays, 4)
        XCTAssertEqual(s.currentStreakDays, 1)
    }

    func testStreakAcrossMonthBoundary() {
        var stats = DictationStats()
        for d in ["2026-06-29", "2026-06-30", "2026-07-01"] {
            stats.record(event(date: date("\(d)T10:00:00Z")))
        }
        let s = InsightsSummary(stats: stats, today: "2026-07-01")
        XCTAssertEqual(s.currentStreakDays, 3)
    }

    // MARK: - Day-key arithmetic (timezone / DST)

    func testDayArithmeticIsUTCAndDSTImmune() {
        // US DST spring-forward 2026 was Mar 8. In local time that day is 23h, but
        // day-key math is UTC so ±1 day is always exactly one calendar day.
        XCTAssertEqual(InsightsSummary.nextDay("2026-03-07"), "2026-03-08")
        XCTAssertEqual(InsightsSummary.nextDay("2026-03-08"), "2026-03-09")
        XCTAssertEqual(InsightsSummary.previousDay("2026-03-08"), "2026-03-07")
        // Leap year: Feb has 29 days in 2028.
        XCTAssertEqual(InsightsSummary.nextDay("2028-02-28"), "2028-02-29")
        XCTAssertEqual(InsightsSummary.nextDay("2028-02-29"), "2028-03-01")
        // Year boundary.
        XCTAssertEqual(InsightsSummary.nextDay("2026-12-31"), "2027-01-01")
        XCTAssertEqual(InsightsSummary.previousDay("2027-01-01"), "2026-12-31")
    }

    func testMalformedDayKeyReturnsNil() {
        XCTAssertNil(InsightsSummary.nextDay("nonsense"))
        XCTAssertNil(InsightsSummary.previousDay("2026-13"))
    }

    /// A late-UTC event and an early-next-UTC-day event should NOT count as the
    /// same streak-day even if they'd be the same LOCAL day for some viewer — the
    /// bucketing is UTC end to end.
    func testStreakBucketingIsUTCNotLocal() {
        var stats = DictationStats()
        stats.record(event(date: date("2026-07-01T23:30:00Z"))) // 2026-07-01
        stats.record(event(date: date("2026-07-02T00:30:00Z"))) // 2026-07-02
        let s = InsightsSummary(stats: stats, today: "2026-07-02")
        XCTAssertEqual(s.activeDays, 2)
        XCTAssertEqual(s.currentStreakDays, 2)
    }

    // MARK: - Today counters

    func testTodayCounters() {
        var stats = DictationStats()
        stats.record(event(date: date("2026-07-08T10:00:00Z"), words: 10))
        stats.record(event(date: date("2026-07-09T10:00:00Z"), words: 4))
        stats.record(event(date: date("2026-07-09T11:00:00Z"), words: 6))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.wordsToday, 10)
        XCTAssertEqual(s.sessionsToday, 2)
    }

    // MARK: - Breakdowns

    func testAppBreakdownSortedWithFractionsAndNames() {
        var stats = DictationStats()
        for _ in 0..<3 { stats.record(event(date: date("2026-07-01T10:00:00Z"), app: "com.google.Chrome")) }
        stats.record(event(date: date("2026-07-01T10:00:00Z"), app: "com.apple.Notes"))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.appBreakdown.count, 2)
        XCTAssertEqual(s.appBreakdown[0].bundleID, "com.google.Chrome")
        XCTAssertEqual(s.appBreakdown[0].displayName, "Chrome")     // prettified fallback
        XCTAssertEqual(s.appBreakdown[0].sessions, 3)
        XCTAssertEqual(s.appBreakdown[0].fraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(s.appBreakdown[1].displayName, "Notes")
    }

    func testAppBreakdownUsesResolverThenFallback() {
        var stats = DictationStats()
        stats.record(event(date: date("2026-07-01T10:00:00Z"), app: "com.acme.Editor"))
        let s = InsightsSummary(
            stats: stats, today: "2026-07-09",
            appName: { $0 == "com.acme.Editor" ? "Acme Editor" : nil }
        )
        XCTAssertEqual(s.appBreakdown[0].displayName, "Acme Editor")
    }

    func testUnknownAppShownAsUnattributed() {
        var stats = DictationStats()
        stats.record(event(date: date("2026-07-01T10:00:00Z"), app: nil))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.appBreakdown[0].bundleID, "unknown")
        XCTAssertEqual(s.appBreakdown[0].displayName, "Unattributed")
    }

    func testAppBreakdownRespectsMaxApps() {
        var stats = DictationStats()
        for i in 0..<10 { stats.record(event(date: date("2026-07-01T10:00:00Z"), app: "com.app\(i)")) }
        let s = InsightsSummary(stats: stats, today: "2026-07-09", maxApps: 3)
        XCTAssertEqual(s.appBreakdown.count, 3)
    }

    func testEngineBreakdownNamesAndFractions() {
        var stats = DictationStats()
        for _ in 0..<3 { stats.record(event(date: date("2026-07-01T10:00:00Z"), engine: "whisperKit")) }
        stats.record(event(date: date("2026-07-01T10:00:00Z"), engine: "appleSpeech"))
        let s = InsightsSummary(stats: stats, today: "2026-07-09")
        XCTAssertEqual(s.engineBreakdown[0].engine, "whisperKit")
        XCTAssertEqual(s.engineBreakdown[0].displayName, "WhisperKit")
        XCTAssertEqual(s.engineBreakdown[0].fraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(s.engineBreakdown[1].displayName, "Apple Speech")
    }

    // MARK: - Formatting

    func testFormatDuration() {
        XCTAssertEqual(InsightsSummary.formatDuration(seconds: 0), "0s")
        XCTAssertEqual(InsightsSummary.formatDuration(seconds: 30), "30s")
        XCTAssertEqual(InsightsSummary.formatDuration(seconds: 90), "1m 30s")
        XCTAssertEqual(InsightsSummary.formatDuration(seconds: 15 * 60), "15m")
        XCTAssertEqual(InsightsSummary.formatDuration(seconds: 3600), "1h")
        XCTAssertEqual(InsightsSummary.formatDuration(seconds: 3600 + 5 * 60), "1h 5m")
        XCTAssertEqual(InsightsSummary.formatDuration(seconds: 2 * 3600 + 5 * 60 + 9), "2h 5m")
    }

    func testPrettifyBundleID() {
        XCTAssertEqual(InsightsSummary.prettifyBundleID("com.google.Chrome"), "Chrome")
        XCTAssertEqual(InsightsSummary.prettifyBundleID("com.apple.TextEdit"), "Text Edit")
        XCTAssertEqual(InsightsSummary.prettifyBundleID("standalone"), "standalone")
    }
}
