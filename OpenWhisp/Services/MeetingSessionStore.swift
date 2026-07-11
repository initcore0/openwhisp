import Foundation

/// Local-only, on-device persistence for the list of `Meeting`s (MAK-50).
///
/// Mirrors the other OpenWhisp JSON stores: a `Codable` array persisted as JSON in
/// `~/Library/Application Support/OpenWhisp/meetings.json`, load/save routed through
/// `JSONStore` so the corrupt-file quarantine (`.corrupt-<epoch>`) and `0o700`
/// directory-permission invariants are shared, not re-implemented. A corrupt file is
/// moved aside and an empty list returned (never a crash, never a silent overwrite).
///
/// The store is a value type over a directory so tests can point it at a temp dir;
/// the app uses the default Application Support location. Meetings audio (the WAVs)
/// live in a sibling `meetings/` directory keyed by the meeting id's leaf filename
/// (`MeetingWAVName`) — the store persists metadata only.
public struct MeetingSessionStore {
    /// The directory holding `meetings.json` and the `meetings/` audio subfolder.
    public let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? MeetingSessionStore.defaultBaseDirectory()
    }

    /// `~/Library/Application Support/OpenWhisp`.
    public static func defaultBaseDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenWhisp", isDirectory: true)
    }

    private var fileURL: URL { baseDirectory.appendingPathComponent("meetings.json") }

    /// The directory the meeting WAVs live in (created on demand by the app when it
    /// writes a recording).
    public var audioDirectory: URL { baseDirectory.appendingPathComponent("meetings", isDirectory: true) }

    /// Resolve a meeting's stored leaf `wavFileName` to an absolute URL inside
    /// `audioDirectory`, or nil if the name is missing/unsafe (never traverses out).
    public func wavURL(for meeting: Meeting) -> URL? {
        resolvedLeafURL(meeting.wavFileName)
    }

    /// Resolve the mic ("Me") leg WAV, or nil if absent/unsafe (MAK-52).
    public func micWavURL(for meeting: Meeting) -> URL? {
        resolvedLeafURL(meeting.micWavFileName)
    }

    /// Resolve the system ("Them") leg WAV, or nil if absent/unsafe (MAK-52).
    public func systemWavURL(for meeting: Meeting) -> URL? {
        resolvedLeafURL(meeting.systemWavFileName)
    }

    /// Leaf-guarded resolution of a stored filename against `audioDirectory`
    /// (never traverses out). nil for a missing or unsafe name.
    private func resolvedLeafURL(_ name: String?) -> URL? {
        guard let name, MeetingWAVName.isValid(name) else { return nil }
        return audioDirectory.appendingPathComponent(name)
    }

    // MARK: - Load / save

    /// All meetings, newest first (by `startedAt`). Missing/empty → `[]`; corrupt →
    /// quarantined by `JSONStore` and `[]` returned.
    public func load() -> [Meeting] {
        let meetings = JSONStore.load(from: fileURL, default: [Meeting](), label: "MeetingSessionStore")
        return meetings.sorted { $0.startedAt > $1.startedAt }
    }

    public func save(_ meetings: [Meeting]) {
        JSONStore.save(meetings, to: fileURL, label: "MeetingSessionStore")
    }

    // MARK: - Mutations (load-modify-save; the caller holds the in-memory copy)

    /// Insert or replace a meeting by id, then persist. Returns the new full list
    /// (newest first) so the caller can mirror it into its `@Published` state.
    @discardableResult
    public func upsert(_ meeting: Meeting) -> [Meeting] {
        var all = load()
        if let i = all.firstIndex(where: { $0.id == meeting.id }) {
            all[i] = meeting
        } else {
            all.append(meeting)
        }
        save(all)
        return all.sorted { $0.startedAt > $1.startedAt }
    }

    /// Delete a meeting and its WAV (leaf-guarded). Returns the remaining list.
    @discardableResult
    public func delete(id: UUID) -> [Meeting] {
        var all = load()
        if let removed = all.first(where: { $0.id == id }) {
            // Only ever deletes validated leaves inside audioDirectory (MeetingWAVName):
            // the mixed WAV plus, when present, both MAK-52 leg WAVs.
            for wav in [wavURL(for: removed), micWavURL(for: removed), systemWavURL(for: removed)].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: wav)
            }
        }
        all.removeAll { $0.id == id }
        save(all)
        return all.sorted { $0.startedAt > $1.startedAt }
    }
}
