import XCTest
@testable import OpenWhispCore

/// Tests for the dependency-free Markdown preview renderer (MAK-96).
///
/// The governing invariant, asserted repeatedly below: **never lose or reorder
/// content**. Unrecognized markup must degrade to plain text, never to a dropped
/// line. Every construct is covered individually, then in mixed documents, then
/// against Cyrillic and pathological inputs.
final class MarkdownPreviewRendererTests: XCTestCase {

    private func kinds(_ text: String) -> [MarkdownPreviewRenderer.Block.Kind] {
        MarkdownPreviewRenderer.render(text).map(\.kind)
    }

    private func plains(_ text: String) -> [String] {
        MarkdownPreviewRenderer.render(text).map(\.plain)
    }

    /// The rendered text of the whole document, markers gone.
    private func rendered(_ text: String) -> String {
        String(MarkdownPreviewRenderer.renderJoined(text).characters)
    }

    // MARK: - Headings

    func testHeadingLevels() {
        XCTAssertEqual(kinds("# One"), [.heading(level: 1)])
        XCTAssertEqual(kinds("## Two"), [.heading(level: 2)])
        XCTAssertEqual(kinds("### Three"), [.heading(level: 3)])
        XCTAssertEqual(kinds("###### Six"), [.heading(level: 6)])
    }

    func testHeadingTextDropsTheMarker() {
        XCTAssertEqual(plains("## Summary"), ["Summary"])
    }

    func testHeadingClosingHashesAreDropped() {
        XCTAssertEqual(plains("## Title ##"), ["Title"])
    }

    func testSevenHashesIsAParagraph() {
        XCTAssertEqual(kinds("####### Seven"), [.paragraph])
        XCTAssertEqual(plains("####### Seven"), ["####### Seven"], "content preserved verbatim")
    }

    func testHashWithoutSpaceIsAParagraphNotAHeading() {
        // The P3 tag form must survive the preview untouched.
        XCTAssertEqual(kinds("#idea"), [.paragraph])
        XCTAssertEqual(plains("#idea"), ["#idea"])
    }

    // MARK: - Lists

    func testUnorderedListNormalizesBullets() {
        XCTAssertEqual(kinds("- one\n* two\n+ three"),
                       [.listItem(depth: 0), .listItem(depth: 0), .listItem(depth: 0)])
        XCTAssertEqual(plains("- one\n* two\n+ three"), ["• one", "• two", "• three"])
    }

    func testOrderedListKeepsItsNumbers() {
        XCTAssertEqual(plains("1. first\n2. second"), ["1. first", "2. second"])
        XCTAssertEqual(kinds("1. first"), [.listItem(depth: 0)])
    }

    func testOrderedListAcceptsParenForm() {
        XCTAssertEqual(plains("1) first"), ["1. first"])
    }

    func testIndentedListGetsDepth() {
        XCTAssertEqual(kinds("- top\n  - nested"), [.listItem(depth: 0), .listItem(depth: 1)])
    }

    func testTabIndentCountsAsDepth() {
        XCTAssertEqual(kinds("- top\n\t- nested"), [.listItem(depth: 0), .listItem(depth: 2)])
    }

    func testBulletWithoutSpaceIsNotAList() {
        // "*emphasis*" must not be mistaken for a bullet.
        XCTAssertEqual(kinds("*emphasis*"), [.paragraph])
    }

    func testNumberWithoutSpaceIsNotAList() {
        XCTAssertEqual(kinds("1.5 metres"), [.paragraph])
        XCTAssertEqual(plains("1.5 metres"), ["1.5 metres"])
    }

    // MARK: - Emphasis

    func testBoldRun() {
        let runs = MarkdownPreviewRenderer.inlineRuns("a **bold** word")
        XCTAssertEqual(runs, [
            .init(text: "a "),
            .init(text: "bold", bold: true),
            .init(text: " word"),
        ])
    }

    func testItalicRun() {
        let runs = MarkdownPreviewRenderer.inlineRuns("an *italic* word")
        XCTAssertEqual(runs, [
            .init(text: "an "),
            .init(text: "italic", italic: true),
            .init(text: " word"),
        ])
    }

    func testUnderscoreItalic() {
        let runs = MarkdownPreviewRenderer.inlineRuns("_it_")
        XCTAssertEqual(runs, [.init(text: "it", italic: true)])
    }

    func testDoubleUnderscoreBold() {
        let runs = MarkdownPreviewRenderer.inlineRuns("__strong__")
        XCTAssertEqual(runs, [.init(text: "strong", bold: true)])
    }

