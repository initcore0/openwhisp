import XCTest
@testable import OpenWhispCore

/// MAK-15 parity tests. These are the PROOF that wiring the real
/// `PostProcessorChain` (VocabularySubstitutor → SmartFormatter → AIPostProcessor)
/// preserves the exact behavior of the old hardcoded path:
///   - `AppState.postProcess` (local clean) is `TranscriptCleaner.clean`.
///   - the separate AI step in `AppState.completeFinalText` is the `AIPostProcessor`
///     stage: refine → non-final re-clean → fall back to the pre-AI text on
///     failure or empty LLM output.
///
/// The tests run representative (adversarial) transcripts through BOTH the old
/// path's logic and the new chain and assert identical output.
final class PostProcessorChainWiringTests: XCTestCase {

    // MARK: - Test doubles

    /// Records the exact text it was handed and returns a canned transform, so we
    /// can assert the chain calls the refiner with the RIGHT text at the RIGHT
    /// position (after the local stages, before nothing).
    final class SpyRefiner: AsyncTextRefiner, @unchecked Sendable {
        private(set) var receivedText: String?
        private(set) var callCount = 0
        let transform: @Sendable (String) -> String
        init(transform: @escaping @Sendable (String) -> String) { self.transform = transform }
        func refine(_ text: String, context: PostProcessContext) async throws -> String {
            receivedText = text
            callCount += 1
            return transform(text)
        }
    }

    /// Always throws — models a network/LLM failure.
    struct FailingRefiner: AsyncTextRefiner {
        struct Boom: Error {}
        func refine(_ text: String, context: PostProcessContext) async throws -> String {
            throw Boom()
        }
    }

    // MARK: - Fixtures

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

    private func ctx(final: Bool) -> PostProcessContext {
        .init(language: "en", targetBundleID: nil, isLiveChunk: !final)
    }

    /// The adversarial corpus: vocab substitution, spoken punctuation, filler,
    /// meta-instruction, numbers/currency-ish prose, markers, ignorable input.
    private let corpus: [String] = [
        " hello world",
        "hello [music] world",
        "um i think comma therefore i am period done",
        "i use clod code daily",
        "Wrap up the report. translate this to English",
        "new line uh so this is fine period",
        "[BLANK_AUDIO]",
        "   ",
        "call me at five dollars please",       // number/currency words in prose
        "meeting at ten thirty tomorrow",        // spoken-time (must NOT become a year)
    ]

    private let vocab: [Vocabulary.Substitution] = [.init(from: "clod code", to: "Claude Code")]

    // MARK: - 1) Local-only chain == clean() (no AI stage effect)

    /// `makeFullChain(refiner: nil)` must be byte-identical to `clean()` for every
    /// input and both final/non-final — a disabled AI session routes through the
    /// SAME assembly as the local path and changes nothing.
    func testFullChainWithNoRefinerMatchesClean() async throws {
        let c = cleaner(vocab: vocab)
        for isFinal in [true, false] {
            for text in corpus {
                let direct = c.clean(text, isFinalTranscript: isFinal)
                let chain = try await c.makeFullChain(isFinalTranscript: isFinal, refiner: nil)
                    .process(text, context: ctx(final: isFinal))
                XCTAssertEqual(direct, chain,
                    "full chain (nil refiner) disagreed with clean() on \"\(text)\" (final=\(isFinal))")
            }
        }
    }

    /// The local stages of the full chain must ALSO equal the local `makeChain`
    /// (the AI stage with a nil refiner is a pure pass-through).
    func testFullChainLocalStagesMatchMakeChain() async throws {
        let c = cleaner(vocab: vocab)
        for isFinal in [true, false] {
            for text in corpus {
                let localChain = try await c.makeChain(isFinalTranscript: isFinal)
                    .process(text, context: ctx(final: isFinal))
                let fullChain = try await c.makeFullChain(isFinalTranscript: isFinal, refiner: nil)
                    .process(text, context: ctx(final: isFinal))
                XCTAssertEqual(localChain, fullChain, "on \"\(text)\" (final=\(isFinal))")
            }
        }
    }

    // MARK: - 2) AI stage reproduces completeFinalText's whole-text logic

    /// Re-implements `AppState.completeFinalText`'s AI-step logic against a refiner,
    /// so we can assert the chain matches the OLD path byte-for-byte. This is the
    /// reference model: local clean (final) → [enhance? refine → non-final re-clean,
    /// with empty/failure fallback to the pre-AI text].
    private func oldPathFinal(
        _ raw: String,
        cleaner c: TranscriptCleaner,
        enhance: Bool,
        refine: (String) -> Result<String, Error>
    ) -> String {
        let finalText = c.clean(raw, isFinalTranscript: true)
        // completeFinalText inserts finalText directly and returns early when the
        // final is empty (the AI step never runs on empty), OR when enhancement is
        // off. Both collapse to "return finalText" for the produced text.
        guard enhance, !finalText.isEmpty else { return finalText }
        switch refine(finalText) {
        case .success(let processed):
            let cleaned = c.clean(processed, isFinalTranscript: false)
            return cleaned.isEmpty ? finalText : cleaned   // empty-LLM fallback
        case .failure:
            return finalText                                // failure fallback
        }
    }

