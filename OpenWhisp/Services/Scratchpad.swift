import Foundation

/// A single note in the floating dictation Scratchpad (MAK-49) — a target-free
/// surface to dictate into when no other app has focus.
///
/// Pure and Foundation-only so its provenance rules, list ordering, and
/// persistence round-trip are unit-testable via `swift test`; the NSPanel /
/// NSTextView that presents it lives in the app target.
///
/// **Provenance** is the point of the note metadata: a note records when it was
/// first created, when it was last touched at all (`updatedAt`, which drives list
/// ordering), and — separately — the last time text arrived by *dictation*
/// (`lastDictatedAt`) versus by *typing* (`lastTypedAt`). Both are optional and
/// decoded with `decodeIfPresent` so a note written before a field existed still
/// decodes. The provenance line the panel shows ("Dictated 3:14 PM · typed 3:20
/// PM") is derived purely from these, so the app view and the tests share one
/// source of truth.
public struct ScratchpadNote: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The note's body text (plain text in v1).
    public var text: String
    /// When the note was first created.
    public let createdAt: Date
    /// When the note was last modified in ANY way — drives list ordering
    /// (most-recently-touched first). Always ≥ `createdAt`.
    public var updatedAt: Date
    /// Last time text arrived by dictation, if ever. `nil` for a note only ever typed.
    public var lastDictatedAt: Date?
    /// Last time text arrived by typing, if ever. `nil` for a note only ever dictated.
    public var lastTypedAt: Date?

    public init(
        id: UUID = UUID(),
        text: String = "",
        createdAt: Date,
        updatedAt: Date? = nil,
        lastDictatedAt: Date? = nil,
        lastTypedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        // A fresh note's updatedAt defaults to its createdAt.
        self.updatedAt = updatedAt ?? createdAt
        self.lastDictatedAt = lastDictatedAt
        self.lastTypedAt = lastTypedAt
    }

    // Explicit decoding so notes written before the provenance fields existed
    // still decode (missing fields → nil / createdAt) instead of failing the load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastDictatedAt = try c.decodeIfPresent(Date.self, forKey: .lastDictatedAt)
        lastTypedAt = try c.decodeIfPresent(Date.self, forKey: .lastTypedAt)
    }

    /// A short one-line title derived from the body — the first non-empty line,
    /// trimmed and capped — for the note list. Empty notes read as "New note".
    public var displayTitle: String {
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        if firstLine.isEmpty { return "New note" }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    /// How a note was most recently sourced, for the provenance line.
    public enum Origin: Equatable, Sendable { case dictated, typed, mixed, empty }

    /// The provenance the panel shows, derived purely from the timestamps.
    /// `mixed` when the note has both a dictated and a typed timestamp.
    public var origin: Origin {
        switch (lastDictatedAt, lastTypedAt) {
        case (nil, nil):   return .empty
        case (_?, nil):    return .dictated
        case (nil, _?):    return .typed
        case (_?, _?):     return .mixed
        }
    }
}

/// The full ordered set of Scratchpad notes plus the pure mutation rules the panel
/// drives. Kept as a value type so every state transition (create, edit, append a
/// dictation, reorder) is a testable pure function; the app holds one of these and
/// persists it after each change.
public struct ScratchpadNotes: Codable, Equatable, Sendable {
    /// Notes in display order: most-recently-updated first (index 0 is newest-touched).
    public private(set) var notes: [ScratchpadNote]

    public init(notes: [ScratchpadNote] = []) {
        self.notes = ScratchpadNotes.ordered(notes)
    }

    /// Sort by `updatedAt` descending; ties broken by `id` for a stable order.
    static func ordered(_ notes: [ScratchpadNote]) -> [ScratchpadNote] {
        notes.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    /// Look up a note by id.
    public func note(_ id: UUID) -> ScratchpadNote? {
        notes.first { $0.id == id }
    }

    /// Create a new empty note and return its id. It sorts to the front (its
    /// `updatedAt` is `now`).
    @discardableResult
    public mutating func createNote(now: Date = Date()) -> UUID {
        let note = ScratchpadNote(createdAt: now)
        notes = ScratchpadNotes.ordered(notes + [note])
        return note.id
    }

    /// Replace a note's whole body — the path the NSTextView's live edits take.
    /// Marks `lastTypedAt` and bumps `updatedAt` (re-sorting the note to front).
    /// No-op for an unknown id or when the text is unchanged (so a focus event that
    /// doesn't actually edit doesn't churn ordering).
    public mutating func setText(_ text: String, for id: UUID, now: Date = Date()) {
        guard let idx = notes.firstIndex(where: { $0.id == id }), notes[idx].text != text else { return }
        var note = notes[idx]
        note.text = text
        note.updatedAt = now
        note.lastTypedAt = now
        notes[idx] = note
        notes = ScratchpadNotes.ordered(notes)
    }

    /// Append a dictation to a note. Inserts a separating space only when needed
    /// (not at the very start, not after existing whitespace). Marks
    /// `lastDictatedAt` and bumps `updatedAt`. Returns the note's full new text
    /// (what the NSTextView should now show), or nil for an unknown id.
    @discardableResult
    public mutating func appendDictation(_ dictated: String, to id: UUID, now: Date = Date()) -> String? {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return nil }
        var note = notes[idx]
        note.text = ScratchpadNotes.joined(existing: note.text, appended: dictated)
        note.updatedAt = now
        note.lastDictatedAt = now
        notes[idx] = note
        notes = ScratchpadNotes.ordered(notes)
        return note.text
    }

    /// Drop the "typed" provenance stamp from a note (no-op if unknown).
    ///
    /// Used by machine-authored inserts (e.g. `insertMeetingNote`) that reuse
    /// `setText` to lay down the body: the text did not come from the user's
    /// keyboard, so the note must not claim it was typed. Ordering (`updatedAt`) is
    /// deliberately left alone — the note was still just touched.
    public mutating func clearTypedProvenance(for id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].lastTypedAt = nil
    }

    /// Delete a note by id (no-op if unknown).
    public mutating func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
    }

    /// The join rule for appended dictation: no separator when the note is empty or
    /// already ends in whitespace; otherwise a single space. Keeps a paragraph the
    /// user is building from getting a stray leading space.
    static func joined(existing: String, appended: String) -> String {
        let piece = appended.trimmingCharacters(in: .whitespacesAndNewlines)
        if piece.isEmpty { return existing }
        if existing.isEmpty { return piece }
        if existing.last?.isWhitespace == true { return existing + piece }
        return existing + " " + piece
    }
}

/// Loads/saves the Scratchpad notes as JSON in Application Support, via the shared
/// quarantine-on-corruption `JSONStore` path. Local-only — the notes never leave
/// the machine.
public enum ScratchpadStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("scratchpad.json")
    }

    public static func load() -> ScratchpadNotes {
        // Re-order on load so a hand-edited or older file always presents sorted.
        JSONStore.load(
            from: fileURL, default: ScratchpadNotes(), label: "ScratchpadStore",
            transform: { ScratchpadNotes(notes: $0.notes) }
        )
    }

    public static func save(_ notes: ScratchpadNotes) {
        JSONStore.save(notes, to: fileURL, label: "ScratchpadStore")
    }
}
