import Foundation

/// A single completed dictation, recorded locally for the user to recover/reuse.
struct TranscriptionEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    /// Bundle ID of the app the text was inserted into, if known.
    let appBundleID: String?
    /// Friendly app name, if known.
    let appName: String?

    init(id: UUID = UUID(), text: String, date: Date, appBundleID: String?, appName: String?) {
        self.id = id
        self.text = text
        self.date = date
        self.appBundleID = appBundleID
        self.appName = appName
    }
}

/// Local, on-device store of recent transcriptions (JSON in Application Support).
/// Bounded to a retention cap so it can't grow without limit. Entirely local —
/// this is a privacy-positive feature (recover text you pasted into the wrong
/// window) and never leaves the machine.
enum TranscriptionHistoryStore {
    /// Hard cap on retained entries.
    static let maxEntries = 200

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("VoiceNote", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    static func load() -> [TranscriptionEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([TranscriptionEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func save(_ entries: [TranscriptionEntry]) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[TranscriptionHistoryStore] save failed: \(error.localizedDescription)")
        }
    }
}
