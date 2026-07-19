import XCTest
@testable import OpenWhispCore

/// MAK-84: the pure term-preparation for SpeechAnalyzer's contextual-strings
/// bias channel. The Speech-framework wiring (`AnalysisContext`, `setContext`) is
/// app-only and macOS-26-gated, exercised by real-app runs; this pins the pure
/// split+cap logic the bridge feeds into it, so a regression is caught by
/// `swift test` rather than in the running app.
final class SpeechAnalyzerContextualStringsTests: XCTestCase {

    func testSplitsCommaJoinedPromptIntoTerms() {
        // Same whisper-shaped round-trip the other engines use.
        XCTAssertEqual(
            SpeechAnalyzerContextualStrings.terms(from: "Claude, Anthropic, kubectl"),
            ["Claude", "Anthropic", "kubectl"])
    }

    func testEmptyPromptYieldsNoTerms() {
        // Empty → the plain, unbiased path (no contextual strings attached).
        XCTAssertTrue(SpeechAnalyzerContextualStrings.terms(from: "").isEmpty)
        XCTAssertTrue(SpeechAnalyzerContextualStrings.terms(from: "   ").isEmpty)
        XCTAssertTrue(SpeechAnalyzerContextualStrings.terms(from: ", , ,").isEmpty)
    }

    func testInheritsSharedSplitterFiltering() {
        // Delegates to ParakeetVocabularyPrompt: short terms (<3) dropped,
        // case-insensitive dedup. Pinned here so a swap of the splitter can't
        // silently change SpeechAnalyzer's behavior.
        XCTAssertEqual(
            SpeechAnalyzerContextualStrings.terms(from: "Claude, ok, hi, Anthropic"),
            ["Claude", "Anthropic"])
        XCTAssertEqual(
            SpeechAnalyzerContextualStrings.terms(from: "Claude, claude, CLAUDE, Anthropic"),
            ["Claude", "Anthropic"])
    }

    func testCapsTermCount() {
        // A vocabulary longer than the cap is truncated (first-N wins — the user's
        // own vocabulary is prepended ahead of harvested screen-context terms).
        let many = (0..<200).map { "term\($0)" }.joined(separator: ", ")
        let terms = SpeechAnalyzerContextualStrings.terms(from: many)
        XCTAssertEqual(terms.count, SpeechAnalyzerContextualStrings.maxTerms)
        XCTAssertEqual(terms.first, "term0")
        XCTAssertEqual(terms.last, "term\(SpeechAnalyzerContextualStrings.maxTerms - 1)")
    }

    func testUnderCapPassesEverythingThrough() {
        let few = (0..<10).map { "term\($0)" }.joined(separator: ", ")
        XCTAssertEqual(SpeechAnalyzerContextualStrings.terms(from: few).count, 10)
    }
}
