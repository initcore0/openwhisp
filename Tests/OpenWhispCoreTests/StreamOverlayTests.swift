import XCTest
@testable import OpenWhispCore

/// EXPERIMENT (stream overlay): the pure halves — config sanitizing, the caption
/// reducer, SSE framing, and the generated overlay page — so the server can lean
/// on tested logic. The live HTTP/SSE path is covered in
/// Tests/OpenWhispSyncLANTests/StreamOverlayServerTests.swift.
final class StreamOverlayTests: XCTestCase {

    // MARK: - Config

    func testDefaultsAreFullHD() {
        let c = StreamOverlayConfig()
        XCTAssertEqual(c.canvasWidth, 1920)
        XCTAssertEqual(c.canvasHeight, 1080)
        XCTAssertFalse(c.translationEnabled)
    }

    func testHexColorValidation() {
        XCTAssertTrue(StreamOverlayConfig.isValidHexColor("#FFF"))
        XCTAssertTrue(StreamOverlayConfig.isValidHexColor("#00FF00"))
        XCTAssertTrue(StreamOverlayConfig.isValidHexColor("#00000000"))
        XCTAssertFalse(StreamOverlayConfig.isValidHexColor("00FF00"))     // no #
        XCTAssertFalse(StreamOverlayConfig.isValidHexColor("#00FF0"))     // 5 digits
        XCTAssertFalse(StreamOverlayConfig.isValidHexColor("#GGGGGG"))    // not hex
        XCTAssertFalse(StreamOverlayConfig.isValidHexColor("red"))
    }

    func testSanitizedClampsAndDefaults() {
        var c = StreamOverlayConfig(
            canvasWidth: 1, canvasHeight: 99_999,
            fontFamily: "Menlo; } body { display:none",  // CSS-escape attempt
            fontSize: 0,
            backgroundColor: "not-a-color", textColor: "#GGGGGG",
            maxLines: 0)
        c.targetLanguage = "es<script>"
        let s = c.sanitized()
        XCTAssertEqual(s.canvasWidth, 320)
        XCTAssertEqual(s.canvasHeight, 4_320)
        XCTAssertEqual(s.fontSize, 8)
        XCTAssertEqual(s.maxLines, 1)
        XCTAssertEqual(s.backgroundColor, "#00000000")
        XCTAssertEqual(s.textColor, "#FFFFFF")
        XCTAssertFalse(s.fontFamily.contains(";"))
        XCTAssertFalse(s.fontFamily.contains("{"))
        XCTAssertEqual(s.targetLanguage, "esscript")
    }

    func testSanitizedKeepsValidConfigUntouched() {
        let c = StreamOverlayConfig(
            canvasWidth: 1280, canvasHeight: 720,
            fontFamily: "'Helvetica Neue', sans-serif", fontSize: 36,
            backgroundColor: "#112233", textColor: "#FFEE00",
            maxLines: 5, translationEnabled: true, targetLanguage: "es")
        XCTAssertEqual(c.sanitized(), c)
    }

    // MARK: - Subtitle reducer (movie-style window)

    func testWrapsAndWindowsLikeMovieSubtitles() {
        var caps = StreamOverlayCaptions(maxLines: 2, charsPerLine: 12)
        // Short text: one line, no window trimming.
        var snap = caps.setText("hello there")
        XCTAssertEqual(snap.lines, ["hello there"])
        // Longer text wraps; only the LAST two lines stay (oldest scrolls off).
        snap = caps.setText("hello there my good friends of the stream")
        XCTAssertEqual(snap.lines.count, 2)
        XCTAssertEqual(snap.lines.last, "the stream")
        XCTAssertTrue(snap.lines.allSatisfy { $0.count <= 12 })
    }

    func testWrapBreaksOnWordsAndHardSplitsLongWords() {
        XCTAssertEqual(
            StreamOverlayCaptions.wrap("one two three four", width: 9),
            ["one two", "three", "four"])
        // A word longer than the budget hard-splits instead of blowing the line.
        XCTAssertEqual(
            StreamOverlayCaptions.wrap("see https://example.com/x ok", width: 10),
            ["see", "https://ex", "ample.com/", "x ok"])
        XCTAssertEqual(StreamOverlayCaptions.wrap("", width: 10), [])
        XCTAssertEqual(StreamOverlayCaptions.wrap("  \n  ", width: 10), [])
    }

