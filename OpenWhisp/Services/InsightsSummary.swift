import Foundation

/// Pure, on-device aggregation of `DictationStats` into the numbers the Insights
/// dashboard shows: lifetime totals, words-per-minute, estimated time saved vs a
/// typing baseline, current/longest streaks, and a per-app breakdown.
///
/// METADATA ONLY — like `DictationStats`, this never touches transcript text. It
/// reads the already-collected aggregates and derives display values. No IO, no
/// clock reads: the caller injects "today" (as a UTC day key) so the whole thing
/// is deterministic and unit-testable, including empty-stats, single-day, and
/// timezone/DST edge cases.
///
/// Day bucketing matches `DictationStats` exactly (UTC `yyyy-MM-dd` keys), so
/// streaks line up with how events were recorded regardless of the viewer's local
/// timezone.
struct InsightsSummary: Equatable {

    /// The assumed typing speed (words per minute) used for the "time saved"
    /// estimate. A commonly cited average for sustained keyboard typing. The UI
    /// MUST state this assumption next to the number — it is an estimate, not a
    /// measurement.
    static let typingBaselineWPM: Double = 40

    // Lifetime totals (straight passthrough from DictationStats).
    var totalSessions: Int
    var totalWords: Int
    var totalCharacters: Int
    var totalSeconds: Double

    /// Words per minute across all dictation time, or nil when there is no
    /// measured speaking time to divide by.
    var wordsPerMinute: Double?

    /// Estimated seconds saved versus typing the same words at
    /// `typingBaselineWPM`, floored at zero (never negative even if you somehow
    /// dictated slower than the baseline). nil when there are no words.
    var estimatedSecondsSaved: Double?

    /// Longest run of consecutive days (up to and including `today`) with at least
    /// one dictation. 0 when today (and yesterday, …) had none.
    var currentStreakDays: Int

    /// Longest run of consecutive dictation days anywhere in the history.
    var longestStreakDays: Int

    /// Distinct calendar days (UTC) with at least one dictation.
    var activeDays: Int

    /// Words dictated today (the injected `today` UTC day).
    var wordsToday: Int

    /// Sessions dictated today.
    var sessionsToday: Int

    /// Per-app usage, richest first. Bundle IDs are mapped to display names by the
    /// caller-supplied resolver; unresolved / unknown fall back to a readable stub.
    var appBreakdown: [AppUsage]

    /// Per-engine session counts, richest first.
    var engineBreakdown: [EngineUsage]

    /// Average transcription latency in seconds, or nil if never measured.
    var averageLatencySeconds: Double?

    struct AppUsage: Equatable {
        /// The raw bundle id key from the store ("unknown" when unattributed).
        let bundleID: String
        /// Human-readable name for display.
        let displayName: String
        let sessions: Int
        /// Share of all attributed sessions, 0…1.
        let fraction: Double
    }

    struct EngineUsage: Equatable {
        let engine: String
        /// Human-readable engine name for display.
        let displayName: String
        let sessions: Int
        let fraction: Double
    }

    // MARK: - Building

    /// Derive the summary from raw stats.
    ///
    /// - Parameters:
    ///   - stats: the collected aggregates.
    ///   - today: the current day as a UTC `yyyy-MM-dd` key (use
    ///     `DictationStats.dayKey(for: Date())`). Injected so tests are
    ///     deterministic and "current streak" / "today" are well-defined.
    ///   - appName: maps a bundle id to a display name (nil → fall back to a
    ///     readable form of the id). The `"unknown"` key is always shown as
    ///     "Unattributed".
    ///   - engineName: maps an engine id to a display name (nil → the id itself).
    ///   - maxApps: cap on the per-app rows returned (0 = all).
    init(
        stats: DictationStats,
        today: String,
        appName: (String) -> String? = { _ in nil },
        engineName: (String) -> String? = { _ in nil },
        maxApps: Int = 8
    ) {
        totalSessions = stats.totalSessions
        totalWords = stats.totalWords
        totalCharacters = stats.totalCharacters
        totalSeconds = stats.totalSeconds
        averageLatencySeconds = stats.averageLatencySeconds

        // WPM over all measured speaking time. Guard against zero/near-zero time.
        if stats.totalSeconds > 0.5 && stats.totalWords > 0 {
            wordsPerMinute = Double(stats.totalWords) / (stats.totalSeconds / 60.0)
        } else {
            wordsPerMinute = nil
        }

        // Time saved = typing time at the baseline − actual speaking time, floored
        // at zero. Typing time for N words at B wpm is N / B minutes.
        if stats.totalWords > 0 {
            let typingSeconds = Double(stats.totalWords) / Self.typingBaselineWPM * 60.0
            estimatedSecondsSaved = max(0, typingSeconds - stats.totalSeconds)
        } else {
            estimatedSecondsSaved = nil
        }

        // Streaks over the sorted set of UTC day keys.
        let days = stats.byDay.keys.filter { (stats.byDay[$0]?.sessions ?? 0) > 0 }
        activeDays = days.count
        let daySet = Set(days)
        longestStreakDays = Self.longestStreak(in: daySet)
        currentStreakDays = Self.currentStreak(endingAt: today, in: daySet)

        wordsToday = stats.byDay[today]?.words ?? 0
        sessionsToday = stats.byDay[today]?.sessions ?? 0

        // Per-app breakdown, richest first, mapped to display names.
        let totalAttributed = stats.sessionsByApp.values.reduce(0, +)
        var apps = stats.sessionsByApp
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .map { (bundleID, sessions) -> AppUsage in
                let name: String = bundleID == "unknown"
                    ? "Unattributed"
                    : (appName(bundleID) ?? Self.prettifyBundleID(bundleID))
                let fraction = totalAttributed > 0 ? Double(sessions) / Double(totalAttributed) : 0
                return AppUsage(bundleID: bundleID, displayName: name, sessions: sessions, fraction: fraction)
            }
        if maxApps > 0 && apps.count > maxApps {
            apps = Array(apps.prefix(maxApps))
        }
        appBreakdown = apps

        // Per-engine breakdown, richest first.
        let totalEngineSessions = stats.sessionsByEngine.values.reduce(0, +)
        engineBreakdown = stats.sessionsByEngine
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .map { (engine, sessions) in
                let fraction = totalEngineSessions > 0 ? Double(sessions) / Double(totalEngineSessions) : 0
                return EngineUsage(
                    engine: engine,
                    displayName: engineName(engine) ?? Self.prettifyEngine(engine),
                    sessions: sessions,
                    fraction: fraction
                )
            }
    }

