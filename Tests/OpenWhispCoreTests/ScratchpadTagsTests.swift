import XCTest
@testable import OpenWhispCore

/// Tests for derived inline `#tag` extraction (MAK-97).
///
/// Tags are computed from the note body, never stored — `scratchpad.json`'s format
/// is a versioned contract shared with the iOS companion. The negatives matter as
/// much as the positives: `#1`, `issue#5` and URL fragments must NOT become tags.
final class ScratchpadTagsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func note(_ text: String) -> ScratchpadNote {
        ScratchpadNote(text: text, createdAt: t0)
    }

    // MARK: - Positives

    func testSimpleTag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "an idea #work here"), ["work"])
    }

    func testTagAtStartOfText() {
        XCTAssertEqual(ScratchpadTags.tags(in: "#work starts the note"), ["work"])
    }

    func testTagAtEndOfText() {
        XCTAssertEqual(ScratchpadTags.tags(in: "ends with #work"), ["work"])
    }

    func testHyphenatedTag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "#work-log entry"), ["work-log"])
    }

    func testUnderscoredTag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "#work_log entry"), ["work_log"])
    }

    func testTagWithTrailingDigits() {
        XCTAssertEqual(ScratchpadTags.tags(in: "#q4 planning"), ["q4"])
    }

    func testCyrillicTag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "это #идея для проекта"), ["идея"])
    }

    func testCJKTag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "note #日本語 here"), ["日本語"])
    }

    func testTagAfterPunctuationIsFound() {
        XCTAssertEqual(ScratchpadTags.tags(in: "(#idea)"), ["idea"])
        XCTAssertEqual(ScratchpadTags.tags(in: "done. #idea"), ["idea"])
    }

    func testTagTerminatedByPunctuation() {
        XCTAssertEqual(ScratchpadTags.tags(in: "#work."), ["work"])
        XCTAssertEqual(ScratchpadTags.tags(in: "#work, #idea"), ["work", "idea"])
    }

    func testTagAfterNewline() {
        XCTAssertEqual(ScratchpadTags.tags(in: "line one\n#work"), ["work"])
    }

    // MARK: - Negatives (the rules that matter)

    func testDigitsOnlyIsNotATag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "see #1 and #42"), [],
                       "issue/number references are not tags")
    }

    func testMidWordHashIsNotATag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "issue#5"), [])
        XCTAssertEqual(ScratchpadTags.tags(in: "issue#five"), [],
                       "the char before # must not be alphanumeric")
    }

    func testURLFragmentIsNotATag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "https://example.com/#fragment"), [],
                       "a '/' before # means a URL fragment")
    }

    func testBareHashIsNotATag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "a # b"), [])
        XCTAssertEqual(ScratchpadTags.tags(in: "#"), [])
    }

    func testMarkdownHeadingIsNotATag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "# Heading"), [],
                       "a heading has a space after #, so there is no tag")
        XCTAssertEqual(ScratchpadTags.tags(in: "## Summary"), [])
    }

    func testDoubleHashIsNotATag() {
        XCTAssertEqual(ScratchpadTags.tags(in: "##idea"), [],
                       "a '#' before '#' is a heading marker, not a tag start")
    }

    func testEmptyTextHasNoTags() {
        XCTAssertEqual(ScratchpadTags.tags(in: ""), [])
    }

    // MARK: - Ordering + de-duplication

    func testTagsAreOrderedByFirstAppearance() {
        XCTAssertEqual(ScratchpadTags.tags(in: "#zebra then #apple"), ["zebra", "apple"])
    }

    func testDuplicateTagsCollapse() {
        XCTAssertEqual(ScratchpadTags.tags(in: "#work and more #work"), ["work"])
    }

    func testTagsAreLowercased() {
        XCTAssertEqual(ScratchpadTags.tags(in: "#Work and #WORK"), ["work"],
                       "case variants are one tag")
    }

    func testCyrillicTagsLowercase() {
        XCTAssertEqual(ScratchpadTags.tags(in: "#Идея"), ["идея"])
    }

    // MARK: - Across notes

    func testAllTagsIsSortedUnion() {
        let notes = [note("#zebra"), note("#apple #zebra"), note("no tags")]
        XCTAssertEqual(ScratchpadTags.allTags(in: notes), ["apple", "zebra"])
    }

    func testAllTagsOfEmptySetIsEmpty() {
        XCTAssertEqual(ScratchpadTags.allTags(in: []), [])
    }

    func testTagCountsCountNotesNotOccurrences() {
        let notes = [note("#work #work"), note("#work"), note("#idea")]
        let counts = Dictionary(uniqueKeysWithValues: ScratchpadTags.tagCounts(in: notes).map { ($0.tag, $0.count) })
        XCTAssertEqual(counts["work"], 2, "a tag twice in one note counts that note once")
        XCTAssertEqual(counts["idea"], 1)
    }

    func testTagCountsOrderedByCountThenAlphabetically() {
        let notes = [note("#b"), note("#b"), note("#a"), note("#c")]
        XCTAssertEqual(ScratchpadTags.tagCounts(in: notes).map(\.tag), ["b", "a", "c"])
    }

    // MARK: - hasTag

    func testHasTagIsCaseInsensitive() {
        XCTAssertTrue(ScratchpadTags.note(note("#Work"), hasTag: "work"))
        XCTAssertTrue(ScratchpadTags.note(note("#work"), hasTag: "WORK"))
        XCTAssertFalse(ScratchpadTags.note(note("#work"), hasTag: "idea"))
    }

    func testHasTagRequiresAWholeTagNotAPrefix() {
        XCTAssertFalse(ScratchpadTags.note(note("#workshop"), hasTag: "work"),
                       "a prefix must not match a different tag")
    }

    // MARK: - Realistic + pathological

    func testRealisticNoteWithMixedContent() {
        let text = """
        # Meeting notes

        Discussed the #roadmap and issue#42 (not a tag).
        Docs at https://example.com/#anchor — also not a tag.

        - ship #q4 by Friday
        - follow up on #идея
        """
        XCTAssertEqual(ScratchpadTags.tags(in: text), ["roadmap", "q4", "идея"])
    }

    func testPathologicalInputsDoNotHang() {
        let inputs = [
            String(repeating: "#", count: 5000),
            String(repeating: "#a", count: 2000),
            String(repeating: "#1 ", count: 2000),
            String(repeating: "a#b", count: 2000),
        ]
        for input in inputs { _ = ScratchpadTags.tags(in: input) }
    }
}
