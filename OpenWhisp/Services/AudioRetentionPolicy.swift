import Foundation

/// The user's opt-in raw-audio retention configuration (MAK-40).
///
/// When `enabled`, each dictation's raw audio is copied beside its history entry
/// so the user can re-transcribe it later. OFF by default — the audio NEVER leaves
/// this device, but keeping it at all is a deliberate choice the user makes.
///
/// Persisted independently (UserDefaults keys in AppState, mirrored here as a
/// Codable value so the sweep decision round-trips in tests). The two caps compose:
/// a clip is pruned if its entry is older than `maxAgeDays` OR the clip falls
/// outside the newest `maxEntries` retained clips — whichever removes it first.
/// `0` disables that particular cap.
public struct AudioRetentionSettings: Codable, Equatable {
    /// Master switch. OFF by default — retention is strictly opt-in.
    public var enabled: Bool
    /// Delete audio + its history entry older than this many days. `0` = no age cap.
    public var maxAgeDays: Int
    /// Keep at most this many retained audio clips (newest first). `0` = no count
    /// cap. Independent of the 200-entry history cap: history can hold more
    /// text-only entries than retained clips.
    public var maxEntries: Int

    public init(enabled: Bool = false, maxAgeDays: Int = 0, maxEntries: Int = 50) {
        self.enabled = enabled
        self.maxAgeDays = maxAgeDays
        self.maxEntries = maxEntries
    }

    /// Explicit decoding so an older/partial persisted blob fills missing keys with
    /// the defaults rather than failing the whole load (mirrors TranscriptionEntry).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        maxAgeDays = try c.decodeIfPresent(Int.self, forKey: .maxAgeDays) ?? 0
        maxEntries = try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? 50
    }
}

/// Pure, testable retention-policy logic for stored dictation audio (MAK-40).
///
/// Two responsibilities, both Foundation-only so `swift test` covers them without
/// touching disk:
///
///  1. **Naming scheme** — the app owns exactly one filename shape for retained
///     audio: `retained-<uuid>.<ext>`. `isRetainedAudioFileName` is the guard the
///     disk sweep MUST pass every candidate through before deleting it, so a sweep
///     can only ever remove files THIS app created. It never deletes by directory
///     listing alone.
///  2. **Sweep decision** — given the current entries and an injected `now`, decide
///     which entries' audio should be pruned (age cap and/or count cap). Returns the
///     entry IDs to drop; the app-side store maps those to filenames and deletes.
public enum AudioRetentionPolicy {

    /// Prefix every retained-audio filename carries. The sweep only ever touches
    /// files that both start with this AND parse as `<prefix><uuid>.<ext>`.
    public static let fileNamePrefix = "retained-"

    /// Allowed on-disk audio extensions (lowercased). WAV is what the capture
    /// pipeline already writes (16 kHz mono 16-bit); m4a is accepted for a future
    /// AAC-compressed path.
    public static let allowedExtensions: Set<String> = ["wav", "m4a"]

    /// The canonical filename for an entry's retained audio.
    public static func fileName(for entryID: UUID, ext: String = "wav") -> String {
        "\(fileNamePrefix)\(entryID.uuidString).\(ext.lowercased())"
    }

    /// True iff `name` is a filename THIS app would have written for retained
    /// audio: the exact `retained-<uuid>.<allowed-ext>` shape. The disk sweep
    /// gates every deletion on this so it can never remove an unrelated file that
    /// merely happens to sit in the audio directory.
    public static func isRetainedAudioFileName(_ name: String) -> Bool {
        parseEntryID(fromFileName: name) != nil
    }

