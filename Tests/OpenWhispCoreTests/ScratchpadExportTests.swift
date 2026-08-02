import XCTest
@testable import OpenWhispCore

/// Tests for Scratchpad note export (MAK-96): the `.md`/`.txt` split and the
/// suggested-file-name slug rules.
final class ScratchpadExportTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func note(_ text: String) -> ScratchpadNote {
        ScratchpadNote(text: text, createdAt: t0)
    }

    // MARK: - Markdown format: verbatim

    func testMarkdownExportIsVerbatim() {
        let body = "# Title\n\nSome **bold** text.\n\n- one\n- two"
        XCTAssertEqual(ScratchpadExport.render(note: note(body), format: .md), body + "\n")
    }

    func testMarkdownPreservesCodeFencesExactly() {
        let body = "```swift\nlet x = 1\n```"
        XCTAssertEqual(ScratchpadExport.render(note: note(body), format: .md), body + "\n")
    }

    // MARK: - Plain text format: markers stripped

    func testPlainTextStripsMarkers() {
        let out = ScratchpadExport.render(note: note("# Title\n\n**bold** and `code`"), format: .txt)
        XCTAssertEqual(out, "Title\n\nbold and code\n")
    }

    func testPlainTextKeepsEveryWord() {
        let body = "## Heading\n- alpha\n- beta\n> quoted"
        let out = ScratchpadExport.render(note: note(body), format: .txt)
        for word in ["Heading", "alpha", "beta", "quoted"] {
            XCTAssertTrue(out.contains(word), "txt export lost '\(word)'")
        }
        XCTAssertFalse(out.contains("##"))
    }

    // MARK: - Trailing newline

    func testBothFormatsEndInExactlyOneNewline() {
        for format in ScratchpadExport.Format.allCases {
            let out = ScratchpadExport.render(note: note("body\n\n\n"), format: format)
            XCTAssertTrue(out.hasSuffix("\n"))
            XCTAssertFalse(out.hasSuffix("\n\n"), "\(format) left extra trailing newlines")
        }
    }

    func testEmptyNoteExportsEmptyString() {
        for format in ScratchpadExport.Format.allCases {
            XCTAssertEqual(ScratchpadExport.render(note: note(""), format: format), "")
        }
    }

    // MARK: - File names

    func testFileNameSlugsTheTitle() {
        XCTAssertEqual(
            ScratchpadExport.exportFileName(for: note("# Project Notes\n\nbody"), format: .md),
            "project-notes.md"
        )
    }

    func testFileNameUsesTheFormatExtension() {
        XCTAssertEqual(ScratchpadExport.exportFileName(for: note("Hello"), format: .txt), "hello.txt")
    }

    func testEmptyNoteFallsBackToTimestamp() {
        let name = ScratchpadExport.exportFileName(for: note(""), format: .md)
        XCTAssertEqual(name, "scratchpad-1000000.md")
    }

    func testPunctuationOnlyTitleFallsBackToTimestamp() {
        let name = ScratchpadExport.exportFileName(for: note("!!! ???"), format: .md)
        XCTAssertEqual(name, "scratchpad-1000000.md")
    }

    // MARK: - slugify

    func testSlugifyLowercasesAndHyphenates() {
        XCTAssertEqual(ScratchpadExport.slugify("Hello World"), "hello-world")
    }

    func testSlugifyCollapsesRunsOfPunctuation() {
        XCTAssertEqual(ScratchpadExport.slugify("a  --  b"), "a-b")
    }

    func testSlugifyDropsLeadingAndTrailingSeparators() {
        XCTAssertEqual(ScratchpadExport.slugify("  ...hello...  "), "hello")
    }

    func testSlugifyKeepsUnicodeLetters() {
        // A Cyrillic note deserves a Cyrillic file name, not an empty slug.
        XCTAssertEqual(ScratchpadExport.slugify("Заметка о работе"), "заметка-о-работе")
    }

    func testSlugifyCapsLength() {
        let slug = ScratchpadExport.slugify(String(repeating: "a", count: 200))
        XCTAssertLessThanOrEqual(slug.count, 48)
    }

    func testSlugifyTreatsPlaceholderTitleAsEmpty() {
        XCTAssertEqual(ScratchpadExport.slugify("New note"), "",
                       "the placeholder title is not user content")
    }

    func testSlugifyOfEmojiOnlyIsEmpty() {
        XCTAssertEqual(ScratchpadExport.slugify("🎉🎉🎉"), "")
    }

    // MARK: - Format metadata

    func testFormatExtensions() {
        XCTAssertEqual(ScratchpadExport.Format.md.fileExtension, "md")
        XCTAssertEqual(ScratchpadExport.Format.txt.fileExtension, "txt")
    }

    func testAllCasesCovered() {
        XCTAssertEqual(Set(ScratchpadExport.Format.allCases.map(\.rawValue)), ["md", "txt"])
    }

    // MARK: - Meeting-note interplay (MAK-96 header unification)

    func testMeetingNoteExportsWithItsH1Intact() {
        var notes = ScratchpadNotes()
        let meeting = Meeting(startedAt: t0, duration: 61, transcript: "hi", status: .done)
        let id = notes.insertMeetingNote(meeting, now: t0)
        let note = notes.note(id)!

        XCTAssertTrue(ScratchpadExport.render(note: note, format: .md).hasPrefix("# Meeting — "))
        XCTAssertTrue(ScratchpadExport.render(note: note, format: .txt).hasPrefix("Meeting — "),
                      "the txt export strips the H1 marker")
        XCTAssertTrue(ScratchpadExport.exportFileName(for: note, format: .md).hasPrefix("meeting-"))
    }
}
