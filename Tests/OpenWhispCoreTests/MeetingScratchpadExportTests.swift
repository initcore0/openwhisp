import XCTest
@testable import OpenWhispCore

/// Tests for "Open in Scratchpad" (MAK-50): the pure `MeetingScratchpadExport`
/// note renderer and the `ScratchpadNotes.insertMeetingNote` mutation behind the
/// Meetings pane action.
final class MeetingScratchpadExportTests: XCTestCase {

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

    private func meeting(
        duration: TimeInterval = 0,
        transcript: String? = nil,
        attributed: String? = nil,
        summary: String? = nil,
        status: MeetingStatus = .done
    ) -> Meeting {
        Meeting(
            startedAt: t0,
            duration: duration,
            transcript: transcript,
            attributedTranscript: attributed,
            summary: summary,
            status: status
        )
    }

    private func text(_ m: Meeting) -> String {
        MeetingScratchpadExport.noteText(for: m, formatter: fixedFormatter)
    }

    // MARK: - Full layout

    func testFullNoteLayoutHeaderSummaryThenTranscript() {
        let note = text(meeting(duration: 750, transcript: "We shipped it.", summary: "## Decisions\nShip on Friday."))
        XCTAssertEqual(note, """
        Meeting — 1970-01-12 13:46 · 12m 30s

        ## Summary

        ## Decisions
        Ship on Friday.

        ## Transcript

        We shipped it.
        """)
    }

    func testNoteHasNoTrailingWhitespace() {
        let note = text(meeting(duration: 30, transcript: "  padded  \n\n", summary: "\n  a summary \n"))
        XCTAssertEqual(note, note.trimmingCharacters(in: .whitespacesAndNewlines),
                       "the rendered note must not carry leading/trailing blank lines")
        XCTAssertTrue(note.hasSuffix("padded"))
    }

    // MARK: - Summary presence

    func testNilSummaryDropsTheSummarySection() {
        let note = text(meeting(duration: 5, transcript: "just talk", summary: nil))
        XCTAssertFalse(note.contains("## Summary"))
        XCTAssertTrue(note.contains("## Transcript"))
    }

    func testWhitespaceOnlySummaryDropsTheSummarySection() {
        let note = text(meeting(duration: 5, transcript: "just talk", summary: "   \n\t\n "))
        XCTAssertFalse(note.contains("## Summary"), "a blank summary must not leave an empty heading")
    }

    func testEmptySummaryDropsTheSummarySection() {
        XCTAssertFalse(text(meeting(transcript: "x", summary: "")).contains("## Summary"))
    }

    // MARK: - Transcript presence / preference

    func testMissingTranscriptStillRendersHeadingWithPlaceholder() {
        let note = text(meeting(duration: 5, transcript: nil, status: .recorded))
        XCTAssertTrue(note.contains("## Transcript"))
        XCTAssertTrue(note.contains(MeetingScratchpadExport.noTranscriptPlaceholder))
    }

    func testWhitespaceOnlyTranscriptFallsBackToPlaceholder() {
        let note = text(meeting(transcript: "   \n  "))
        XCTAssertTrue(note.hasSuffix(MeetingScratchpadExport.noTranscriptPlaceholder))
    }

    func testAttributedTranscriptWinsOverPlain() {
        let note = text(meeting(transcript: "plain version", attributed: "Me: hi\nThem: hello"))
        XCTAssertTrue(note.contains("Me: hi\nThem: hello"))
        XCTAssertFalse(note.contains("plain version"))
    }

    func testEmptyAttributedTranscriptFallsBackToPlain() {
        let note = text(meeting(transcript: "plain version", attributed: ""))
        XCTAssertTrue(note.contains("plain version"))
    }

    func testWholeMeetingEmptyStillProducesAUsableNote() {
        let note = text(meeting(duration: 0, transcript: nil, summary: nil, status: .recorded))
        XCTAssertEqual(note, """
        Meeting — 1970-01-12 13:46

        ## Transcript

        (no transcript)
        """)
    }

    // MARK: - Header + duration label

    func testHeaderIsTheFirstLineAndBecomesTheNoteTitle() {
        var notes = ScratchpadNotes()
        let id = notes.insertMeetingNote(meeting(duration: 61, transcript: "hi"), now: t0, formatter: fixedFormatter)
        let note = try! XCTUnwrap(notes.note(id))
        XCTAssertEqual(note.displayTitle, "Meeting — 1970-01-12 13:46 · 1m 1s")
    }

