import Foundation

/// Renders a completed **file transcription** (MAK-36) into a single editable
/// Scratchpad note body, and inserts it into `ScratchpadNotes` (MAK-98:
/// "Open in Scratchpad" for transcribed audio/video files).
///
/// The sibling of `MeetingScratchpadExport`, and deliberately the same shape: the
/// File Transcription pane shows a completed job's transcript as a read-only
/// three-line preview, and this is the seam that turns it into something the user
/// can edit, re-dictate into, and keep alongside their other notes.
///
/// **It takes primitives, not the job.** `FileTranscriptionJob` is internal to the
/// app/core boundary while this renderer is `public` like its meeting sibling, and
/// — more usefully — passing `(name, duration, transcript)` means every layout rule
/// below is pinned by `swift test` without constructing a queue job at all. The
/// pane is a thin caller that reads `job.displayName` / `job.durationSeconds` /
/// `job.fullText`.
///
/// **Layout** (sections separated by one blank line, no trailing blank lines):
///
///     # interview.m4a — Jul 28, 2026 at 3:14 PM · 12m 30s
///
///     ## Transcript
///
///     <transcript body>
///
/// Rules the tests pin:
/// - The header is always present — it is the note's `displayTitle` in the list, so
///   an otherwise-empty transcript still reads as the file rather than "New note".
/// - The duration suffix appears only for a positive duration (a job whose decode
///   never determined one carries `durationSeconds == 0`).
/// - A blank / whitespace-only file name falls back to a generic label, so the
///   header can never render a dangling em dash with nothing before it.
/// - An empty transcript still renders the `## Transcript` heading with an explicit
///   `(no transcript)` placeholder — mirroring the meeting export, so the note never
///   silently looks like the transcript was lost.
/// - The body is whitespace-trimmed at its edges; interior formatting is untouched.
///
/// There is no `## Summary` section (unlike meetings): a file job has no summary —
/// the pane's optional LLM pass *enhances the transcript in place* rather than
/// producing a separate artifact.
public enum FileTranscriptScratchpadExport {

    /// Placeholder body used when the job produced no (non-blank) text. Same wording
    /// as the meeting export so the two surfaces agree.
    public static let noTranscriptPlaceholder = MeetingScratchpadExport.noTranscriptPlaceholder

    /// Header label for a job with no usable file name. Blank names shouldn't happen
    /// (the queue defaults `displayName` to the path's last component), but a note
    /// titled "# — Jul 28" would be worse than a generic word.
    public static let untitledFileName = "Transcript"

    /// The note body for a completed file transcription: header line, then the
    /// `## Transcript` section.
    ///
    /// - Parameters:
    ///   - fileName: the job's `displayName` (the source file's name).
    ///   - date: the timestamp for the header — the pane passes the job's `addedAt`
    ///     (the queue records no completion time).
    ///   - duration: the media duration in seconds (`durationSeconds`); `0` or
    ///     negative drops the suffix.
    ///   - transcript: the job's `fullText`. Empty/whitespace yields the placeholder.
    ///   - formatter: date formatter for the header. Injectable so tests are
    ///     locale/timezone independent; defaults to the shared medium-date formatter.
    public static func noteText(
        fileName: String,
        date: Date,
        duration: TimeInterval,
        transcript: String,
        formatter: DateFormatter? = nil
    ) -> String {
        let head = header(fileName: fileName, date: date, duration: duration, formatter: formatter)
        return head + "\n\n## Transcript\n\n" + transcriptBody(transcript)
    }

    /// The first line of the note — what the Scratchpad list shows as its title.
    /// `"# <file name> — <date>"`, plus `" · <duration>"` when the duration is positive.
    ///
    /// An H1 (MAK-96) like the meeting header, so both surfaces render identically in
    /// the Markdown preview. The `#` costs the list nothing: the sidebar title comes
    /// from `ScratchpadText.listTitle`, which strips Markdown markers.
    public static func header(
        fileName: String,
        date: Date,
        duration: TimeInterval,
        formatter: DateFormatter? = nil
    ) -> String {
        let f = formatter ?? defaultFormatter
        let name = trimmed(fileName).isEmpty ? untitledFileName : trimmed(fileName)
        var line = "# " + name + " — " + f.string(from: date)
        // Reuse the meeting export's duration rendering so "12m 30s" means the same
        // thing on both surfaces — one implementation, one set of rounding-edge tests.
        if let d = MeetingScratchpadExport.durationLabel(duration) { line += " · " + d }
        return line
    }

    /// The transcript text to embed: the trimmed transcript, else the placeholder.
    /// Never empty.
    static func transcriptBody(_ transcript: String) -> String {
        let body = trimmed(transcript)
        return body.isEmpty ? noTranscriptPlaceholder : body
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
    /// Insert a completed file transcription as a NEW Scratchpad note and return its
    /// id (MAK-98 "Open in Scratchpad").
    ///
    /// A fresh note every time — deliberately not an upsert keyed on the job, for the
    /// same reason `insertMeetingNote` isn't: the note is *editable*, so re-exporting
    /// a transcript the user has already annotated must never clobber their edits. It
    /// sorts to the front like any other newly-touched note.
    ///
    /// **Provenance**: the body is machine-generated, so neither `lastDictatedAt` nor
    /// `lastTypedAt` is stamped — the note reads as `.empty` origin until the user
    /// actually types or dictates into it.
    @discardableResult
    mutating func insertFileTranscriptNote(
        fileName: String,
        date: Date,
        duration: TimeInterval,
        transcript: String,
        now: Date = Date(),
        formatter: DateFormatter? = nil
    ) -> UUID {
        let id = createNote(now: now)
        // Route the body through the same setText path the editor uses, then clear
        // the typed stamp it sets: the text did not come from the user's keyboard.
        setText(
            FileTranscriptScratchpadExport.noteText(
                fileName: fileName, date: date, duration: duration,
                transcript: transcript, formatter: formatter),
            for: id, now: now)
        clearTypedProvenance(for: id)
        return id
    }
}
