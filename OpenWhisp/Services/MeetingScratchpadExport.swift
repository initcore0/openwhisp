import Foundation

/// Renders a `Meeting` into a single editable Scratchpad note body, and inserts it
/// into `ScratchpadNotes` (MAK-49 + MAK-50: "Open in Scratchpad").
///
/// The Meetings pane shows a meeting's transcript and summary as *read-only* text.
/// This is the seam that turns them into something the user can edit, re-dictate
/// into, and keep alongside their other notes — one plain-text note, not Markdown
/// rendering, because the Scratchpad editor is a plain `NSTextView`.
///
/// Pure and Foundation-only so the note layout is pinned by `swift test` rather than
/// asserted by eye in the app; the pane is a thin caller.
///
/// **Layout** (sections separated by one blank line, no trailing blank lines):
///
///     Meeting — Jul 28, 2026 at 3:14 PM · 12m 30s
///
///     ## Summary
///
///     <summary body>
///
///     ## Transcript
///
///     <transcript body>
///
/// Rules the tests pin:
/// - The header is always present — it is the note's `displayTitle` in the list, so
///   an otherwise-empty meeting still reads as a meeting rather than "New note".
/// - The duration suffix appears only for a positive duration.
/// - A nil / empty / whitespace-only summary drops the whole `## Summary` section
///   (no empty heading).
/// - An absent transcript still renders the `## Transcript` heading with an explicit
///   `(no transcript)` placeholder — mirroring `exportMarkdown`, so the note never
///   silently looks like the transcript was lost.
/// - Every body is whitespace-trimmed at its edges; interior formatting is untouched.
public enum MeetingScratchpadExport {

    /// Placeholder body used when the meeting has no (non-blank) transcript. Same
    /// wording as the Markdown export so the two surfaces agree.
    public static let noTranscriptPlaceholder = "(no transcript)"

    /// The note body for a meeting: header line, optional `## Summary` section, then
    /// the `## Transcript` section.
    ///
    /// - Parameters:
    ///   - meeting: the meeting to render. `attributedTranscript` (Me/Them labels)
    ///     wins over the plain `transcript` when it carries text, matching the detail
    ///     view, the Markdown export, and the summarizer input.
    ///   - formatter: date formatter for the header. Injectable so tests are
    ///     locale/timezone independent; defaults to the shared medium-date formatter.
    public static func noteText(for meeting: Meeting, formatter: DateFormatter? = nil) -> String {
        var sections: [String] = [header(for: meeting, formatter: formatter)]

        let summary = trimmed(meeting.summary)
        if !summary.isEmpty {
            sections.append("## Summary\n\n" + summary)
        }

        sections.append("## Transcript\n\n" + transcriptBody(for: meeting))
        return sections.joined(separator: "\n\n")
    }

    /// The first line of the note — what the Scratchpad list shows as its title.
    /// `"Meeting — <date>"`, plus `" · <duration>"` when the duration is positive.
    public static func header(for meeting: Meeting, formatter: DateFormatter? = nil) -> String {
        let f = formatter ?? defaultFormatter
        var line = "Meeting — " + f.string(from: meeting.startedAt)
        if let d = durationLabel(meeting.duration) { line += " · " + d }
        return line
    }

    /// The transcript text to embed: the attributed transcript when it has content,
    /// else the plain transcript, else the placeholder. Never empty.
    static func transcriptBody(for meeting: Meeting) -> String {
        let attributed = trimmed(meeting.attributedTranscript)
        if !attributed.isEmpty { return attributed }
        let plain = trimmed(meeting.transcript)
        if !plain.isEmpty { return plain }
        return noTranscriptPlaceholder
    }

    /// A compact duration label — `"45s"`, `"12m 30s"`, `"1h 05m"`. `nil` for a
    /// non-positive duration (an un-timed or still-empty recording), which drops the
    /// suffix from the header entirely rather than printing a bare "0s".
    static func durationLabel(_ duration: TimeInterval) -> String? {
        guard duration > 0 else { return nil }
        let total = Int(duration.rounded())
        // Guard the rounding edge: a 0 < duration < 0.5 rounds to 0 seconds, which
        // would print "0s" — treat it as no meaningful duration.
        guard total > 0 else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private static func trimmed(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let defaultFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

public extension ScratchpadNotes {
    /// Insert a meeting's transcript + summary as a NEW Scratchpad note and return
    /// its id (MAK-50 "Open in Scratchpad").
    ///
    /// A fresh note every time — deliberately not an upsert keyed on the meeting:
    /// the note is *editable*, so re-exporting a meeting the user has already
    /// annotated must never clobber their edits. It sorts to the front like any
    /// other newly-touched note.
    ///
    /// **Provenance**: the body is machine-generated, so neither `lastDictatedAt`
    /// nor `lastTypedAt` is stamped — the note reads as `.empty` origin ("New note"
    /// in the provenance line) until the user actually types or dictates into it.
    /// `createdAt`/`updatedAt` are both `now`, which is what drives list ordering.
    @discardableResult
    mutating func insertMeetingNote(
        _ meeting: Meeting,
        now: Date = Date(),
        formatter: DateFormatter? = nil
    ) -> UUID {
        let id = createNote(now: now)
        // Route the body through the same setText path the editor uses, then clear
        // the typed stamp it sets: the text did not come from the user's keyboard.
        setText(MeetingScratchpadExport.noteText(for: meeting, formatter: formatter), for: id, now: now)
        clearTypedProvenance(for: id)
        return id
    }
}