    func testUnbalancedEmphasisStaysLiteral() {
        XCTAssertEqual(MarkdownPreviewRenderer.inlineRuns("2 * 3 = 6"), [.init(text: "2 * 3 = 6")])
        XCTAssertEqual(MarkdownPreviewRenderer.inlineRuns("**unclosed"), [.init(text: "**unclosed")])
    }

    func testEmptyEmphasisPairStaysLiteral() {
        XCTAssertEqual(MarkdownPreviewRenderer.inlineRuns("****"), [.init(text: "****")])
    }

    func testMultipleEmphasisSpansOnOneLine() {
        let runs = MarkdownPreviewRenderer.inlineRuns("**a** and **b**")
        XCTAssertEqual(runs, [
            .init(text: "a", bold: true),
            .init(text: " and "),
            .init(text: "b", bold: true),
        ])
    }

    // MARK: - Code

    func testCodeSpan() {
        let runs = MarkdownPreviewRenderer.inlineRuns("run `swift test` now")
        XCTAssertEqual(runs, [
            .init(text: "run "),
            .init(text: "swift test", code: true),
            .init(text: " now"),
        ])
    }

    func testCodeSpanContentsAreOpaqueToEmphasis() {
        let runs = MarkdownPreviewRenderer.inlineRuns("`a *b* c`")
        XCTAssertEqual(runs, [.init(text: "a *b* c", code: true)],
                       "asterisks inside a code span are literal")
    }

    func testUnterminatedCodeSpanStaysLiteral() {
        XCTAssertEqual(MarkdownPreviewRenderer.inlineRuns("a `dangling"), [.init(text: "a `dangling")])
    }

    func testFencedCodeBlock() {
        // The two fence lines render as blanks; the body is the code block.
        XCTAssertEqual(kinds("```\nlet x = 1\n```"), [.blank, .codeBlock, .blank])
        XCTAssertEqual(plains("```\nlet x = 1\n```"), ["", "let x = 1", ""])
    }

    func testFencedCodeBlockWithLanguageTag() {
        XCTAssertEqual(kinds("```swift\ncode\n```"), [.blank, .codeBlock, .blank])
    }

    func testTildeFence() {
        XCTAssertEqual(kinds("~~~\ncode\n~~~"), [.blank, .codeBlock, .blank])
    }

    func testCodeBlockPreservesIndentationAndMarkers() {
        let blocks = MarkdownPreviewRenderer.render("```\n  # not a heading\n```")
        XCTAssertEqual(blocks.map(\.kind), [.blank, .codeBlock, .blank])
        XCTAssertEqual(blocks[1].plain, "  # not a heading",
                       "code-block lines are verbatim, indentation included")
    }

    // MARK: - Links

    func testLinkKeepsItsLabel() {
        let runs = MarkdownPreviewRenderer.inlineRuns("see [docs](https://example.com) now")
        XCTAssertEqual(runs, [
            .init(text: "see "),
            .init(text: "docs", link: "https://example.com"),
            .init(text: " now"),
        ])
    }

    func testLinkAttributeIsAttached() {
        let attributed = MarkdownPreviewRenderer.inline("[docs](https://example.com)")
        let run = attributed.runs.first { $0.link != nil }
        XCTAssertEqual(run?.link, URL(string: "https://example.com"))
    }

    func testBareBracketsAreNotALink() {
        let runs = MarkdownPreviewRenderer.inlineRuns("[TODO] ship")
        XCTAssertTrue(runs.allSatisfy { $0.link == nil }, "no run may be linked")
        // The scanner may split around the bracket; what matters is that the text
        // survives intact and in order.
        XCTAssertEqual(runs.map(\.text).joined(), "[TODO] ship")
    }

    // MARK: - Rules, quotes, blanks

    func testHorizontalRules() {
        XCTAssertEqual(kinds("---"), [.horizontalRule])
        XCTAssertEqual(kinds("***"), [.horizontalRule])
        XCTAssertEqual(kinds("___"), [.horizontalRule])
    }

    func testBlockQuote() {
        XCTAssertEqual(kinds("> quoted"), [.blockQuote])
        XCTAssertEqual(plains("> quoted"), ["quoted"])
    }

    func testBlankLinesBecomeSpacers() {
        XCTAssertEqual(kinds("a\n\nb"), [.paragraph, .blank, .paragraph])
    }

    // MARK: - The core invariant: no loss, no reordering