    func testEmptyTextClearsAndClearHides() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        _ = caps.setText("something on screen")
        var snap = caps.setText("")
        XCTAssertEqual(snap.lines, [], "empty text (session reset) hides captions")
        _ = caps.setText("back again")
        snap = caps.clear()
        XCTAssertEqual(snap.lines, [], "clear (silence timeout) hides captions")
    }

    func testRevisionIsMonotonic() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        let a = caps.setText("a")
        let b = caps.setText("a b")
        let c = caps.clear()
        XCTAssertLessThan(a.revision, b.revision)
        XCTAssertLessThan(b.revision, c.revision)
    }

    func testConfigDecodeToleratesMissingNewFields() throws {
        // A v1 config JSON (no charsPerLine/lingerSeconds) must still decode,
        // falling back to defaults — users' saved settings survive the upgrade.
        let v1 = ##"{"canvasWidth":1280,"canvasHeight":720,"fontFamily":"Menlo","fontSize":40,"backgroundColor":"#00000000","textColor":"#FFFFFF","maxLines":3,"translationEnabled":false,"targetLanguage":""}"##
        let decoded = try JSONDecoder().decode(StreamOverlayConfig.self, from: Data(v1.utf8))
        XCTAssertEqual(decoded.canvasWidth, 1280)
        XCTAssertEqual(decoded.charsPerLine, StreamOverlayConfig().charsPerLine)
        XCTAssertEqual(decoded.lingerSeconds, StreamOverlayConfig().lingerSeconds)
        // captionTrack (added with dual-runtime translation) is absent in v1 →
        // defaults to .original, so an old install keeps its single-track look.
        XCTAssertEqual(decoded.captionTrack, .original)
    }

    func testCaptionTrackDecodesAndRoundTrips() throws {
        var c = StreamOverlayConfig()
        c.captionTrack = .both
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(StreamOverlayConfig.self, from: data)
        XCTAssertEqual(back.captionTrack, .both)
        // An unknown/garbage value would fail enum decode; decodeIfPresent guards
        // the ABSENT case, which the v1 test covers.
    }

    // MARK: - Two-track (translated) reducer

    func testTranslatedTrackIsIndependentOfOriginal() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        var snap = caps.setText("привет как дела")
        XCTAssertEqual(snap.lines, ["привет как дела"])
        XCTAssertEqual(snap.translatedLines, [], "no translated segment yet")
        // A translated segment lands without disturbing the original line.
        snap = caps.setTranslatedText("hello how are you")
        XCTAssertEqual(snap.lines, ["привет как дела"], "original track untouched")
        XCTAssertEqual(snap.translatedLines, ["hello how are you"])
        // A new original partial keeps the translated line in place (it trails).
        snap = caps.setText("привет как дела сегодня")
        XCTAssertEqual(snap.translatedLines, ["hello how are you"])
    }

    func testTranslatedTrackWrapsAndWindows() {
        var caps = StreamOverlayCaptions(maxLines: 2, charsPerLine: 10)
        let snap = caps.setTranslatedText("one two three four five six")
        XCTAssertLessThanOrEqual(snap.translatedLines.count, 2, "windowed to maxLines")
        XCTAssertTrue(snap.translatedLines.allSatisfy { $0.count <= 10 })
    }

    func testClearHidesBothTracks() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        _ = caps.setText("original")
        _ = caps.setTranslatedText("translated")
        let snap = caps.clear()
        XCTAssertEqual(snap.lines, [])
        XCTAssertEqual(snap.translatedLines, [])
    }

    func testSnapshotDecodesWithoutTranslatedLines() throws {
        // A single-track client/older frame with no translatedLines key still
        // decodes (the field defaults to []), keeping the wire backward-compatible.
        let v1 = ##"{"lines":["hi"],"revision":3}"##
        let snap = try JSONDecoder().decode(
            StreamOverlayCaptions.Snapshot.self, from: Data(v1.utf8))
        XCTAssertEqual(snap.lines, ["hi"])
        XCTAssertEqual(snap.translatedLines, [])
        XCTAssertEqual(snap.revision, 3)
    }

    func testSSEFrameCarriesTranslatedLines() throws {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        _ = caps.setText("оригинал")
        let frame = StreamOverlaySSE.frame(caps.setTranslatedText("original"))
        let json = frame
            .dropFirst("event: caption\ndata: ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = try JSONDecoder().decode(
            StreamOverlayCaptions.Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.lines, ["оригинал"])
        XCTAssertEqual(decoded.translatedLines, ["original"])
    }

    func testPageRendersTranslatedTrackPerMode() {
        let both = StreamOverlayPage.html(
            config: StreamOverlayConfig(captionTrack: .both))
        XCTAssertTrue(both.contains("const track = 'both'"))
        XCTAssertTrue(both.contains("translatedLines"))
        let translated = StreamOverlayPage.html(
            config: StreamOverlayConfig(captionTrack: .translated))
        XCTAssertTrue(translated.contains("const track = 'translated'"))
        let original = StreamOverlayPage.html(
            config: StreamOverlayConfig(captionTrack: .original))
        XCTAssertTrue(original.contains("const track = 'original'"))
    }

    // MARK: - SSE framing

    func testSSEFrameShape() throws {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        let frame = StreamOverlaySSE.frame(caps.setText("hi"))
        XCTAssertTrue(frame.hasPrefix("event: caption\ndata: "))
        XCTAssertTrue(frame.hasSuffix("\n\n"))
        // The data line round-trips as a Snapshot.
        let json = frame
            .dropFirst("event: caption\ndata: ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = try JSONDecoder().decode(
            StreamOverlayCaptions.Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.lines, ["hi"])
    }

    // MARK: - Page generation

    func testPageEmbedsDisplayParameters() {
        let html = StreamOverlayPage.html(config: StreamOverlayConfig(
            canvasWidth: 1280, canvasHeight: 720,
            fontFamily: "Menlo, monospace", fontSize: 64,
            backgroundColor: "#00000000", textColor: "#FFEE00", maxLines: 2))
        XCTAssertTrue(html.contains("width: 1280px"))
        XCTAssertTrue(html.contains("height: 720px"))
        XCTAssertTrue(html.contains("font-family: Menlo, monospace"))
        XCTAssertTrue(html.contains("font-size: 64px"))
        XCTAssertTrue(html.contains("background: #00000000"))
        XCTAssertTrue(html.contains("color: #FFEE00"))
        XCTAssertTrue(html.contains("EventSource('/events')"))
    }

    func testPageSanitizesHostileConfig() {
        let html = StreamOverlayPage.html(config: StreamOverlayConfig(
            fontFamily: "x; } </style><script>alert(1)</script>",
            backgroundColor: "</style>"))
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertFalse(html.contains("</style><"))
        XCTAssertTrue(html.contains("background: #00000000"), "invalid color falls back")
    }
}