    /// Extracts the entry UUID a retained-audio filename encodes, or nil if the
    /// name doesn't match the scheme (prefix + valid UUID + allowed extension).
    public static func parseEntryID(fromFileName name: String) -> UUID? {
        // The guard validates a LEAF filename only. Reject anything containing a
        // path separator (or a NUL) outright — otherwise a crafted name like
        // "retained-../../x/retained-<uuid>.wav" would pass the prefix/extension/
        // lastPathComponent checks below while escaping the audio directory when
        // appended as a path component. Deletes and reads must never traverse.
        guard !name.contains("/"), !name.contains("\0") else { return nil }
        guard name.hasPrefix(fileNamePrefix) else { return nil }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        guard base.hasPrefix(fileNamePrefix) else { return nil }
        let uuidPart = String(base.dropFirst(fileNamePrefix.count))
        return UUID(uuidString: uuidPart)
    }

    /// One entry as the policy sees it: identity, when it was recorded, and whether
    /// it currently has retained audio. Kept minimal (not the full
    /// `TranscriptionEntry`) so the policy stays independent of the history model
    /// and is trivially testable.
    public struct Candidate: Equatable {
        public let id: UUID
        public let date: Date
        public let hasAudio: Bool
        public init(id: UUID, date: Date, hasAudio: Bool) {
            self.id = id
            self.date = date
            self.hasAudio = hasAudio
        }
    }

    /// The result of evaluating the policy: which entries' audio to delete, and —
    /// separately — which entries should be dropped from history entirely (the age
    /// cap deletes the history entry too, per the ticket: "delete audio+history
    /// older than N days").
    public struct Sweep: Equatable {
        /// Entry IDs whose audio file should be removed (the text entry may be kept).
        public let audioToDelete: Set<UUID>
        /// Entry IDs to remove from history entirely (age cap). Every ID here that
        /// had audio also appears in `audioToDelete`.
        public let entriesToDelete: Set<UUID>
        public init(audioToDelete: Set<UUID>, entriesToDelete: Set<UUID>) {
            self.audioToDelete = audioToDelete
            self.entriesToDelete = entriesToDelete
        }
        public var isEmpty: Bool { audioToDelete.isEmpty && entriesToDelete.isEmpty }
    }

    /// Decide what to prune given the current entries, the policy settings, and an
    /// injected `now` (so tests are deterministic — no wall-clock read).
    ///
    /// Rules, applied to `candidates` (any order; sorted internally newest-first):
    ///  - **Age cap** (`maxAgeDays > 0`): an entry older than the cutoff is dropped
    ///    ENTIRELY (its history row and its audio) — matches the ticket's "delete
    ///    audio + history older than N days".
    ///  - **Count cap** (`maxEntries > 0`): among the audio-bearing entries that
    ///    survive the age cap, keep only the newest `maxEntries`; the rest have
    ///    their AUDIO removed (the text history row is kept — the count cap is about
    ///    disk-heavy audio, not the lightweight text log).
    ///
    /// When `enabled` is false the sweep is empty — retention off means the app
    /// never auto-deletes the user's history or files behind their back.
    public static func evaluate(
        candidates: [Candidate],
        settings: AudioRetentionSettings,
        now: Date
    ) -> Sweep {
        guard settings.enabled else {
            return Sweep(audioToDelete: [], entriesToDelete: [])
        }

        var entriesToDelete: Set<UUID> = []
        var audioToDelete: Set<UUID> = []

        // Age cap: drop whole entries older than the cutoff.
        if settings.maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(settings.maxAgeDays) * 86_400)
            for c in candidates where c.date < cutoff {
                entriesToDelete.insert(c.id)
                if c.hasAudio { audioToDelete.insert(c.id) }
            }
        }

        // Count cap: among surviving audio-bearing entries, keep newest N clips.
        if settings.maxEntries > 0 {
            let survivingAudio = candidates
                .filter { $0.hasAudio && !entriesToDelete.contains($0.id) }
                .sorted { $0.date > $1.date }
            if survivingAudio.count > settings.maxEntries {
                for c in survivingAudio.dropFirst(settings.maxEntries) {
                    audioToDelete.insert(c.id)
                }
            }
        }

        return Sweep(audioToDelete: audioToDelete, entriesToDelete: entriesToDelete)
    }
}
