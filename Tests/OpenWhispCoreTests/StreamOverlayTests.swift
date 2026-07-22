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

    // MARK: - Caption reducer

    func testPartialThenFinalScrollsWindow() {
        var caps = StreamOverlayCaptions(maxLines: 2)
        _ = caps.setPartial("hel")
        var snap = caps.setPartial("hello wor")
        XCTAssertEqual(snap.partial, "hello wor")
        XCTAssertEqual(snap.lines, [])

        snap = caps.commitFinal("hello world")
        XCTAssertEqual(snap.partial, "", "final clears the partial")
        XCTAssertEqual(snap.lines, ["hello world"])

        _ = caps.commitFinal("line two")
        snap = caps.commitFinal("line three")
        XCTAssertEqual(snap.lines, ["line two", "line three"], "window caps at maxLines")
    }

    func testEmptyFinalOnlyClearsPartial() {
        var caps = StreamOverlayCaptions(maxLines: 3)
        _ = caps.commitFinal("kept")
        let snap = caps.commitFinal("   \n")
        XCTAssertEqual(snap.lines, ["kept"])
        XCTAssertEqual(snap.partial, "")
    }

    func testRevisionIsMonotonic() {
        var caps = StreamOverlayCaptions(maxLines: 3)
        let a = caps.setPartial("a")
        let b = caps.commitFinal("a b")
        let c = caps.clear()
        XCTAssertLessThan(a.revision, b.revision)
        XCTAssertLessThan(b.revision, c.revision)
        XCTAssertEqual(c.lines, [])
    }

    // MARK: - SSE framing

    func testSSEFrameShape() throws {
        var caps = StreamOverlayCaptions(maxLines: 3)
        let frame = StreamOverlaySSE.frame(caps.commitFinal("hi"))
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