    /// Success path: the chain's output equals the old path, for the whole corpus.
    /// The refiner uppercases so we can also confirm it actually ran (not a no-op).
    func testAIStageSuccessMatchesOldPath() async throws {
        let c = cleaner(vocab: vocab)
        let transform: @Sendable (String) -> String = { $0.uppercased() }
        for text in corpus {
            let spy = SpyRefiner(transform: transform)
            let chain = try await c.makeFullChain(isFinalTranscript: true, refiner: spy)
                .process(text, context: ctx(final: true))
            let expected = oldPathFinal(text, cleaner: c, enhance: true,
                                        refine: { .success(transform($0)) })
            XCTAssertEqual(chain, expected, "AI success mismatch on \"\(text)\"")
        }
    }

    /// Failure path: a throwing refiner must fall back to the pre-AI (locally
    /// cleaned final) text — exactly the `.failure` branch of completeFinalText.
    func testAIStageFailureFallsBackToPreAIText() async throws {
        let c = cleaner(vocab: vocab)
        for text in corpus {
            let chain = try await c.makeFullChain(isFinalTranscript: true, refiner: FailingRefiner())
                .process(text, context: ctx(final: true))
            let expected = oldPathFinal(text, cleaner: c, enhance: true,
                                        refine: { _ in .failure(FailingRefiner.Boom()) })
            XCTAssertEqual(chain, expected, "AI failure fallback mismatch on \"\(text)\"")
            // And that fallback IS the local-only result.
            let localOnly = c.clean(text, isFinalTranscript: true)
            XCTAssertEqual(chain, localOnly, "failure fallback should equal local clean on \"\(text)\"")
        }
    }

    /// Empty-LLM-output path: a refiner that returns whitespace/empty (which
    /// re-cleans to "") must fall back to the pre-AI text — the `guard
    /// !cleaned.isEmpty` branch of completeFinalText.
    func testAIStageEmptyOutputFallsBackToPreAIText() async throws {
        let c = cleaner(vocab: vocab)
        for text in corpus where !c.clean(text, isFinalTranscript: true).isEmpty {
            let spy = SpyRefiner(transform: { _ in "   " })  // re-cleans to ""
            let chain = try await c.makeFullChain(isFinalTranscript: true, refiner: spy)
                .process(text, context: ctx(final: true))
            let expected = c.clean(text, isFinalTranscript: true)  // pre-AI text
            XCTAssertEqual(chain, expected, "empty-LLM fallback mismatch on \"\(text)\"")
        }
    }

    // MARK: - 3) The refiner is called with the RIGHT text at the RIGHT position

    /// The AI stage runs LAST: the refiner receives the fully locally-cleaned text
    /// (vocab-substituted, formatted, meta-stripped) — not the raw transcript.
    func testRefinerReceivesLocallyCleanedFinalText() async throws {
        let c = cleaner(vocab: vocab)
        let raw = "um i use clod code daily. translate this to English"
        let spy = SpyRefiner(transform: { $0 })  // identity
        _ = try await c.makeFullChain(isFinalTranscript: true, refiner: spy)
            .process(raw, context: ctx(final: true))
        let expectedInput = c.clean(raw, isFinalTranscript: true)
        XCTAssertEqual(spy.receivedText, expectedInput)
        // Sanity: the cleaned input is meaningfully different from the raw — vocab
        // applied, filler removed, meta stripped — so "received cleaned text" is a
        // real assertion, not trivially true.
        XCTAssertEqual(expectedInput, "I use Claude Code daily.")
        XCTAssertEqual(spy.callCount, 1)
    }

    /// The AI stage must NOT run on an empty final transcript (an ignorable input
    /// that the local stages collapse to ""), matching the app never calling the
    /// LLM on empty text.
    func testRefinerNotCalledOnEmptyFinal() async throws {
        let c = cleaner()
        let spy = SpyRefiner(transform: { $0.uppercased() })
        let out = try await c.makeFullChain(isFinalTranscript: true, refiner: spy)
            .process("[BLANK_AUDIO]", context: ctx(final: true))
        XCTAssertEqual(out, "")
        XCTAssertEqual(spy.callCount, 0, "LLM must not run on empty final text")
        XCTAssertNil(spy.receivedText)
    }

    // MARK: - 4) AIPostProcessor unit behavior (in isolation)

    func testAIPostProcessorPassThroughWhenRefinerNil() async throws {
        let stage = AIPostProcessor(refiner: nil)
        let out = try await stage.process("keep me", context: ctx(final: true))
        XCTAssertEqual(out, "keep me")
    }

    func testAIPostProcessorReclansOutput() async throws {
        // reclean uppercases-independent: here reclean trims to prove it is applied.
        let spy = SpyRefiner(transform: { "  \($0) padded  " })
        let stage = AIPostProcessor(refiner: spy, reclean: { $0.trimmingCharacters(in: .whitespaces) })
        let out = try await stage.process("x", context: ctx(final: true))
        XCTAssertEqual(out, "x padded")
    }

    func testAIPostProcessorNeverThrowsOnRefinerFailure() async throws {
        let stage = AIPostProcessor(refiner: FailingRefiner(), reclean: { $0 })
        // Must not throw — a refiner failure is an internal fallback, not a
        // chain-aborting error.
        let out = try await stage.process("safe", context: ctx(final: true))
        XCTAssertEqual(out, "safe")
    }
}
