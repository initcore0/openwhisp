import XCTest
@testable import OpenWhispCore

/// Tests for the Scratchpad's presentation-layer text derivations (MAK-95):
/// Markdown stripping for list rows, the list title/snippet, and the provenance
/// line moved out of the AppKit controller.
///
/// The two invariants under test everywhere: stripping removes only *markers*
/// (never words) and never reorders content.
final class ScratchpadTextTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Heading markers

    func testStripsATXHeadings() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "# Title"), "Title")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "## Summary"), "Summary")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "###### Deep"), "Deep")
    }

    func testStripsClosingHashes() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "## Title ##"), "Title")
    }

    func testSevenHashesIsNotAHeading() {
        // Markdown caps headings at 6 levels; the 7th hash is content.
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "####### Seven"), "####### Seven")
    }

    func testHashWithoutSpaceIsNotAHeading() {
        // This is the P3 tag form — it must survive stripping intact.
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "#idea and more"), "#idea and more")
    }

    // MARK: - List / quote / rule markers

    func testStripsUnorderedListMarkers() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "- item"), "item")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "* item"), "item")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "+ item"), "item")
    }

    func testStripsOrderedListMarkers() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "1. first"), "first")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "42) forty-two"), "forty-two")
    }

    func testOrderedMarkerNeedsTrailingSpace() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "1.5 metres"), "1.5 metres")
    }

    func testStripsBlockquote() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "> quoted line"), "quoted line")
    }

    func testNestedQuoteAndBullet() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "> - nested item"), "nested item")
    }

    func testHorizontalRulesRenderEmpty() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "---"), "")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "***"), "")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "___"), "")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "- - -"), "")
    }

    func testTwoDashesIsNotARule() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "--"), "--")
    }

    func testFenceLinesRenderEmpty() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "```swift"), "")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "~~~"), "")
    }

    // MARK: - Inline markers

    func testStripsBoldAndItalic() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "a **bold** word"), "a bold word")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "an *italic* word"), "an italic word")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "an _italic_ word"), "an italic word")
    }

    func testStripsCodeSpans() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "run `swift test` now"), "run swift test now")
    }

    func testUnbalancedMarkerSurvives() {
        // A lone asterisk in prose is content, not a marker.
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "2 * 3 = 6"), "2 * 3 = 6")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "a `dangling span"), "a `dangling span")
    }

    func testStripsLinksKeepingLabel() {
        XCTAssertEqual(
            ScratchpadText.strippingMarkdown(line: "see [the docs](https://example.com) now"),
            "see the docs now"
        )
    }

    func testBareBracketsSurvive() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "[TODO] ship it"), "[TODO] ship it")
    }

    // MARK: - Content preservation

    func testStrippingNeverLosesWords() {
        let doc = "# Heading\n\nSome **bold** and `code`.\n\n- one\n- two\n\n> quoted\n"
        let stripped = ScratchpadText.strippingMarkdown(doc)
        for word in ["Heading", "Some", "bold", "and", "code", "one", "two", "quoted"] {
            XCTAssertTrue(stripped.contains(word), "stripping dropped '\(word)'")
        }
    }

    func testStrippingPreservesLineOrder() {
        let stripped = ScratchpadText.strippingMarkdown("# A\n## B\n- C")
        XCTAssertEqual(stripped, "A\nB\nC")
    }

    func testStrippingPreservesLineCount() {
        // Line-for-line mapping: marker-only lines become empty, they don't vanish.
        let doc = "# A\n\n---\n\nB"
        XCTAssertEqual(ScratchpadText.strippingMarkdown(doc).components(separatedBy: "\n").count,
                       doc.components(separatedBy: "\n").count)
    }

    func testCyrillicSurvivesStripping() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "## Заголовок"), "Заголовок")
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "**жирный** текст"), "жирный текст")
    }

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "just a normal sentence."),
                       "just a normal sentence.")
    }

    // MARK: - listTitle

    func testListTitleStripsMarkdown() {
        XCTAssertEqual(ScratchpadText.listTitle(for: "# Meeting — Jul 28\n\nbody"), "Meeting — Jul 28")
    }

    func testListTitleSkipsMarkerOnlyLines() {
        XCTAssertEqual(ScratchpadText.listTitle(for: "---\n\n# Real title"), "Real title")
    }

    func testListTitleForEmptyNote() {
        XCTAssertEqual(ScratchpadText.listTitle(for: ""), "New note")
        XCTAssertEqual(ScratchpadText.listTitle(for: "\n   \n"), "New note")
    }

    func testListTitleCapsLength() {
        let long = String(repeating: "a", count: 200)
        let title = ScratchpadText.listTitle(for: long)
        XCTAssertEqual(title.count, 61, "60 chars + ellipsis")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testListTitleOfMarkerOnlyDocument() {
        XCTAssertEqual(ScratchpadText.listTitle(for: "---\n***\n```"), "New note")
    }

    // MARK: - snippet

    func testSnippetSkipsTitleAndTakesTwoLines() {
        let text = "# Title\n\nfirst body line\nsecond body line\nthird body line"
        XCTAssertEqual(ScratchpadText.snippet(for: text), "first body line\nsecond body line")
    }

    func testSnippetIsEmptyForTitleOnlyNote() {
        XCTAssertEqual(ScratchpadText.snippet(for: "# Only a title"), "")
        XCTAssertEqual(ScratchpadText.snippet(for: ""), "")
    }

    func testSnippetStripsMarkers() {
        XCTAssertEqual(ScratchpadText.snippet(for: "Title\n- **one**\n- two"), "one\ntwo")
    }

    func testSnippetCapsEachLine() {
        let text = "Title\n" + String(repeating: "x", count: 300)
        let snippet = ScratchpadText.snippet(for: text)
        XCTAssertEqual(snippet.count, 101, "100 chars + ellipsis")
    }

    // MARK: - provenanceLine (moved from the AppKit controller)

    func testProvenanceForNilNote() {
        XCTAssertEqual(ScratchpadText.provenanceLine(nil), "")
    }

    func testProvenanceForUntouchedNote() {
        let note = ScratchpadNote(createdAt: t0)
        XCTAssertEqual(ScratchpadText.provenanceLine(note), "New note")
    }

    func testProvenanceDictatedOnlyIsCapitalized() {
        let note = ScratchpadNote(createdAt: t0, lastDictatedAt: t0)
        let line = ScratchpadText.provenanceLine(note)
        XCTAssertTrue(line.hasPrefix("Dictated "), "got: \(line)")
        XCTAssertFalse(line.contains("typed"))
    }

    func testProvenanceMixedJoinsBothParts() {
        let note = ScratchpadNote(createdAt: t0, lastDictatedAt: t0, lastTypedAt: t0.addingTimeInterval(60))
        let line = ScratchpadText.provenanceLine(note)
        XCTAssertTrue(line.hasPrefix("Dictated "))
        XCTAssertTrue(line.contains(" · typed "))
    }

    func testProvenanceTypedOnly() {
        let note = ScratchpadNote(createdAt: t0, lastTypedAt: t0)
        XCTAssertTrue(ScratchpadText.provenanceLine(note).hasPrefix("Typed "))
    }

    // MARK: - Origin glyphs

    func testOriginSymbolsAreSFSymbolsNotEmoji() {
        XCTAssertEqual(ScratchpadText.originSymbol(.dictated), "mic")
        XCTAssertEqual(ScratchpadText.originSymbol(.typed), "keyboard")
        XCTAssertEqual(ScratchpadText.originSymbol(.mixed), "mic.badge.plus")
        XCTAssertNil(ScratchpadText.originSymbol(.empty), "an untouched note shows no glyph")
        for origin in [ScratchpadNote.Origin.dictated, .typed, .mixed] {
            let symbol = ScratchpadText.originSymbol(origin) ?? ""
            XCTAssertTrue(symbol.allSatisfy { $0.isASCII }, "SF Symbol names are ASCII: \(symbol)")
        }
    }

    func testOriginLabelsAreHumanReadable() {
        XCTAssertEqual(ScratchpadText.originLabel(.dictated), "Dictated")
        XCTAssertEqual(ScratchpadText.originLabel(.mixed), "Dictated and typed")
    }

    // MARK: - Pathological inputs

    func testPathologicalInputsDoNotHang() {
        let inputs = [
            String(repeating: "#", count: 500),
            String(repeating: "*", count: 500),
            String(repeating: "[", count: 200),
            String(repeating: "[a](b)", count: 200),
            "```" + String(repeating: "x", count: 1000),
            String(repeating: "> ", count: 200) + "deep",
        ]
        for input in inputs {
            _ = ScratchpadText.strippingMarkdown(line: input)
            _ = ScratchpadText.listTitle(for: input)
            _ = ScratchpadText.snippet(for: input)
        }
    }

    func testDeeplyNestedQuotesPeelToContent() {
        XCTAssertEqual(ScratchpadText.strippingMarkdown(line: "> > > deep"), "deep")
    }
}
