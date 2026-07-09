import Foundation

/// Local-only persistence for `DictationStats` (JSON in Application Support).
///
/// METADATA ONLY and **on-device only** — these aggregates are collected but never
/// transmitted and never surfaced in the UI yet. No transcript text is ever stored
/// (see `DictationStats`/`DictationEvent`). A future opt-in step could upload, but
/// nothing here does.
enum DictationStatsStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("stats.json")
    }

    static func load() -> DictationStats {
        JSONStore.load(from: fileURL, default: DictationStats(), label: "DictationStatsStore")
    }

    static func save(_ stats: DictationStats) {
        JSONStore.save(stats, to: fileURL, label: "DictationStatsStore")
    }
}
