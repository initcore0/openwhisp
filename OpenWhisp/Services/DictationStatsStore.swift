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
        guard let data = try? Data(contentsOf: fileURL) else { return DictationStats() }
        do {
            return try JSONDecoder().decode(DictationStats.self, from: data)
        } catch {
            // The file exists but is undecodable (corruption, hand-edit, version
            // skew). Move it aside instead of returning defaults silently — the
            // next save would otherwise overwrite it and make the loss permanent.
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            print("[DictationStatsStore] load failed: \(error); moved file to \(backup.lastPathComponent)")
            return DictationStats()
        }
    }

    static func save(_ stats: DictationStats) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(stats)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[DictationStatsStore] save failed: \(error.localizedDescription)")
        }
    }
}
