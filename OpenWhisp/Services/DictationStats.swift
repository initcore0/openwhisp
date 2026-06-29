import Foundation

/// One completed-dictation event — METADATA ONLY. Deliberately holds NO transcript
/// text (counts/durations/identifiers only) so the stats store can never leak what
/// was said. Folded into `DictationStats` aggregates; not itself persisted.
struct DictationEvent: Equatable {
    /// When the dictation completed.
    let date: Date
    /// Word count of the final transcript.
    let wordCount: Int
    /// Character count of the final transcript.
    let charCount: Int
    /// Whole-session wall-clock duration in seconds (hotkey-down → final text).
    let durationSeconds: Double
    /// Transcription engine id ("whisperKit" / "whisper" / "appleSpeech").
    let engine: String
    /// Model id for the engine (whisper.cpp GGML name or WhisperKit model id), if any.
    let model: String?
    /// Output mode ("preview" / "liveChunks" / "finalOnly").
    let outputMode: String
    /// Target app BUNDLE ID only (no app name) — coarse usage breakdown.
    let appBundleID: String?
    /// Seconds from the user finishing speaking to the final text being ready
    /// (transcription latency), when measurable; nil otherwise.
    let transcriptionLatencySeconds: Double?

    /// Word count via whitespace splitting — the single definition used everywhere
    /// so counts are consistent. Static + pure so it's unit-tested directly.
    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// Per-day rollup bucket. Keyed by an ISO `yyyy-MM-dd` day string (UTC) in the
/// parent map. Sums only — no per-event rows, so it stays compact and bounded.
struct DictationDayStats: Codable, Equatable {
    var sessions: Int = 0
    var words: Int = 0
    var characters: Int = 0
    var seconds: Double = 0
}

/// Aggregate dictation statistics: lifetime totals + per-day rollups + small
/// per-dimension breakdowns (by engine, by app bundle id). METADATA ONLY — never
/// any transcript text. Local-only for now (see `DictationStatsStore`); collected
/// but not surfaced in the UI.
///
/// Pure value type with a single `record(_:)` fold, so it's deterministic and
/// unit-tested. The store handles persistence; AppState calls `record` per
/// completed dictation.
struct DictationStats: Codable, Equatable {
    /// Bumped if the on-disk shape changes, so a future reader can migrate.
    var schemaVersion: Int = 1

    // Lifetime totals.
    var totalSessions: Int = 0
    var totalWords: Int = 0
    var totalCharacters: Int = 0
    var totalSeconds: Double = 0

    /// Per-day rollups, keyed by `yyyy-MM-dd` (UTC).
    var byDay: [String: DictationDayStats] = [:]
    /// Sessions per engine id.
    var sessionsByEngine: [String: Int] = [:]
    /// Sessions per target app bundle id (key "unknown" when absent).
    var sessionsByApp: [String: Int] = [:]

    // Latency accumulators, so an average can be derived without storing rows.
    var latencySamples: Int = 0
    var latencyTotalSeconds: Double = 0

    /// Average transcription latency in seconds, or nil if never measured.
    var averageLatencySeconds: Double? {
        latencySamples > 0 ? latencyTotalSeconds / Double(latencySamples) : nil
    }

    /// Day key (`yyyy-MM-dd`, UTC) for a date — the bucket key for `byDay`.
    static func dayKey(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Fold a completed-dictation event into the aggregates. Pure: no IO, no clock
    /// reads (the event carries its own `date`).
    mutating func record(_ event: DictationEvent) {
        totalSessions += 1
        totalWords += event.wordCount
        totalCharacters += event.charCount
        totalSeconds += max(0, event.durationSeconds)

        let key = Self.dayKey(for: event.date)
        var day = byDay[key] ?? DictationDayStats()
        day.sessions += 1
        day.words += event.wordCount
        day.characters += event.charCount
        day.seconds += max(0, event.durationSeconds)
        byDay[key] = day

        sessionsByEngine[event.engine, default: 0] += 1
        sessionsByApp[event.appBundleID ?? "unknown", default: 0] += 1

        if let latency = event.transcriptionLatencySeconds, latency >= 0 {
            latencySamples += 1
            latencyTotalSeconds += latency
        }
    }
}
