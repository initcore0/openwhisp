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
    }

    // MARK: - Retirement (resumed speech starts clean)

    /// The reported bug: after the silence timeout hid the captions, speaking
    /// again re-showed the PREVIOUS utterance's tail. Streaming engines emit a
    /// growing session transcript, so the reducer must remember what already had
    /// its time on screen.
    func testResumedSpeechAfterSilenceShowsOnlyNewWords() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        _ = caps.setText("hello there friends")
        // Silence timeout: hide AND retire what was shown.
        let hidden = caps.retire(upTo: "hello there friends")
        XCTAssertEqual(hidden.lines, [], "silence hides the captions")
        // The engine keeps growing the SAME transcript when speech resumes.
        let resumed = caps.setText("hello there friends welcome back")
        XCTAssertEqual(resumed.lines, ["welcome back"],
                       "only the new words show — the retired utterance must not replay")
    }

    /// Retirement compounds: each silence retires only up to what was shown.
    func testRetirementCompoundsAcrossMultiplePauses() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        _ = caps.setText("one two")
        _ = caps.retire(upTo: "one two")
        var snap = caps.setText("one two three four")
        XCTAssertEqual(snap.lines, ["three four"])
        _ = caps.retire(upTo: "one two three four")
        snap = caps.setText("one two three four five")
        XCTAssertEqual(snap.lines, ["five"])
    }

    /// The engine re-punctuates/re-cases as it goes; matching on raw characters
    /// would fail and replay retired speech. Word-count matching survives it.
    func testRetirementSurvivesRepunctuation() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        _ = caps.setText("hello there")
        _ = caps.retire(upTo: "hello there")
        let snap = caps.setText("Hello, there! Welcome back")
        XCTAssertEqual(snap.lines, ["Welcome back"],
                       "re-punctuated prefix still counts as retired")
    }

    /// A new session (or a shortened/restarted transcript) must not be swallowed
    /// by a stale retirement mark — that would hide live speech forever.
    func testShorterTranscriptResetsRetirementInsteadOfHidingSpeech() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        _ = caps.setText("a long previous utterance here")
        _ = caps.retire(upTo: "a long previous utterance here")
        let snap = caps.setText("brand new")
        XCTAssertEqual(snap.lines, ["brand new"],
                       "an unrelated/shorter transcript shows in full")
    }

    /// `clear()` (capture stopped) forgets retirement — the next session's first
    /// words are new speech, not a continuation.
    func testClearResetsRetirement() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        _ = caps.setText("first session")
        _ = caps.retire(upTo: "first session")
        _ = caps.clear()
        let snap = caps.setText("first session")
        XCTAssertEqual(snap.lines, ["first session"])
    }

    /// Live wrap edits (the settings pane) rebuild the reducer; retirement and
    /// the revision counter must survive, or a rewrap resurrects faded speech /
    /// emits a frame the page drops as stale.
    func testResizedPreservesRetirementAndRevision() {
        var caps = StreamOverlayCaptions(maxLines: 3, charsPerLine: 42)
        _ = caps.setText("hello there friends")
        let retired = caps.retire(upTo: "hello there friends")
        var resized = caps.resized(maxLines: 2, charsPerLine: 20)
        XCTAssertEqual(resized.maxLines, 2)
        XCTAssertEqual(resized.charsPerLine, 20)
        XCTAssertEqual(resized.retiredTranscript, "hello there friends")
        let snap = resized.setText("hello there friends and more")
        XCTAssertEqual(snap.lines, ["and more"], "retired text stays retired after a rewrap")
        XCTAssertGreaterThan(snap.revision, retired.revision,
                             "revision keeps climbing so the page won't drop the frame")
    }

    // MARK: - Local overlay visibility (captions capture hides the pill)

    func testCaptureSessionHidesTheLocalOverlay() {
        // The reported bug: starting captions put the floating dictation pill in
        // the middle of the screen being streamed.
        XCTAssertFalse(OverlayVisibilityPolicy.showsLocalOverlay(
            setting: true, isAgentSession: false, isCaptionsCapture: true))
        // Captions capture outranks the agent force-show — an agent-driven
        // capture is still going out on stream.
        XCTAssertFalse(OverlayVisibilityPolicy.showsLocalOverlay(
            setting: true, isAgentSession: true, isCaptionsCapture: true))
        // Ordinary sessions are unchanged.
        XCTAssertTrue(OverlayVisibilityPolicy.showsLocalOverlay(
            setting: true, isAgentSession: false, isCaptionsCapture: false))
        XCTAssertFalse(OverlayVisibilityPolicy.showsLocalOverlay(
            setting: false, isAgentSession: false, isCaptionsCapture: false))
        XCTAssertTrue(OverlayVisibilityPolicy.showsLocalOverlay(
            setting: false, isAgentSession: true, isCaptionsCapture: false),
            "agent sessions still force the overlay on")
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

    /// The live-restyle wire: appearance edits reach a running page as a `style`
    /// event instead of restarting the server (which stopped the capture).
    func testStyleFrameCarriesTheLookAndIsSanitized() throws {
        let frame = StreamOverlaySSE.styleFrame(StreamOverlayConfig(
            canvasWidth: 1280, canvasHeight: 720,
            fontFamily: "Menlo; } body { display:none", fontSize: 9_999,
            backgroundColor: "nope", textColor: "#FFEE00"))
        XCTAssertTrue(frame.hasPrefix("event: style\ndata: "))
        XCTAssertTrue(frame.hasSuffix("\n\n"))
        let json = frame
            .dropFirst("event: style\ndata: ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let style = try JSONDecoder().decode(StreamOverlayStyle.self, from: Data(json.utf8))
        XCTAssertEqual(style.canvasWidth, 1280)
        XCTAssertEqual(style.textColor, "#FFEE00")
        XCTAssertEqual(style.fontSize, 400, "clamped by sanitize before going on the wire")
        XCTAssertEqual(style.backgroundColor, "#00000000", "invalid color falls back")
        XCTAssertFalse(style.fontFamily.contains(";"))
        XCTAssertFalse(style.fontFamily.contains("{"))
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
        // The page must listen for live restyles, or an appearance edit would
        // only land after an OBS source refresh.
        XCTAssertTrue(html.contains("addEventListener('style'"))
    }

    // MARK: - Voice-command matcher (phrase counter)

    func testMatcherIgnoresCaseAndPunctuation() {
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "I died again", in: "well, I DIED AGAIN!"), 1)
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "i died again", in: "I died... again?"), 1)
        // The PHRASE may be punctuated/cased too — the streamer types naturally.
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "  I Died, Again!  ", in: "i died again"), 1)
    }

    /// The word-boundary rule, stated as the bug it prevents: a substring match
    /// would count "died again" inside "studied again".
    func testMatcherMatchesWholeWordsNotSubstrings() {
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "died again", in: "I studied again today"), 0,
            #""died again" must not match inside "studied again""#)
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "die", in: "diet"), 0)
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "die", in: "I die"), 1)
        // A phrase whose words appear but not CONTIGUOUSLY doesn't count.
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "died again", in: "died, and then later again"), 0)
    }

    func testMatcherCountsMultipleOccurrencesInOneFinal() {
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(
                of: "I died again",
                in: "I died again and then I died again, unbelievable"), 2)
    }

    /// Non-overlapping: the streamer said "ha ha" once and a half, not twice.
    func testMatcherCountsNonOverlappingOccurrences() {
        XCTAssertEqual(OverlayVoiceCommandMatcher.occurrences(of: "ha ha", in: "ha ha ha"), 1)
        XCTAssertEqual(OverlayVoiceCommandMatcher.occurrences(of: "ha ha", in: "ha ha ha ha"), 2)
    }

    /// Cyrillic must behave exactly like Latin — normalization is by Unicode
    /// character properties, not an ASCII range.
    func testMatcherWorksForCyrillicPhrases() {
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "я снова умер", in: "ну всё, Я СНОВА УМЕР!"), 1)
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(
                of: "я снова умер", in: "я снова умер... и я снова умер"), 2)
        // Word boundaries hold in Cyrillic too: "умер" is not "умерла".
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "умер", in: "она умерла"), 0)
    }

    /// A half-configured counter (no phrase yet) must never fire — otherwise it
    /// would increment on EVERY utterance.
    func testEmptyOrWhitespacePhraseNeverMatches() {
        XCTAssertEqual(OverlayVoiceCommandMatcher.occurrences(of: "", in: "anything at all"), 0)
        XCTAssertEqual(OverlayVoiceCommandMatcher.occurrences(of: "   ", in: "anything at all"), 0)
        XCTAssertEqual(OverlayVoiceCommandMatcher.occurrences(of: "!!! ...", in: "anything at all"), 0)
        XCTAssertEqual(OverlayVoiceCommandMatcher.occurrences(of: "phrase", in: ""), 0)
    }

    func testPhraseLongerThanTextNeverMatches() {
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: "I died again for real", in: "I died again"), 0)
    }

    func testMatcherAcceptsACommandValue() {
        let command = OverlayVoiceCommand(phrase: "I died again")
        XCTAssertEqual(command.kind, .counter)
        XCTAssertEqual(
            OverlayVoiceCommandMatcher.occurrences(of: command, in: "oh no, I died again"), 1)
    }

    // MARK: - Counter config + wire

    func testCounterConfigDefaultsPreserveTodaysBehavior() {
        let c = StreamOverlayConfig()
        XCTAssertTrue(c.captionsEnabled, "captions stay on by default")
        XCTAssertFalse(c.counterEnabled, "the counter is opt-in")
        XCTAssertEqual(c.counterLabel, "Counter")
        XCTAssertEqual(c.counterCorner, .bottomRight)
    }

    /// A config saved BEFORE the counter shipped must keep showing captions —
    /// the decodeIfPresent default is the whole backcompat story.
    func testConfigDecodeDefaultsCaptionsOnForPreCounterConfigs() throws {
        let old = ##"{"canvasWidth":1280,"canvasHeight":720,"fontFamily":"Menlo","fontSize":40,"backgroundColor":"#00000000","textColor":"#FFFFFF","maxLines":3,"charsPerLine":42,"lingerSeconds":4,"translationEnabled":false,"targetLanguage":""}"##
        let decoded = try JSONDecoder().decode(StreamOverlayConfig.self, from: Data(old.utf8))
        XCTAssertTrue(decoded.captionsEnabled)
        XCTAssertFalse(decoded.counterEnabled)
        XCTAssertEqual(decoded.counterLabel, "Counter")
        XCTAssertEqual(decoded.counterCorner, .bottomRight)
    }

    func testCounterCornerIsRawValueCodable() throws {
        var c = StreamOverlayConfig()
        c.counterCorner = .topLeft
        let data = try JSONEncoder().encode(c)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"counterCorner\":\"topLeft\""))
        XCTAssertEqual(try JSONDecoder().decode(StreamOverlayConfig.self, from: data).counterCorner, .topLeft)
    }

    func testSanitizedBoundsCounterFieldsAndKeepsSSEFramingSafe() {
        var c = StreamOverlayConfig()
        // A label with a raw newline would break the single-line SSE `data:` frame.
        c.counterLabel = "Deaths\nevent: caption"
        c.counterPhrase = String(repeating: "x", count: 500)
        let s = c.sanitized()
        XCTAssertFalse(s.counterLabel.contains("\n"))
        XCTAssertEqual(s.counterPhrase.count, 200)

        var blank = StreamOverlayConfig()
        blank.counterLabel = "   "
        XCTAssertEqual(blank.sanitized().counterLabel, "Counter", "an empty label falls back")
    }

    func testCounterSSEFrameShape() throws {
        let frame = StreamOverlaySSE.counterFrame(StreamOverlayCounterState(
            label: "Deaths", count: 12, corner: .topLeft, visible: true))
        XCTAssertTrue(frame.hasPrefix("event: counter\ndata: "))
        XCTAssertTrue(frame.hasSuffix("\n\n"))
        let json = frame
            .dropFirst("event: counter\ndata: ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = try JSONDecoder().decode(StreamOverlayCounterState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.label, "Deaths")
        XCTAssertEqual(decoded.count, 12)
        XCTAssertEqual(decoded.corner, .topLeft)
        XCTAssertTrue(decoded.visible)
    }

    /// The style event carries the captions switch and the counter's corner, so
    /// counter-only mode and a corner move land without an OBS source refresh.
    func testStyleFrameCarriesCaptionsSwitchAndCounterCorner() throws {
        var c = StreamOverlayConfig()
        c.captionsEnabled = false
        c.counterCorner = .topRight
        let frame = StreamOverlaySSE.styleFrame(c)
        let json = frame
            .dropFirst("event: style\ndata: ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let style = try JSONDecoder().decode(StreamOverlayStyle.self, from: Data(json.utf8))
        XCTAssertFalse(style.captionsEnabled)
        XCTAssertEqual(style.counterCorner, .topRight)
    }

    // MARK: - Counter page rendering

    func testPageRendersCounterInTheConfiguredCorner() {
        var c = StreamOverlayConfig()
        c.counterEnabled = true
        c.counterCorner = .topLeft
        let html = StreamOverlayPage.html(config: c)
        XCTAssertTrue(html.contains("id=\"counter\""))
        XCTAssertTrue(html.contains("top: 3vh; left: 3vh;"))
        XCTAssertTrue(html.contains("addEventListener('counter'"))
        // The label is user text — it must land via textContent. (`innerHTML`
        // appears nowhere as an assignment; the comments naming it are the only
        // occurrences, so assert the safe call instead of the absent one.)
        XCTAssertTrue(html.contains("counterEl.textContent = st.label"))
        XCTAssertFalse(html.contains("innerHTML ="))
        XCTAssertFalse(html.contains("innerHTML="))
    }

    func testPageHidesCaptionsWhenCaptionsAreDisabled() {
        var c = StreamOverlayConfig()
        c.captionsEnabled = false
        c.counterEnabled = true
        let html = StreamOverlayPage.html(config: c)
        XCTAssertTrue(html.contains("<div id=\"captions\" class=\"hidden\">"),
                      "counter-only mode must render the caption block hidden")
        // The counter half is still fully present.
        XCTAssertTrue(html.contains("id=\"counter\""))

        let withCaptions = StreamOverlayPage.html(config: StreamOverlayConfig())
        XCTAssertTrue(withCaptions.contains("<div id=\"captions\"></div>"))
    }

    func testCornerCSSCoversEveryCase() {
        XCTAssertEqual(StreamOverlayPage.cornerCSS(.topLeft), "top: 3vh; left: 3vh;")
        XCTAssertEqual(StreamOverlayPage.cornerCSS(.topRight), "top: 3vh; right: 3vh;")
        XCTAssertEqual(StreamOverlayPage.cornerCSS(.bottomLeft), "bottom: 3vh; left: 3vh;")
        XCTAssertEqual(StreamOverlayPage.cornerCSS(.bottomRight), "bottom: 3vh; right: 3vh;")
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
