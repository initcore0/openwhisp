import XCTest
@testable import OpenWhispCore

/// MAK-71: recovering discrete bias terms from the whisper-shaped `prompt` string.
/// The input format is whatever `Vocabulary.whisperPrompt` /
/// `AppState.effectiveWhisperPrompt` produce (comma-joined terms), so these tests
/// pin the round-trip rather than an invented format.
final class ParakeetVocabularyPromptTests: XCTestCase {

    func testSplitsCommaJoinedTerms() {
        // Exactly what Vocabulary.whisperPrompt emits.
        XCTAssertEqual(
            ParakeetVocabularyPrompt.terms(from: "Claude, Anthropic, kubectl"),
            ["Claude", "Anthropic", "kubectl"])
    }

    func testRoundTripsWhisperPrompt() {
        // The real contract: whatever the vocabulary produces must come back out.
        let vocabulary = Vocabulary(terms: ["Claude", "Anthropic", "OpenWhisp"], substitutions: [])
        XCTAssertEqual(
            ParakeetVocabularyPrompt.terms(from: vocabulary.whisperPrompt),
            ["Claude", "Anthropic", "OpenWhisp"])
    }

    func testEmptyPromptYieldsNoTerms() {
        // Drives the "take the plain unbiased path" branch — the common case,
        // since vocabulary is off by default.
        XCTAssertTrue(ParakeetVocabularyPrompt.terms(from: "").isEmpty)
        XCTAssertTrue(ParakeetVocabularyPrompt.terms(from: "   ").isEmpty)
        XCTAssertTrue(ParakeetVocabularyPrompt.terms(from: ", , ,").isEmpty)
    }

    func testDropsTermsTooShortForTheSpotter() {
        // CTC-WS skips <3 chars anyway (false-positive control per the NeMo
        // paper); dropping them here avoids pointless tokenizer work.
        XCTAssertEqual(
            ParakeetVocabularyPrompt.terms(from: "Claude, ok, hi, Anthropic"),
            ["Claude", "Anthropic"])
    }

    func testDropsProseLengthEntries() {
        // effectiveWhisperPrompt can carry screen-context harvest; a sentence is
        // not a keyword and would waste a CTC pass.
        let prose = String(repeating: "x", count: 61)
        XCTAssertEqual(
            ParakeetVocabularyPrompt.terms(from: "Claude, \(prose)"),
            ["Claude"])
    }

    func testDedupesCaseInsensitivelyKeepingFirstSpelling() {
        // Screen-context harvest can re-surface a term the user already typed;
        // "Claude" and "claude" spot identically, so the second is wasted work.
        XCTAssertEqual(
            ParakeetVocabularyPrompt.terms(from: "Claude, claude, CLAUDE, Anthropic"),
            ["Claude", "Anthropic"])
    }

    func testHandlesScreenContextConcatenation() {
        // AppState joins vocabulary + harvested bias terms with ", " — the exact
        // shape the engine receives when screen context is on.
        XCTAssertEqual(
            ParakeetVocabularyPrompt.terms(from: "Claude, Anthropic, kubectl, Grafana"),
            ["Claude", "Anthropic", "kubectl", "Grafana"])
    }

    func testPreservesInternalSpacingOfMultiWordTerms() {
        // Multi-word terms are weaker in CTC-WS but legal; don't mangle them.
        XCTAssertEqual(
            ParakeetVocabularyPrompt.terms(from: "Claude Code, San Francisco"),
            ["Claude Code", "San Francisco"])
    }
}
