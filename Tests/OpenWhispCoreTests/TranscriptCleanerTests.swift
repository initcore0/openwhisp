import XCTest
@testable import OpenWhispCore

final class TranscriptCleanerTests: XCTestCase {

    private func cleaner(
        vocab: [Vocabulary.Substitution] = [],
        vocabEnabled: Bool = true,
        formatting: Bool = true,
        fillers: Bool = true,
        spoken: Bool = true,
        language: String = "en"
    ) -> TranscriptCleaner {
        TranscriptCleaner(config: .init(
            language: language,
            customVocabularyEnabled: vocabEnabled,
            substitutions: vocab,
            smartFormattingEnabled: formatting,
            fillerRemovalEnabled: fillers,
            spokenPunctuationEnabled: spoken
        ))
    }

    // MARK: Normalization + markers + ignorable

    func testTrimsLeadingSpaceAndCapitalizes() {
        XCTAssertEqual(cleaner().clean(" hello world", isFinalTranscript: false), "Hello world")
    }

    func testRemovesNonSpeechMarkers() {
        XCTAssertEqual(cleaner().clean("hello [music] world", isFinalTranscript: false), "Hello world")
    }

    func testIgnorableBecomesEmpty() {
        XCTAssertEqual(cleaner().clean("[BLANK_AUDIO]", isFinalTranscript: false), "")
        XCTAssertEqual(cleaner().clean("(silence)", isFinalTranscript: false), "")
        XCTAssertEqual(cleaner().clean("   ", isFinalTranscript: false), "")
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(cleaner().clean("hello     world", isFinalTranscript: false), "Hello world")
    }

    // MARK: Vocabulary + formatting ordering (sub before formatting)

    func testVocabSubstitutionThenCasing() {
        let c = cleaner(vocab: [.init(from: "clod code", to: "Claude Code")])
        XCTAssertEqual(c.clean("i use clod code daily", isFinalTranscript: false), "I use Claude Code daily")
    }

    func testVocabDisabledLeavesText() {
        let c = cleaner(vocab: [.init(from: "clod code", to: "Claude Code")], vocabEnabled: false)
        XCTAssertEqual(c.clean("i use clod code daily", isFinalTranscript: false), "I use clod code daily")
    }

    func testFormattingOffIsNearPassthrough() {
        let c = cleaner(formatting: false)
        XCTAssertEqual(c.clean("um hello world", isFinalTranscript: false), "um hello world")
    }

    // MARK: Meta-instruction strip only on final

    func testMetaStripOnlyWhenFinal() {
        let input = "Hello, how are you? Please translate this into English."
        XCTAssertEqual(cleaner().clean(input, isFinalTranscript: true), "Hello, how are you?")
        // Not final → the trailing instruction is NOT stripped (still formatted).
        XCTAssertNotEqual(cleaner().clean(input, isFinalTranscript: false), "Hello, how are you?")
    }

    // MARK: Opt-in structural formatting threads through Config (MAK-20)

    func testStructuralRulesOffByDefaultThroughCleaner() {
        // The default Config leaves normalizeNumbers/currency/lists/markdown off,
        // so a cleaner built the usual way must NOT apply them.
        let c = cleaner()
        XCTAssertEqual(c.clean("five dollars", isFinalTranscript: false), "Five dollars")
        XCTAssertEqual(c.clean("bullet buy milk", isFinalTranscript: false), "Bullet buy milk")
    }

    func testStructuralRulesApplyWhenEnabledThroughConfig() {
        let c = TranscriptCleaner(config: .init(
            language: "en",
            customVocabularyEnabled: false,
            substitutions: [],
            smartFormattingEnabled: true,
            fillerRemovalEnabled: true,
            spokenPunctuationEnabled: true,
            normalizeNumbers: true,
            normalizeCurrency: true,
            spokenListsEnabled: true,
            basicMarkdownEnabled: true))
        XCTAssertEqual(c.clean("bullet spend five dollars", isFinalTranscript: false), "- Spend $5")
    }

    func testStructuralRulesRespectedByChainForm() async throws {
        // The composable chain must produce the same output as clean() with the
        // new flags on, so downstream stages stay in agreement.
        let c = TranscriptCleaner(config: .init(
            language: "en",
            customVocabularyEnabled: false,
            substitutions: [],
            smartFormattingEnabled: true,
            fillerRemovalEnabled: true,
            spokenPunctuationEnabled: true,
            normalizeNumbers: true,
            normalizeCurrency: true,
            spokenListsEnabled: true,
            basicMarkdownEnabled: true))
        let input = "heading tasks new line bullet spend five dollars"
        let direct = c.clean(input, isFinalTranscript: false)
        let chain = try await c.makeChain(isFinalTranscript: false)
            .process(input, context: .init(language: "en", targetBundleID: nil, isLiveChunk: true))
        XCTAssertEqual(direct, chain)
        XCTAssertEqual(direct, "# Tasks\n- Spend $5")
    }

    // MARK: clean() and the PostProcessorChain form agree

    func testCleanMatchesChain() async throws {
        let cases = [
            " hello world",
            "hello [music] world",
            "um i think comma therefore i am period done",
            "i use clod code daily",
            "Wrap up the report. translate this to English",
        ]
        let c = cleaner(vocab: [.init(from: "clod code", to: "Claude Code")])
        for (isFinal, _) in [(true, ()), (false, ())] {
            for text in cases {
                let direct = c.clean(text, isFinalTranscript: isFinal)
                let chain = try await c.makeChain(isFinalTranscript: isFinal)
                    .process(text, context: .init(language: "en", targetBundleID: nil, isLiveChunk: !isFinal))
                XCTAssertEqual(direct, chain, "chain disagreed with clean() on \"\(text)\" (final=\(isFinal))")
            }
        }
    }
}