    // MARK: - Streak math (pure)

    /// Longest run of consecutive calendar days present in `daySet`.
    static func longestStreak(in daySet: Set<String>) -> Int {
        guard !daySet.isEmpty else { return 0 }
        // Only days that START a run (no predecessor in the set) need scanning.
        var best = 0
        for day in daySet {
            guard let prev = previousDay(day), !daySet.contains(prev) else { continue }
            var length = 1
            var cursor = day
            while let next = nextDay(cursor), daySet.contains(next) {
                length += 1
                cursor = next
            }
            best = max(best, length)
        }
        return best
    }

    /// Consecutive days with dictation ending at `today`. Zero if `today` has none.
    static func currentStreak(endingAt today: String, in daySet: Set<String>) -> Int {
        guard daySet.contains(today) else { return 0 }
        var length = 1
        var cursor = today
        while let prev = previousDay(cursor), daySet.contains(prev) {
            length += 1
            cursor = prev
        }
        return length
    }

    // MARK: - Day-key arithmetic (UTC, matches DictationStats.dayKey)

    /// A fixed UTC gregorian calendar — the ONLY calendar used for day-key math so
    /// results never depend on the viewer's locale/timezone (and DST can't shift a
    /// day boundary, since UTC has none).
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func parse(_ dayKey: String) -> Date? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        c.hour = 12 // noon UTC — safely away from any boundary
        return utcCalendar.date(from: c)
    }

    private static func format(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The `yyyy-MM-dd` day after `dayKey`, or nil if the key is malformed.
    static func nextDay(_ dayKey: String) -> String? {
        guard let date = parse(dayKey),
              let next = utcCalendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return format(next)
    }

    /// The `yyyy-MM-dd` day before `dayKey`, or nil if the key is malformed.
    static func previousDay(_ dayKey: String) -> String? {
        guard let date = parse(dayKey),
              let prev = utcCalendar.date(byAdding: .day, value: -1, to: date) else { return nil }
        return format(prev)
    }

    // MARK: - Display helpers

    /// Best-effort readable name from a reverse-DNS bundle id when we have no
    /// running-app display name (e.g. the app that recorded it isn't running now).
    /// "com.google.Chrome" → "Chrome"; "com.apple.Notes" → "Notes".
    static func prettifyBundleID(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        // Split camelCase into words so "TextEdit" → "Text Edit".
        var out = ""
        for (i, ch) in last.enumerated() {
            if i > 0 && ch.isUppercase { out.append(" ") }
            out.append(ch)
        }
        return out.isEmpty ? bundleID : out
    }

    static func prettifyEngine(_ engine: String) -> String {
        switch engine {
        case "whisperKit":  return "WhisperKit"
        case "whisper":     return "whisper.cpp"
        case "appleSpeech": return "Apple Speech"
        case "speechAnalyzer": return "Apple SpeechAnalyzer"
        default:            return engine
        }
    }

    // MARK: - Human formatting (pure)

    /// A compact "time saved" phrase like "2h 5m" / "45m" / "30s". Deterministic,
    /// so it's directly testable and reusable by the share card.
    static func formatDuration(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total > 0 else { return "0s" }
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return s > 0 && m < 10 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }
}
