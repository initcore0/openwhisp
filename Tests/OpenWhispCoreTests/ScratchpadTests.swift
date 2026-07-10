import XCTest
@testable import OpenWhispCore

/// Tests for the pure Scratchpad note model (MAK-49): list ordering,
/// provenance tagging, the dictation-append join rule, and the persistence
/// round-trip (including forward-compatible decoding of pre-provenance files).
final class ScratchpadTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    // MARK: - Ordering: most-recently-updated first

    func testNewNoteSortsToFront() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        let b = notes.createNote(now: at(10))
        XCTAssertEqual(notes.notes.map(\.id), [b, a])
    }

    func testEditReordersToFront() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        let b = notes.createNote(now: at(10))
        notes.setText("edited", for: a, now: at(20))
        XCTAssertEqual(notes.notes.first?.id, a)
        XCTAssertEqual(notes.notes.map(\.id), [a, b])
    }

    func testAppendDictationReordersToFront() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        let b = notes.createNote(now: at(10))
        notes.appendDictation("hello", to: a, now: at(30))
        XCTAssertEqual(notes.notes.first?.id, a)
    }

    // MARK: - Provenance tagging

    func testTypedOnlyOrigin() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        notes.setText("typed", for: a, now: at(1))
        XCTAssertEqual(notes.note(a)?.origin, .typed)
        XCTAssertNotNil(notes.note(a)?.lastTypedAt)
        XCTAssertNil(notes.note(a)?.lastDictatedAt)
    }

    func testDictatedOnlyOrigin() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        notes.appendDictation("spoken", to: a, now: at(1))
        XCTAssertEqual(notes.note(a)?.origin, .dictated)
        XCTAssertNotNil(notes.note(a)?.lastDictatedAt)
    }

    func testMixedOrigin() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        notes.appendDictation("spoken", to: a, now: at(1))
        notes.setText("spoken edited", for: a, now: at(2))
        XCTAssertEqual(notes.note(a)?.origin, .mixed)
    }

    func testEmptyOrigin() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        XCTAssertEqual(notes.note(a)?.origin, .empty)
    }

    // MARK: - Dictation append join rule

    func testAppendIntoEmptyHasNoLeadingSpace() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        let result = notes.appendDictation("first sentence.", to: a, now: at(1))
        XCTAssertEqual(result, "first sentence.")
    }

    func testAppendAddsSingleSeparatingSpace() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        notes.appendDictation("one.", to: a, now: at(1))
        let result = notes.appendDictation("two.", to: a, now: at(2))
        XCTAssertEqual(result, "one. two.")
    }

    func testAppendAfterTrailingWhitespaceDoesNotDoubleSpace() {
        XCTAssertEqual(ScratchpadNotes.joined(existing: "one.\n", appended: "two."), "one.\ntwo.")
        XCTAssertEqual(ScratchpadNotes.joined(existing: "one. ", appended: "two."), "one. two.")
    }

    func testAppendTrimsTheDictatedPiece() {
        XCTAssertEqual(ScratchpadNotes.joined(existing: "one.", appended: "  two.  "), "one. two.")
    }

    func testAppendUnknownIdReturnsNil() {
        var notes = ScratchpadNotes()
        XCTAssertNil(notes.appendDictation("x", to: UUID(), now: at(1)))
    }

    // MARK: - setText no-ops

    func testSetTextUnchangedDoesNotBumpOrdering() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        let b = notes.createNote(now: at(10))
        notes.setText("", for: a, now: at(20)) // unchanged (already empty) → no-op
        XCTAssertEqual(notes.notes.first?.id, b, "an unchanged setText must not reorder")
    }

    // MARK: - Delete

    func testDelete() {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        _ = notes.createNote(now: at(10))
        notes.delete(a)
        XCTAssertNil(notes.note(a))
        XCTAssertEqual(notes.notes.count, 1)
    }

    // MARK: - displayTitle

    func testDisplayTitleUsesFirstNonEmptyLine() {
        let note = ScratchpadNote(text: "\n  \nHello world\nsecond", createdAt: t0)
        XCTAssertEqual(note.displayTitle, "Hello world")
    }

    func testDisplayTitleForEmptyNote() {
        XCTAssertEqual(ScratchpadNote(text: "", createdAt: t0).displayTitle, "New note")
    }

    // MARK: - Persistence round-trip

    func testCodableRoundTrip() throws {
        var notes = ScratchpadNotes()
        let a = notes.createNote(now: at(0))
        notes.appendDictation("dictated bit", to: a, now: at(1))
        notes.setText("dictated bit typed", for: a, now: at(2))
        _ = notes.createNote(now: at(5))

        let data = try JSONEncoder().encode(notes)
        let decoded = try JSONDecoder().decode(ScratchpadNotes.self, from: data)
        XCTAssertEqual(decoded, notes)
        XCTAssertEqual(decoded.note(a)?.origin, .mixed)
    }

    func testDecodesLegacyNoteWithoutProvenanceFields() throws {
        // A note written before updatedAt/provenance existed: only id/text/createdAt.
        let json = """
        { "notes": [ { "id": "\(UUID().uuidString)", "text": "old", "createdAt": 1000000 } ] }
        """
        let decoded = try JSONDecoder().decode(ScratchpadNotes.self, from: Data(json.utf8))
        let note = try XCTUnwrap(decoded.notes.first)
        XCTAssertEqual(note.text, "old")
        XCTAssertEqual(note.updatedAt, note.createdAt, "missing updatedAt defaults to createdAt")
        XCTAssertEqual(note.origin, .empty)
    }
}
