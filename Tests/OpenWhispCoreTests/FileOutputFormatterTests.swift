import XCTest
@testable import OpenWhispCore

/// Tests for the pure file-output core (MAK-12): rendering a dictation into the
/// entry / append-chunk / overwrite-contents to write, template token expansion,
/// empty-text handling, and `FileOutputConfig` Codable round-trips. No filesystem —
/// these are the reliable, deterministic heart of the feature.
///
/// One end-to-end test DOES write to a temp file, but it exercises the *formatter's*
/// output (the app-only `FileOutputTarget` isn't compiled into `OpenWhispCore`), so
/// it verifies the bytes the writer would produce actually land on disk correctly.
final class FileOutputFormatterTests: XCTestCase {

    // A fixed timestamp so token expansion is deterministic. 2026-07-09 14:30 UTC.
    private let fixedDate = Date(timeIntervalSince1970: 1_783_607_400)
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    private func config(template: String? = nil, mode: FileOutputMode = .append) -> FileOutputConfig {
        FileOutputConfig(path: "/tmp/notes.md", template: template, mode: mode)
    }

    // MARK: - renderEntry: no template

    func testRenderEntryWithoutTemplateIsJustTheText() {
        let entry = FileOutputFormatter.renderEntry(
            text: "buy milk", config: config(template: nil),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(entry, "buy milk")
    }

    func testRenderEntryBlankTemplateIsTreatedAsNoTemplate() {
        let entry = FileOutputFormatter.renderEntry(
            text: "buy milk", config: config(template: "   \n  "),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(entry, "buy milk")
    }

    func testRenderEntryTrimsSurroundingWhitespaceFromText() {
        let entry = FileOutputFormatter.renderEntry(
            text: "  hello world\n", config: config(template: nil),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(entry, "hello world")
    }

    // MARK: - renderEntry: with template + token expansion

    func testRenderEntryWithHeadingAboveText() {
        let entry = FileOutputFormatter.renderEntry(
            text: "buy milk", config: config(template: "## Notes"),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(entry, "## Notes\nbuy milk")
    }

    func testTemplateDateToken() {
        let entry = FileOutputFormatter.renderEntry(
            text: "x", config: config(template: "# {{date}}"),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(entry, "# 2026-07-09\nx")
    }

    func testTemplateTimeToken() {
        let entry = FileOutputFormatter.renderEntry(
            text: "x", config: config(template: "at {{time}}"),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(entry, "at 14:30\nx")
    }

    func testTemplateDatetimeToken() {
        let entry = FileOutputFormatter.renderEntry(
            text: "x", config: config(template: "## {{datetime}}"),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(entry, "## 2026-07-09 14:30\nx")
    }

    func testTemplateDatetimeTokenIsNotEatenByDateToken() {
        // {{datetime}} must expand to the full stamp, not "2026-07-09time".
        let heading = FileOutputFormatter.expandedHeading(
            "{{datetime}}", date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(heading, "2026-07-09 14:30")
    }

    func testTemplateAllTokensTogether() {
        let entry = FileOutputFormatter.renderEntry(
            text: "note", config: config(template: "{{date}} / {{time}} / {{datetime}}"),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(entry, "2026-07-09 / 14:30 / 2026-07-09 14:30\nnote")
    }

    // MARK: - empty text handling

    func testRenderEntryEmptyTextReturnsNil() {
        XCTAssertNil(FileOutputFormatter.renderEntry(
            text: "", config: config(template: "## heading"),
            date: fixedDate, timeZone: utc, locale: posix
        ))
    }

    func testRenderEntryWhitespaceTextReturnsNil() {
        XCTAssertNil(FileOutputFormatter.renderEntry(
            text: "  \n\t ", config: config(template: "## heading"),
            date: fixedDate, timeZone: utc, locale: posix
        ))
    }

    func testAppendChunkEmptyTextReturnsNil() {
        // An empty dictation must never append a bare heading or a stray separator.
        XCTAssertNil(FileOutputFormatter.renderAppendChunk(
            text: "", config: config(template: "## heading"),
            existingContents: "prior content",
            date: fixedDate, timeZone: utc, locale: posix
        ))
    }

    func testOverwriteEmptyTextReturnsNil() {
        // Empty dictation must NOT blank the file.
        XCTAssertNil(FileOutputFormatter.renderOverwriteContents(
            text: "   ", config: config(template: "## heading"),
            date: fixedDate, timeZone: utc, locale: posix
        ))
    }

    // MARK: - append separators

    func testAppendToEmptyFileHasNoLeadingSeparator() {
        let chunk = FileOutputFormatter.renderAppendChunk(
            text: "first", config: config(template: nil),
            existingContents: "",
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(chunk, "first\n")
    }

    func testAppendAfterMidLineContentAddsBlankLineSeparator() {
        // Existing content ends mid-line → finish the line + a blank line before the entry.
        let chunk = FileOutputFormatter.renderAppendChunk(
            text: "second", config: config(template: nil),
            existingContents: "first entry",
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(chunk, "\n\nsecond\n")
    }

    func testAppendAfterSingleNewlineAddsOneMoreForBlankLine() {
        let chunk = FileOutputFormatter.renderAppendChunk(
            text: "second", config: config(template: nil),
            existingContents: "first entry\n",
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(chunk, "\nsecond\n")
    }

    func testAppendAfterBlankLineAddsNoExtraSeparator() {
        let chunk = FileOutputFormatter.renderAppendChunk(
            text: "second", config: config(template: nil),
            existingContents: "first entry\n\n",
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(chunk, "second\n")
    }

    func testAppendChunkIncludesHeading() {
        let chunk = FileOutputFormatter.renderAppendChunk(
            text: "log this", config: config(template: "## {{datetime}}"),
            existingContents: "earlier\n",
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(chunk, "\n## 2026-07-09 14:30\nlog this\n")
    }

    // MARK: - overwrite

    func testOverwriteReplacesWithEntryPlusNewline() {
        let contents = FileOutputFormatter.renderOverwriteContents(
            text: "latest", config: config(template: nil, mode: .overwrite),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(contents, "latest\n")
    }

    func testOverwriteWithHeading() {
        let contents = FileOutputFormatter.renderOverwriteContents(
            text: "latest", config: config(template: "# {{date}}", mode: .overwrite),
            date: fixedDate, timeZone: utc, locale: posix
        )
        XCTAssertEqual(contents, "# 2026-07-09\nlatest\n")
    }

    // MARK: - Codable round-trip

    func testConfigCodableRoundTrips() throws {
        let cfg = FileOutputConfig(
            path: "/Users/me/vault/daily.md",
            template: "## {{datetime}}",
            mode: .append
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(FileOutputConfig.self, from: data)
        XCTAssertEqual(decoded, cfg)
    }

    func testConfigCodableRoundTripsWithNilTemplateAndOverwrite() throws {
        let cfg = FileOutputConfig(path: "/tmp/scratch.md", template: nil, mode: .overwrite)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(FileOutputConfig.self, from: data)
        XCTAssertEqual(decoded, cfg)
        XCTAssertNil(decoded.template)
        XCTAssertEqual(decoded.mode, .overwrite)
    }

    func testFileOutputModeRawValuesAreStable() {
        // Persisted contract — pin the strings.
        XCTAssertEqual(FileOutputMode.append.rawValue, "append")
        XCTAssertEqual(FileOutputMode.overwrite.rawValue, "overwrite")
        XCTAssertEqual(FileOutputMode(rawValue: "append"), .append)
        XCTAssertNil(FileOutputMode(rawValue: "nonsense"))
    }

    func testConfigDefaultsToAppendMode() {
        let cfg = FileOutputConfig(path: "/tmp/x.md")
        XCTAssertEqual(cfg.mode, .append)
        XCTAssertNil(cfg.template)
    }

    // MARK: - end-to-end to a temp file (formatter output actually lands on disk)

    func testAppendChunksAccumulateInATempFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openwhisp-mak12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("daily.md")

        let cfg = FileOutputConfig(path: url.path, template: nil, mode: .append)

        func appendDictation(_ text: String) throws {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard let chunk = FileOutputFormatter.renderAppendChunk(
                text: text, config: cfg, existingContents: existing,
                date: fixedDate, timeZone: utc, locale: posix
            ) else { return }
            if let data = (existing + chunk).data(using: .utf8) {
                try data.write(to: url)
            }
        }

        try appendDictation("first note")
        try appendDictation("second note")
        try appendDictation("   ")           // empty → must not add anything
        try appendDictation("third note")

        let final = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(final, "first note\n\nsecond note\n\nthird note\n")
    }
}