    func testEveryLineProducesExactlyOneBlock() {
        // The invariant that makes "never lose content" checkable: EVERY input line
        // yields exactly one block, fence markers and blank lines included.
        let docs = [
            "# H\n\ntext\n- item\n> quote\n---\nplain",
            "```\ncode\n```",
            "```\nunterminated",
            "a\n\n\nb",
            String(repeating: "`", count: 20),
        ]
        for doc in docs {
            XCTAssertEqual(MarkdownPreviewRenderer.render(doc).count,
                           doc.components(separatedBy: "\n").count,
                           "one block per input line, for: \(doc.prefix(20))…")
        }
    }

    func testContentOrderIsPreserved() {
        XCTAssertEqual(plains("# first\nsecond\n- third"), ["first", "second", "• third"])
    }

    func testNoWordIsLostInAMixedDocument() {
        let doc = """
        # Project notes

        Some **bold** text with `code` and a [link](https://x.com).

        - alpha
        - beta

        > a quotation

        ```
        fenced code
        ```

        1. one
        2. two
        """
        let out = rendered(doc)
        for word in ["Project", "notes", "Some", "bold", "text", "with", "code",
                     "link", "alpha", "beta", "quotation", "fenced", "one", "two"] {
            XCTAssertTrue(out.contains(word), "renderer lost '\(word)'")
        }
    }

    func testPlainProseIsUntouched() {
        let prose = "Just an ordinary sentence, with commas and a period."
        XCTAssertEqual(plains(prose), [prose])
        XCTAssertEqual(kinds(prose), [.paragraph])
    }

    // MARK: - Cyrillic

    func testCyrillicHeadingAndEmphasis() {
        XCTAssertEqual(kinds("## Заголовок"), [.heading(level: 2)])
        XCTAssertEqual(plains("## Заголовок"), ["Заголовок"])
        XCTAssertEqual(MarkdownPreviewRenderer.inlineRuns("**жирный** текст"), [
            .init(text: "жирный", bold: true),
            .init(text: " текст"),
        ])
    }

    func testCyrillicListAndCodeSurvive() {
        XCTAssertEqual(plains("- идея\n- вторая"), ["• идея", "• вторая"])
        XCTAssertEqual(rendered("`код`"), "код")
    }

    func testMixedScriptDocumentLosesNothing() {
        let doc = "# Заметки\n\nTesting **смешанный** text."
        let out = rendered(doc)
        XCTAssertTrue(out.contains("Заметки"))
        XCTAssertTrue(out.contains("смешанный"))
        XCTAssertTrue(out.contains("Testing"))
    }

    // MARK: - Pathological inputs

    func testUnterminatedFenceTreatsRestAsCodeWithoutLosingIt() {
        let blocks = MarkdownPreviewRenderer.render("intro\n```\nstill here\nand here")
        XCTAssertEqual(blocks.map(\.plain), ["intro", "", "still here", "and here"],
                       "an unterminated fence must never swallow the remaining lines")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .blank, .codeBlock, .codeBlock])
    }

    func testEmptyDocumentRendersOneBlankBlock() {
        // One block per line, and "" is one (empty) line.
        XCTAssertEqual(kinds(""), [.blank])
    }

    func testWhitespaceOnlyDocument() {
        XCTAssertEqual(kinds("   \n\t\n"), [.blank, .blank, .blank])
    }

    func testLongMarkerRunsDoNotHang() {
        let inputs = [
            String(repeating: "#", count: 1000),
            String(repeating: "*", count: 1000),
            String(repeating: "`", count: 1000),
            String(repeating: "[", count: 500),
            String(repeating: "[a](b)", count: 300),
            String(repeating: "> ", count: 500) + "deep",
            String(repeating: "- ", count: 500),
        ]
        for input in inputs {
            let blocks = MarkdownPreviewRenderer.render(input)
            XCTAssertFalse(blocks.isEmpty, "input produced no blocks: \(input.prefix(20))…")
        }
    }

    func testNestedEmphasisDoesNotDropText() {
        XCTAssertTrue(rendered("**bold with *inner* inside**").contains("bold with"))
        XCTAssertTrue(rendered("**bold with *inner* inside**").contains("inner"))
        XCTAssertTrue(rendered("**bold with *inner* inside**").contains("inside"))
    }

    func testVeryLongSingleLineIsRenderedWhole() {
        let long = String(repeating: "word ", count: 5000)
        XCTAssertEqual(plains(long), [long.trimmingCharacters(in: .whitespaces)])
    }
}