    func testZeroDurationOmitsTheDurationSuffix() {
        XCTAssertNil(MeetingScratchpadExport.durationLabel(0))
        XCTAssertNil(MeetingScratchpadExport.durationLabel(-5))
        XCTAssertNil(MeetingScratchpadExport.durationLabel(0.2), "sub-second rounds to 0s — omit rather than print \"0s\"")
        XCTAssertFalse(text(meeting(duration: 0, transcript: "x")).contains("·"))
    }

    func testDurationLabelFormats() {
        XCTAssertEqual(MeetingScratchpadExport.durationLabel(45), "45s")
        XCTAssertEqual(MeetingScratchpadExport.durationLabel(750), "12m 30s")
        XCTAssertEqual(MeetingScratchpadExport.durationLabel(3900), "1h 05m")
    }

    // MARK: - insertMeetingNote

    func testInsertMeetingNoteCarriesTheMeetingsActualFields() {
        var notes = ScratchpadNotes()
        let m = meeting(duration: 100, transcript: "the real transcript body", summary: "the real summary body")
        let id = notes.insertMeetingNote(m, now: t0, formatter: fixedFormatter)
        let body = try! XCTUnwrap(notes.note(id)?.text)
        XCTAssertTrue(body.contains("the real transcript body"), "the note must carry the meeting's transcript")
        XCTAssertTrue(body.contains("the real summary body"), "the note must carry the meeting's summary")
    }

    func testInsertedNoteSortsToTheFront() {
        var notes = ScratchpadNotes()
        _ = notes.createNote(now: t0)
        _ = notes.createNote(now: t0.addingTimeInterval(10))
        let id = notes.insertMeetingNote(meeting(transcript: "x"), now: t0.addingTimeInterval(20), formatter: fixedFormatter)
        XCTAssertEqual(notes.notes.first?.id, id)
        XCTAssertEqual(notes.notes.count, 3)
    }

    func testInsertedNoteIsNotMarkedTypedOrDictated() {
        var notes = ScratchpadNotes()
        let id = notes.insertMeetingNote(meeting(transcript: "x"), now: t0, formatter: fixedFormatter)
        let note = try! XCTUnwrap(notes.note(id))
        XCTAssertNil(note.lastTypedAt, "a machine-generated body must not claim it was typed")
        XCTAssertNil(note.lastDictatedAt)
        XCTAssertEqual(note.origin, .empty)
        XCTAssertEqual(note.updatedAt, t0)
    }

    func testEachExportCreatesAFreshNoteAndNeverClobbersEdits() {
        var notes = ScratchpadNotes()
        let m = meeting(transcript: "original")
        let first = notes.insertMeetingNote(m, now: t0, formatter: fixedFormatter)
        notes.setText("my hand-written edits", for: first, now: t0.addingTimeInterval(5))

        let second = notes.insertMeetingNote(m, now: t0.addingTimeInterval(10), formatter: fixedFormatter)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(notes.note(first)?.text, "my hand-written edits", "re-export must not overwrite the user's edits")
        XCTAssertEqual(notes.notes.count, 2)
    }

    func testInsertedNoteSurvivesThePersistenceRoundTrip() throws {
        var notes = ScratchpadNotes()
        let id = notes.insertMeetingNote(
            meeting(duration: 90, transcript: "round trip me", summary: "sum"),
            now: t0, formatter: fixedFormatter
        )
        let data = try JSONEncoder().encode(notes)
        let decoded = try JSONDecoder().decode(ScratchpadNotes.self, from: data)
        XCTAssertEqual(decoded.note(id)?.text, notes.note(id)?.text)
    }

    // MARK: - Reachability of the pane action

    /// The pane offers "Open in Scratchpad" exactly when the meeting has transcript
    /// text (the same condition that gates Export .md). Pinning it here keeps the
    /// wiring honest: a status change must not silently make the action dead.
    func testActionIsOfferedForEveryMeetingThatHasATranscript() {
        for status: MeetingStatus in [.transcribed, .done, .recorded, .failed(reason: "x")] {
            let m = meeting(transcript: "some text", status: status)
            XCTAssertNotNil(m.transcript, "status \(status.label) with a transcript must be exportable")
            XCTAssertTrue(text(m).contains("some text"))
        }
    }
}
