import Foundation

/// A single completed dictation, recorded locally for the user to recover/reuse.
struct TranscriptionEntry: Codable, Identifiable, Equatable {
    let id: UUID
    /// The final text that was inserted (LLM-refined when a cleanup tier ran,
    /// otherwise identical to `rawText`).
    let text: String
    let date: Date
    /// Bundle ID of the app the text was inserted into, if known.
    let appBundleID: String?
    /// Friendly app name, if known.
    let appName: String?
    /// The RAW transcript before any AI cleanup pass, kept so the user can revert
    /// the refined `text` back to their exact words with one click (MAK-35).
    ///
    /// Optional and decoded with `decodeIfPresent` so entries written before this
    /// field existed still decode (their raw text is simply unknown → `nil`). Nil
    /// when no cleanup ran (the raw text equals `text`) or for legacy entries.
    let rawText: String?

    /// The filename (NOT the full path — just the leaf) of this dictation's
    /// retained raw audio, when opt-in audio retention was on at record time
    /// (MAK-40). The full path is resolved against the app's audio directory so a
    /// moved Application Support folder still finds the clip. `nil` when retention
    /// was off, the clip was pruned by the retention policy, or for legacy entries.
    ///
    /// Storing only the leaf (always `retained-<uuid>.<ext>`) keeps history.json
    /// portable and lets `AudioRetentionPolicy` validate the name before any delete.
    let audioFileName: String?

    init(
        id: UUID = UUID(),
        text: String,
        date: Date,
        appBundleID: String?,
        appName: String?,
        rawText: String? = nil,
        audioFileName: String? = nil
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.appBundleID = appBundleID
        self.appName = appName
        self.rawText = rawText
        self.audioFileName = audioFileName
    }

    // Explicit decoding so a missing `rawText`/`audioFileName` (older history.json
    // files) decodes to nil instead of failing the whole load. Other keys required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
    }

    /// The text a one-click "revert to original" should restore, or `nil` when
    /// there is nothing to revert to. Pure so the overlay/history revert button
    /// (a deferred UI follow-up) and any tests share one decision:
    /// - returns the stored `rawText` only when it exists AND actually differs
    ///   from the current `text` (a cleanup pass changed something to undo);
    /// - returns `nil` when no raw text was stored, or when it is identical to
    ///   `text` (nothing was changed, so "revert" would be a no-op and the UI
    ///   should hide the affordance).
    var revertTarget: String? {
        guard let raw = rawText, raw != text else { return nil }
        return raw
    }

    /// Produce the entry that results from re-transcribing this one's stored audio
    /// (MAK-40): the new text replaces `text`, and the PREVIOUS text becomes the
    /// revert baseline (`rawText`) when it differs — so the MAK-35 "revert to
    /// original" affordance restores the pre-re-transcribe words. When the new text
    /// equals the old, nothing changed, so the prior `rawText` is preserved as-is.
    /// The retained-audio filename is carried through unchanged. Pure so the app-side
    /// patch and tests share one decision.
    func reTranscribed(withNewText newText: String) -> TranscriptionEntry {
        let revertBaseline = text != newText ? text : rawText
        return TranscriptionEntry(
            id: id, text: newText, date: date,
            appBundleID: appBundleID, appName: appName,
            rawText: revertBaseline, audioFileName: audioFileName
        )
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
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    static func load() -> [TranscriptionEntry] {
        JSONStore.load(from: fileURL, default: [], label: "TranscriptionHistoryStore")
    }

    static func save(_ entries: [TranscriptionEntry]) {
        JSONStore.save(entries, to: fileURL, label: "TranscriptionHistoryStore")
    }
}

/// On-disk home for opt-in retained raw audio (MAK-40): a dedicated `audio/`
/// subdirectory next to `history.json` under Application Support, so the retention
/// sweep operates on a directory THIS app owns exclusively. Filenames follow
/// `AudioRetentionPolicy`'s `retained-<uuid>.<ext>` scheme; nothing else is ever
/// written here, and the sweep validates every candidate's name before deleting.
enum RetainedAudioStore {
    /// `~/Library/Application Support/OpenWhisp/audio/`.
    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
    }

    /// Full URL for a stored clip's leaf filename.
    static func url(for fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }
}
