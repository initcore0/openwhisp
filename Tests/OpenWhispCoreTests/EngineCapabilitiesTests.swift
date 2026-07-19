import XCTest
@testable import OpenWhispCore

/// Guards the engine-capability contract (MAK-70). The bug this prevents is not
/// "the resolver returns the wrong answer" — it's "a call site never asked".
/// #175 shipped with a correct resolver and a UI that bypassed it, so these tests
/// pin the *rule* across every engine rather than spot-checking one.
final class EngineCapabilitiesTests: XCTestCase {

    /// Every engine the app can be set to. Sourced from `allEngineIDs` (the same
    /// list the pipeline iterates), so adding an engine there is what makes the
    /// contract test below force a decision for it.
    private let allEngines = EngineCapabilities.allEngineIDs

    /// THE CONTRACT (MAK-69 acceptance centerpiece): for every engine × capability,
    /// a setting is offered iff it is honored. This iterates ALL engines, so adding
    /// engine #6 to `allEngineIDs` fails here until its `Capabilities` record is
    /// declared with a deliberate value for each field. The per-engine expectations
    /// are the honest matrix; the loop asserts the *reader* answers agree with the
    /// declared record (the bug this prevents is a call site asking a reader that
    /// silently diverged from the declaration).
    func testEveryEngineDeclaresEveryCapability() {
        // The shipped matrix, engine → (translate, vocab, streamPartials, wordTS).
        // Kept explicit (not derived) so a wrong declaration is caught by a human-
        // readable expectation, not by re-deriving the same possibly-wrong rule.
        let expected: [String: (translate: Bool,
                                vocab: EngineCapabilities.VocabularySupport,
                                partials: Bool,
                                wordTS: Bool)] = [
            EngineCapabilities.whisperCpp:     (true,  .all,       false, true),
            EngineCapabilities.whisperKit:     (true,  .all,       true,  true),
            EngineCapabilities.parakeet:       (false, .batchOnly, true,  true),
            EngineCapabilities.appleSpeech:    (false, .all,       true,  false),
            EngineCapabilities.speechAnalyzer: (false, .all,       true,  false),
        ]

        for engine in allEngines {
            guard let want = expected[engine] else {
                XCTFail("Engine '\(engine)' is in allEngineIDs but has no expected capability row — declare it (translate/vocab/partials/timestamps) so it can't ship as a silent no-op")
                continue
            }
            let cap = EngineCapabilities.capabilities(for: engine)

            // The record is internally consistent (id round-trips, has a name).
            XCTAssertEqual(cap.id, engine)
            XCTAssertFalse(cap.displayName.isEmpty, "\(engine) needs a display name")

            // Offered-iff-honored, field by field, via BOTH the record and the
            // free-function readers the call sites actually use.
            XCTAssertEqual(cap.translation, want.translate, "\(engine) translation")
            XCTAssertEqual(
                LanguageResolver.supportsTranslation(transcriptionEngine: engine),
                want.translate, "\(engine) translate rule must match the capability record")

            XCTAssertEqual(cap.vocabulary, want.vocab, "\(engine) vocabulary")
            XCTAssertEqual(
                EngineCapabilities.vocabularySupport(transcriptionEngine: engine),
                want.vocab, "\(engine) vocabularySupport reader")
            XCTAssertEqual(
                EngineCapabilities.supportsVocabularyBiasing(transcriptionEngine: engine),
                want.vocab.isSupportedAnywhere, "\(engine) bias-terms UI gate")
            XCTAssertEqual(
                EngineCapabilities.honorsStreamingVocabulary(transcriptionEngine: engine),
                want.vocab.honorsStreaming,
                "\(engine): AppState hands the streaming engine a prompt iff this is true — it must equal .honorsStreaming")

            XCTAssertEqual(cap.streamingPartials, want.partials, "\(engine) streaming partials")
            XCTAssertEqual(cap.wordTimestamps, want.wordTS, "\(engine) word timestamps")
        }
    }

    /// The streaming-vocabulary gate (which decides whether AppState hands the
    /// live engine a bias prompt) must NEVER be true for an engine whose vocab is
    /// batch-only — that would re-arm the silent-no-op bug on the live path.
    func testStreamingVocabularyGateNeverExceedsBatch() {
        for engine in allEngines {
            let v = EngineCapabilities.vocabularySupport(transcriptionEngine: engine)
            if v == .batchOnly || v == .none {
                XCTAssertFalse(
                    EngineCapabilities.honorsStreamingVocabulary(transcriptionEngine: engine),
                    "\(engine) is \(v) — it must not claim to honor streaming vocabulary")
            }
        }
    }

