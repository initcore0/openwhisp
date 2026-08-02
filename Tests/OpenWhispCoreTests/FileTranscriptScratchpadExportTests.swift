import XCTest
@testable import OpenWhispCore

/// Tests for "Open in Scratchpad" on transcribed FILES (MAK-98): the pure
/// `FileTranscriptScratchpadExport` note renderer and the
/// `ScratchpadNotes.insertFileTranscriptNote` mutation behind the File
/// Transcription pane's action.
///
/// The sibling of `MeetingScratchpadExportTests`, and deliberately parallel to it.
final class FileTranscriptScratchpadExportTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Fixed-format, fixed-timezone formatter so the header assertions don't depend
    /// on the machine's locale/timezone.
    private var fixedFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }

    private func text(
        fileName: String = "interview.m4a",
        duration: TimeInterval = 0,
        transcript: String = ""
    ) -> String {
        FileTranscriptScratchpadExport.noteText(
            fileName: fileName, date: t0, duration: duration,
            transcript: transcript, formatter: fixedFormatter)
    }

    // MARK: - Full layout

    func testFullNoteLayoutHeaderThenTranscript() {
        let note = text(fileName: "interview.m4a", duration: 750, transcript: "We shipped it.")
        XCTAssertEqual(note, """
        # interview.m4a — 1970-01-12 13:46 · 12m 30s

        ## Transcript

        We shipped it.
        """)
    }

    func testNoteHasNoTrailingWhitespace() {
        let note = text(transcript: "Body.\n\n")
        XCTAssertEqual(note, note.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A file transcript has no summary section — unlike a meeting, the job's
    /// optional LLM pass enhances the transcript in place rather than producing a
    /// second artifact.
    func testNoSummarySectionIsEverRendered() {
        XCTAssertFalse(text(transcript: "Body.").contains("## Summary"))
    }

    // MARK: - Header

    func testHeaderIsAnH1SoThePreviewRendersItAsATitle() {
        XCTAssertTrue(text(transcript: "x").hasPrefix("# "))
    }

    func testHeaderCarriesFileNameAndDate() {
        let head = FileTranscriptScratchpadExport.header(
            fileName: "talk.mp4", date: t0, duration: 0, formatter: fixedFormatter)
        XCTAssertEqual(head, "# talk.mp4 — 1970-01-12 13:46")
    }

    /// `durationSeconds` is 0 until the decode determines it — a queued-then-done
    /// job with no duration must not print a bare "0s".
    func testZeroDurationDropsTheSuffix() {
        let head = FileTranscriptScratchpadExport.header(
            fileName: "a.wav", date: t0, duration: 0, formatter: fixedFormatter)
        XCTAssertFalse(head.contains("·"))
    }

    func testNegativeDurationDropsTheSuffix() {
        let head = FileTranscriptScratchpadExport.header(
            fileName: "a.wav", date: t0, duration: -5, formatter: fixedFormatter)
        XCTAssertFalse(head.contains("·"))
    }

    func testPositiveDurationRendersTheSuffix() {
        let head = FileTranscriptScratchpadExport.header(
            fileName: "a.wav", date: t0, duration: 45, formatter: fixedFormatter)
        XCTAssertTrue(head.hasSuffix("· 45s"), head)
    }

    /// Duration rendering is delegated to the meeting export, so the two surfaces
    /// can never drift apart on what "12m 30s" means.
    func testDurationLabelMatchesTheMeetingSurface() {
        for seconds in [0.0, 0.4, 1, 45, 750, 3661] as [TimeInterval] {
            let head = FileTranscriptScratchpadExport.header(
                fileName: "a.wav", date: t0, duration: seconds, formatter: fixedFormatter)
            if let expected = MeetingScratchpadExport.durationLabel(seconds) {
                XCTAssertTrue(head.hasSuffix("· " + expected), "\(seconds): \(head)")
            } else {
                XCTAssertFalse(head.contains("·"), "\(seconds): \(head)")
            }
        }
    }

    // MARK: - File-name edge cases

    func testBlankFileNameFallsBackToAGenericLabel() {
        let head = FileTranscriptScratchpadExport.header(
            fileName: "   \n ", date: t0, duration: 0, formatter: fixedFormatter)
        XCTAssertEqual(head, "# \(FileTranscriptScratchpadExport.untitledFileName) — 1970-01-12 13:46")
        // The failure mode this guards: "# — <date>", a dangling em dash.
        XCTAssertFalse(head.hasPrefix("# —"))
    }

    func testEmptyFileNameFallsBackToAGenericLabel() {
        let head = FileTranscriptScratchpadExport.header(
            fileName: "", date: t0, duration: 0, formatter: fixedFormatter)
        XCTAssertTrue(head.hasPrefix("# \(FileTranscriptScratchpadExport.untitledFileName) — "))
    }

    func testFileNameIsTrimmedButOtherwiseVerbatim() {
        let head = FileTranscriptScratchpadExport.header(
            fileName: "  My Talk — final (v2).mp4  ", date: t0, duration: 0, formatter: fixedFormatter)
        XCTAssertTrue(head.hasPrefix("# My Talk — final (v2).mp4 — "), head)
    }

    /// Unicode / emoji names survive: the header is a note title, not a file path.
    func testUnicodeFileNameIsPreserved() {
        let head = FileTranscriptScratchpadExport.header(
            fileName: "Встреча 🎙.m4a", date: t0, duration: 0, formatter: fixedFormatter)
        XCTAssertTrue(head.contains("Встреча 🎙.m4a"), head)
    }

    // MARK: - Empty / whitespace transcripts

    func testEmptyTranscriptStillRendersTheHeadingWithAPlaceholder() {
        let note = text(transcript: "")
        XCTAssertTrue(note.contains("## Transcript"))
        XCTAssertTrue(note.hasSuffix(FileTranscriptScratchpadExport.noTranscriptPlaceholder), note)
    }

    func testWhitespaceOnlyTranscriptIsTreatedAsEmpty() {
        XCTAssertTrue(text(transcript: "  \n\t\n  ")
            .hasSuffix(FileTranscriptScratchpadExport.noTranscriptPlaceholder))
    }

    func testTranscriptIsEdgeTrimmedButInteriorFormattingSurvives() {
        let note = text(transcript: "\n\n  Line one.\n\n    Indented.\n\n")
        XCTAssertTrue(note.hasSuffix("Line one.\n\n    Indented."), note)
    }

    /// The placeholder wording is shared with the meeting surface on purpose.
    func testPlaceholderMatchesTheMeetingSurface() {
        XCTAssertEqual(
            FileTranscriptScratchpadExport.noTranscriptPlaceholder,
            MeetingScratchpadExport.noTranscriptPlaceholder)
    }

    // MARK: - insertFileTranscriptNote

    func testInsertCreatesANewNoteCarryingTheRenderedBody() {
        var notes = ScratchpadNotes()
        let id = notes.insertFileTranscriptNote(
            fileName: "interview.m4a", date: t0, duration: 750,
            transcript: "We shipped it.", now: t0, formatter: fixedFormatter)
        XCTAssertEqual(notes.note(id)?.text, text(
            fileName: "interview.m4a", duration: 750, transcript: "We shipped it."))
    }

    func testInsertedNoteSortsToTheFront() {
        var notes = ScratchpadNotes()
        notes.createNote(now: t0.addingTimeInterval(-100))
        let id = notes.insertFileTranscriptNote(
            fileName: "a.wav", date: t0, duration: 0, transcript: "Body.", now: t0)
        XCTAssertEqual(notes.notes.first?.id, id)
    }

    /// The body is machine-generated, so the note must not claim the user typed it —
    /// the same provenance contract `insertMeetingNote` holds.
    func testInsertedNoteHasNoTypedOrDictatedProvenance() {
        var notes = ScratchpadNotes()
        let id = notes.insertFileTranscriptNote(
            fileName: "a.wav", date: t0, duration: 0, transcript: "Body.", now: t0)
        let note = notes.note(id)
        XCTAssertNil(note?.lastTypedAt)
        XCTAssertNil(note?.lastDictatedAt)
        XCTAssertEqual(note?.origin, .empty)
    }

    /// A fresh note every time — re-exporting a transcript the user already
    /// annotated must never clobber their edits.
    func testInsertingTwiceCreatesTwoIndependentNotes() {
        var notes = ScratchpadNotes()
        let first = notes.insertFileTranscriptNote(
            fileName: "a.wav", date: t0, duration: 0, transcript: "Body.", now: t0)
        notes.setText("My edits.", for: first, now: t0.addingTimeInterval(1))
        let second = notes.insertFileTranscriptNote(
            fileName: "a.wav", date: t0, duration: 0, transcript: "Body.",
            now: t0.addingTimeInterval(2))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(notes.notes.count, 2)
        XCTAssertEqual(notes.note(first)?.text, "My edits.")
    }

    /// The list row must read as the file, not "New note".
    func testInsertedNoteTitleReadsAsTheFile() {
        var notes = ScratchpadNotes()
        let id = notes.insertFileTranscriptNote(
            fileName: "interview.m4a", date: t0, duration: 0, transcript: "",
            now: t0, formatter: fixedFormatter)
        XCTAssertTrue(notes.note(id)?.displayTitle.contains("interview.m4a") == true,
                      notes.note(id)?.displayTitle ?? "")
        XCTAssertNotEqual(notes.note(id)?.displayTitle, "New note")
    }

    /// An empty-transcript job still yields a titled, self-explaining note rather
    /// than something that looks like the transcript was lost.
    func testInsertWithEmptyTranscriptStillCarriesHeaderAndPlaceholder() {
        var notes = ScratchpadNotes()
        let id = notes.insertFileTranscriptNote(
            fileName: "silent.wav", date: t0, duration: 3, transcript: "   ", now: t0)
        let body = notes.note(id)?.text ?? ""
        XCTAssertTrue(body.contains("silent.wav"))
        XCTAssertTrue(body.contains(FileTranscriptScratchpadExport.noTranscriptPlaceholder))
    }

    // MARK: - Persistence policy

    /// Inserting a note is structural — it must hit disk immediately and cancel any
    /// pending debounced write, exactly like the meeting insert.
    func testFileTranscriptInsertPersistsImmediately() {
        XCTAssertTrue(ScratchpadPersistencePolicy.requiresImmediateWrite(.fileTranscriptInsert))
        XCTAssertTrue(ScratchpadPersistencePolicy.cancelsPendingWrite(.fileTranscriptInsert))
    }
}
