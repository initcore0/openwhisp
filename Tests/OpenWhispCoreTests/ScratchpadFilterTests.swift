import XCTest
@testable import OpenWhispCore

/// Tests for Scratchpad list filtering (MAK-97): free-text search over the full
/// note body, the tag filter, and the AND of the two — including the non-Latin
/// cases a naive `lowercased().contains` would get wrong.
final class ScratchpadFilterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func note(_ text: String, at offset: TimeInterval = 0) -> ScratchpadNote {
        ScratchpadNote(text: text, createdAt: t0.addingTimeInterval(offset))
    }

    // MARK: - Query matching

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(ScratchpadFilter.matches(note: note("anything"), query: ""))
        XCTAssertTrue(ScratchpadFilter.matches(note: note("anything"), query: "   "),
                      "a whitespace-only query is not a filter")
    }

    func testSubstringMatch() {
        XCTAssertTrue(ScratchpadFilter.matches(note: note("the quick brown fox"), query: "brown"))
        XCTAssertFalse(ScratchpadFilter.matches(note: note("the quick brown fox"), query: "purple"))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(ScratchpadFilter.matches(note: note("Hello World"), query: "hello"))
        XCTAssertTrue(ScratchpadFilter.matches(note: note("hello world"), query: "WORLD"))
    }

    func testMatchSearchesTheBodyNotJustTheTitle() {
        let n = note("Title line\n\nthe needle is down here")
        XCTAssertTrue(ScratchpadFilter.matches(note: n, query: "needle"))
    }

    func testQueryIsTrimmed() {
        XCTAssertTrue(ScratchpadFilter.matches(note: note("brown fox"), query: "  brown  "))
    }

    // MARK: - Cyrillic / non-Latin

    func testCyrillicMatch() {
        XCTAssertTrue(ScratchpadFilter.matches(note: note("это моя заметка"), query: "заметка"))
        XCTAssertFalse(ScratchpadFilter.matches(note: note("это моя заметка"), query: "письмо"))
    }

    func testCyrillicMatchIsCaseInsensitive() {
        XCTAssertTrue(ScratchpadFilter.matches(note: note("Заметка о работе"), query: "заметка"))
        XCTAssertTrue(ScratchpadFilter.matches(note: note("заметка о работе"), query: "ЗАМЕТКА"))
    }

    func testCJKMatch() {
        XCTAssertTrue(ScratchpadFilter.matches(note: note("これはメモです"), query: "メモ"))
    }

    // MARK: - filtered: ordering + no-match

    func testFilteredPreservesInputOrder() {
        let notes = [note("alpha match", at: 30), note("beta", at: 20), note("gamma match", at: 10)]
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, query: "match").map(\.text),
                       ["alpha match", "gamma match"])
    }

    func testEmptyQueryReturnsEverythingUnchanged() {
        let notes = [note("a"), note("b"), note("c")]
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, query: "").map(\.text), ["a", "b", "c"])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(ScratchpadFilter.filtered(notes: [note("a"), note("b")], query: "zzz").isEmpty)
    }

    func testFilteringAnEmptyListIsEmpty() {
        XCTAssertTrue(ScratchpadFilter.filtered(notes: [], query: "anything").isEmpty)
    }

    // MARK: - Tag filter

    func testTagFilterNarrowsToTaggedNotes() {
        let notes = [note("has #work here"), note("untagged"), note("also #work")]
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, tag: "work").count, 2)
    }

    func testTagFilterIsCaseInsensitive() {
        let notes = [note("has #Work here")]
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, tag: "work").count, 1)
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, tag: "WORK").count, 1)
    }

    func testNilTagIsNotAFilter() {
        let notes = [note("a"), note("b")]
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, tag: nil).count, 2)
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, tag: "").count, 2)
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, tag: "   ").count, 2)
    }

    func testCyrillicTagFilter() {
        let notes = [note("это #идея"), note("без тегов")]
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, tag: "идея").count, 1)
    }

    // MARK: - Query AND tag

    func testQueryAndTagAreANDed() {
        let notes = [
            note("shipping the #work item"),
            note("#work on something else"),
            note("shipping without a tag"),
        ]
        let result = ScratchpadFilter.filtered(notes: notes, query: "shipping", tag: "work")
        XCTAssertEqual(result.map(\.text), ["shipping the #work item"],
                       "a note must satisfy BOTH filters")
    }

    func testTagWithNonMatchingQueryYieldsNothing() {
        let notes = [note("has #work here")]
        XCTAssertTrue(ScratchpadFilter.filtered(notes: notes, query: "zzz", tag: "work").isEmpty)
    }

    func testTagTextIsItselfSearchable() {
        // The '#work' literal is in the body, so searching for it works too.
        let notes = [note("has #work here")]
        XCTAssertEqual(ScratchpadFilter.filtered(notes: notes, query: "#work").count, 1)
    }
}
