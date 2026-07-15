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

    func testOnlyWhisperCppBiasesVocabulary() {
        // whisper.cpp takes a free-text initial_prompt; nothing else does today.
        XCTAssertTrue(EngineCapabilities.supportsVocabularyBiasing(
            transcriptionEngine: EngineCapabilities.whisperCpp))

        for engine in [EngineCapabilities.whisperKit,
                       EngineCapabilities.parakeet,
                       EngineCapabilities.appleSpeech] {
            XCTAssertFalse(
                EngineCapabilities.supportsVocabularyBiasing(transcriptionEngine: engine),
                "\(engine) discards the prompt — the bias-terms UI must not be offered for it")
        }
    }

    /// The default engine is Parakeet. This test exists to make the cost of that
    /// gap explicit: if someone wires Parakeet biasing, this test fails and they
    /// update the capability — rather than the UI staying hidden by accident.
    func testDefaultEngineVocabularyGapIsDeliberate() {
        XCTAssertFalse(
            EngineCapabilities.supportsVocabularyBiasing(
                transcriptionEngine: EngineCapabilities.parakeet),
            "Parakeet is the default engine and cannot bias vocabulary (FluidAudio exposes no seam). If this now fails, biasing was wired — offer the UI again.")
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
