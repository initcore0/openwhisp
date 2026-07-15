import XCTest
@testable import OpenWhispCore

/// Guards the engine-capability contract (MAK-70). The bug this prevents is not
/// "the resolver returns the wrong answer" — it's "a call site never asked".
/// #175 shipped with a correct resolver and a UI that bypassed it, so these tests
/// pin the *rule* across every engine rather than spot-checking one.
final class EngineCapabilitiesTests: XCTestCase {

    /// Every engine the app can be set to. If you add an engine (e.g. MAK-59's
    /// Apple SpeechAnalyzer), add it here — the tests below then force you to
    /// decide its capabilities rather than letting it default to a silent no-op.
    private let allEngines = [
        EngineCapabilities.whisperCpp,
        EngineCapabilities.whisperKit,
        EngineCapabilities.parakeet,
        EngineCapabilities.appleSpeech,
    ]

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

        // Both have real but unwired seams (MAK-69): WhisperKit's promptTokens
        // needs the tokenizer; Apple Speech has contextualStrings.
        for engine in [EngineCapabilities.whisperKit, EngineCapabilities.appleSpeech] {
            XCTAssertEqual(
                EngineCapabilities.vocabularySupport(transcriptionEngine: engine), .none,
                "\(engine) discards the prompt — the bias-terms UI must not be offered for it")
        }
    }

    /// The bias-terms field is offered iff terms reach the engine *somewhere*.
    /// Parakeet now qualifies on the strength of its batch path alone — the UI
    /// says so explicitly rather than implying live dictation is covered.
    func testBiasTermsUIGateFollowsAnyPathSupport() {
        XCTAssertTrue(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.parakeet))
        XCTAssertTrue(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.whisperCpp))
        XCTAssertFalse(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.whisperKit))
        XCTAssertFalse(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.appleSpeech))
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
    }
}