    func testVocabularySupportPerEngine() {
        // whisper.cpp takes a free-text initial_prompt on both paths.
        XCTAssertEqual(
            EngineCapabilities.vocabularySupport(transcriptionEngine: EngineCapabilities.whisperCpp),
            .all)

        // Parakeet biases via FluidAudio's CTC-WS pass, which needs the full
        // log-prob matrix over complete audio — batch only (MAK-71).
        XCTAssertEqual(
            EngineCapabilities.vocabularySupport(transcriptionEngine: EngineCapabilities.parakeet),
            .batchOnly)

        // MAK-69 wired WhisperKit's promptTokens (tokenizer) and Apple Speech's
        // contextualStrings; MAK-84 wired SpeechAnalyzer's AnalysisContext
        // contextualStrings on both paths — so all three are .all.
        XCTAssertEqual(
            EngineCapabilities.vocabularySupport(transcriptionEngine: EngineCapabilities.whisperKit), .all)
        XCTAssertEqual(
            EngineCapabilities.vocabularySupport(transcriptionEngine: EngineCapabilities.appleSpeech), .all)
        XCTAssertEqual(
            EngineCapabilities.vocabularySupport(transcriptionEngine: EngineCapabilities.speechAnalyzer), .all,
            "SpeechAnalyzer biases via AnalysisContext.contextualStrings on both paths (MAK-84) — the bias-terms UI is offered for it")
    }

    /// The bias-terms field is offered iff terms reach the engine *somewhere*.
    /// Parakeet now qualifies on the strength of its batch path alone — the UI
    /// says so explicitly rather than implying live dictation is covered.
    func testBiasTermsUIGateFollowsAnyPathSupport() {
        XCTAssertTrue(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.parakeet))
        XCTAssertTrue(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.whisperCpp))
        // MAK-69 wired these two, so the bias-terms UI is now offered for them.
        XCTAssertTrue(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.whisperKit))
        XCTAssertTrue(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.appleSpeech))
        // MAK-84 wired it.
        XCTAssertTrue(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.speechAnalyzer))
    }

    /// `.batchOnly` must never quietly read as "fully supported". This is the
    /// distinction that keeps the batch/streaming split honest — if someone
    /// collapses VocabularySupport back into a Bool, this fails.
    func testBatchOnlyIsNotTheSameAsFullSupport() {
        XCTAssertNotEqual(
            EngineCapabilities.vocabularySupport(transcriptionEngine: EngineCapabilities.parakeet),
            .all,
            "Parakeet does NOT bias live dictation — claiming .all would re-create the silent-no-op bug")
        XCTAssertTrue(EngineCapabilities.VocabularySupport.batchOnly.isSupportedAnywhere)
        XCTAssertFalse(EngineCapabilities.VocabularySupport.none.isSupportedAnywhere)
    }

    /// An unknown engine id must not silently claim capabilities it can't back.
    func testUnknownEngineClaimsNothing() {
        XCTAssertFalse(EngineCapabilities.supportsVocabularyBiasing(transcriptionEngine: "someFutureEngine"))
    }

    func testDisplayNamesAreHumanReadable() {
        // The UI explains gaps by name ("Parakeet can't be steered…"), so a raw
        // identifier leaking into a sentence is a user-visible defect.
        XCTAssertEqual(EngineCapabilities.displayName(transcriptionEngine: EngineCapabilities.parakeet), "Parakeet")
        XCTAssertEqual(EngineCapabilities.displayName(transcriptionEngine: EngineCapabilities.whisperKit), "WhisperKit")
        XCTAssertEqual(EngineCapabilities.displayName(transcriptionEngine: EngineCapabilities.whisperCpp), "whisper.cpp")
        XCTAssertEqual(EngineCapabilities.displayName(transcriptionEngine: EngineCapabilities.appleSpeech), "Apple Speech")
        XCTAssertEqual(EngineCapabilities.displayName(transcriptionEngine: EngineCapabilities.speechAnalyzer), "Apple SpeechAnalyzer")

        for engine in allEngines {
            XCTAssertFalse(
                EngineCapabilities.displayName(transcriptionEngine: engine).isEmpty,
                "\(engine) needs a display name for capability-gap copy")
        }
    }

    /// Cross-check against the translate rule: both capabilities are keyed on the
    /// same engine identifiers, so a typo'd id in one set would silently mean
    /// "capable" here. Parakeet and Apple Speech must be known to BOTH rules.
    func testCapabilityRulesAgreeOnEngineIdentifiers() {
        for engine in LanguageResolver.noTranslateEngines {
            XCTAssertTrue(
                allEngines.contains(engine),
                "\(engine) is named in the translate rule but unknown to EngineCapabilities — the two rules have drifted apart")
        }
        XCTAssertEqual(EngineCapabilities.appleSpeech, LanguageResolver.appleSpeechEngine)
        // MAK-59: the SpeechAnalyzer id must be identical across all three
        // sources of truth, or a switch keyed on one would silently miss it.
        XCTAssertEqual(EngineCapabilities.speechAnalyzer, LanguageResolver.speechAnalyzerEngine)
        XCTAssertEqual(EngineCapabilities.speechAnalyzer, SpeechAnalyzerAvailability.engineID)
    }
}
