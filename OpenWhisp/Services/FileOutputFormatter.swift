import Foundation

/// The pure, testable core of the file output target (MAK-12).
///
/// The `FileOutputTarget` (app-side, `OutputTarget`) does the actual file I/O, but
/// EVERYTHING about *what bytes to write* — how a dictation is rendered into an
/// entry, what heading/timestamp wraps it, whether an append needs a leading
/// separator — lives here as side-effect-free functions over a `FileOutputConfig`.
/// That keeps the decision logic in `OpenWhispCore` so `swift test` can cover it
/// without touching the filesystem.
///
/// Foundation-only (no AppKit) so it compiles into `OpenWhispCore`.

// MARK: - Write mode

/// Whether the file target appends each dictation to the end of the file (the
/// note-taking / daily-log case) or overwrites the file with the latest one (a
/// scratch "last dictation" buffer). Persisted, so the raw values are a stored
/// contract — pin them.
enum FileOutputMode: String, Codable, CaseIterable, Equatable {
    /// Add the entry to the end of the existing file, separated from prior content.
    case append
    /// Replace the whole file with just this entry.
    case overwrite
}

// MARK: - Config

/// A Codable description of a file sink: WHERE to write, HOW to wrap each entry,
/// and append-vs-overwrite. Lives in core so a Settings surface can persist it and
/// it round-trips in tests.
///
/// `template` is an optional heading/prefix rendered ABOVE the dictation text. It
/// supports two substitution tokens so a user can build a dated heading without any
/// code:
///   - `{{date}}`     → the current date (`yyyy-MM-dd`)
///   - `{{time}}`     → the current time (`HH:mm`)
///   - `{{datetime}}` → `yyyy-MM-dd HH:mm`
/// e.g. `template: "## {{datetime}}"` renders `## 2026-07-09 14:30` above the text.
/// When `template` is nil or blank, the entry is just the dictation text (no heading).
struct FileOutputConfig: Codable, Equatable {
    /// Absolute path to the target file (e.g. an Obsidian daily note). A relative
    /// path is resolved by the writer against the user's home directory; the
    /// formatter itself never touches the path — it only renders content.
    var path: String
    /// Optional heading/prefix template rendered above the text. See the type doc
    /// for the supported `{{date}}` / `{{time}}` / `{{datetime}}` tokens. nil/blank
    /// = no heading.
    var template: String?
    /// Append to the file or overwrite it.
    var mode: FileOutputMode

    init(path: String, template: String? = nil, mode: FileOutputMode = .append) {
        self.path = path
        self.template = template
        self.mode = mode
    }
}

// MARK: - Formatter

/// Pure rendering of a dictation into the exact text to write/append. No I/O.
enum FileOutputFormatter {

    /// Render the ENTRY for one dictation: the optional heading (with `{{date}}` /
    /// `{{time}}` / `{{datetime}}` expanded) on its own line, then the text. This is
    /// the self-contained block — it carries no leading/trailing separators; joining
    /// it onto an existing file is `renderAppendChunk` / `renderOverwriteContents`.
    ///
    /// - Parameters:
    ///   - text:     the dictated text (already post-processed).
    ///   - config:   the sink config (only `template` is consulted here).
    ///   - date:     the timestamp to expand tokens against (injected so tests are
    ///               deterministic; defaults to now).
    ///   - calendar/locale/timeZone: injected for deterministic token formatting.
    /// - Returns: the rendered entry, or `nil` when `text` is empty/whitespace (the
    ///   caller then writes nothing — an empty dictation must never append a bare
    ///   heading or a stray separator).
    static func renderEntry(
        text: String,
        config: FileOutputConfig,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        guard let heading = expandedHeading(config.template, date: date, timeZone: timeZone, locale: locale) else {
            return body
        }
        return heading + "\n" + body
    }

    /// The chunk to APPEND to an existing file: the rendered entry prefixed with a
    /// blank-line separator so it doesn't run into the previous content, and given a
    /// trailing newline so the file stays newline-terminated and the NEXT append is
    /// cleanly separated too.
    ///
    /// `existingContents` decides the leading separator:
    ///   - empty file        → no leading newlines (the entry starts the file).
    ///   - ends with "\n\n"  → already blank-line separated → add nothing.
    ///   - ends with "\n"    → one more newline makes the blank-line separator.
    ///   - ends mid-line     → two newlines (finish the line + a blank line).
    /// Returns `nil` when the entry is empty (see `renderEntry`) — nothing to append.
    static func renderAppendChunk(
        text: String,
        config: FileOutputConfig,
        existingContents: String,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String? {
        guard let entry = renderEntry(text: text, config: config, date: date, timeZone: timeZone, locale: locale) else {
            return nil
        }
        let separator = appendSeparator(for: existingContents)
        return separator + entry + "\n"
    }

    /// The FULL contents to write when overwriting: just the rendered entry with a
    /// trailing newline. Returns `nil` for an empty dictation (nothing to write —
    /// the caller leaves the file untouched rather than blanking it).
    static func renderOverwriteContents(
        text: String,
        config: FileOutputConfig,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String? {
        guard let entry = renderEntry(text: text, config: config, date: date, timeZone: timeZone, locale: locale) else {
            return nil
        }
        return entry + "\n"
    }

    // MARK: - Internals

    /// Expand a heading template's tokens, or nil when there's no usable heading
    /// (template nil or blank after trimming).
    static func expandedHeading(
        _ template: String?,
        date: Date,
        timeZone: TimeZone,
        locale: Locale
    ) -> String? {
        guard let template else { return nil }
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let dateStr = formatted(date, "yyyy-MM-dd", timeZone: timeZone, locale: locale)
        let timeStr = formatted(date, "HH:mm", timeZone: timeZone, locale: locale)
        let dateTimeStr = formatted(date, "yyyy-MM-dd HH:mm", timeZone: timeZone, locale: locale)

        // {{datetime}} first so it isn't partially eaten by {{date}}/{{time}}.
        return trimmed
            .replacingOccurrences(of: "{{datetime}}", with: dateTimeStr)
            .replacingOccurrences(of: "{{date}}", with: dateStr)
            .replacingOccurrences(of: "{{time}}", with: timeStr)
    }

    private static func formatted(_ date: Date, _ format: String, timeZone: TimeZone, locale: Locale) -> String {
        let df = DateFormatter()
        df.locale = locale
        df.timeZone = timeZone
        df.dateFormat = format
        return df.string(from: date)
    }

    /// The leading separator that places a blank line between existing content and
    /// the new entry (see `renderAppendChunk`).
    private static func appendSeparator(for existing: String) -> String {
        if existing.isEmpty { return "" }
        if existing.hasSuffix("\n\n") { return "" }
        if existing.hasSuffix("\n") { return "\n" }
        return "\n\n"
    }
}
