import XCTest
@testable import OpenWhispCore

/// The arm/offer decisions for the on-device TEXT translation path (Apple
/// Translation, macOS 15+): translate the session's FINAL transcript as text
/// when the user wants English but the active engine is ASR-only. Replaces the
/// retired dual-runtime approach (PR #219) — one ASR runtime, no audio tap,
/// and on failure the ORIGINAL text is kept, never lost.
///
/// Everything is asserted engine-by-engine over `allEngineIDs` so a future
/// engine can't silently fall in a gap between the engine-level translate path
/// and the text path.
final class TextTranslationPolicyTests: XCTestCase {

    private let allEngines = EngineCapabilities.allEngineIDs

    private func shouldRun(
        translate: Bool = true, language: String = "ru",
        engine: String = EngineCapabilities.parakeet, available: Bool = true
    ) -> Bool {
        TextTranslationPolicy.shouldTranslateFinal(
            translateToEnglish: translate, language: language,
            transcriptionEngine: engine, textTranslationAvailable: available)
    }

    // MARK: - shouldTranslateFinal

    /// The recovered combination: translate on + non-English + ASR-only engine
    /// + macOS 15 text translator → the text path runs. All three ASR-only
    /// engines, because the text path needs no audio tap.
    func testArmsForEveryASROnlyEngine() {
        for engine in [EngineCapabilities.parakeet,
                       EngineCapabilities.appleSpeech,
                       EngineCapabilities.speechAnalyzer] {
            XCTAssertTrue(shouldRun(engine: engine), "text path should arm for \(engine)")
        }
    }

    /// "auto" is not English — the speaker may be dictating any language, and
    /// the framework auto-detects the source (nil source in the configuration).
    func testArmsForAutoDetectLanguage() {
        XCTAssertTrue(shouldRun(language: "auto"))
    }

    func testDoesNotArmWhenTranslateIsOff() {
        XCTAssertFalse(shouldRun(translate: false))
    }

    /// English source → en→en is a no-op; regional tags count as English too
    /// (same base-code stripping as the Parakeet language gate).
    func testDoesNotArmForEnglishIncludingRegionalTags() {
        XCTAssertFalse(shouldRun(language: "en"))
        XCTAssertFalse(shouldRun(language: "en-US"))
        XCTAssertFalse(shouldRun(language: "en_GB"))
    }

    /// Engines that translate natively keep the engine-level path — the text
    /// path must never double-translate.
    func testDoesNotArmForNativeTranslateEngines() {
        XCTAssertFalse(shouldRun(engine: EngineCapabilities.whisperCpp))
        XCTAssertFalse(shouldRun(engine: EngineCapabilities.whisperKit))
    }

    /// macOS 14: the framework doesn't exist — the session behaves exactly as
    /// before this feature (transcript stays in the spoken language).
    func testDoesNotArmWhenTextTranslationUnavailable() {
        XCTAssertFalse(shouldRun(available: false))
    }

    /// THE COMPLEMENT CONTRACT: for every engine, exactly one translate path
    /// arms when the user wants English with a non-English language on
    /// macOS 15+ — the engine-level one (`effectiveTranslateToEnglish` via
    /// LanguageResolver) or the text path. Never both (double translation),
    /// never neither (the silent-drop bug this feature removes).
    func testExactlyOnePathArmsPerEngine() {
        for engine in allEngines {
            let engineLevel = LanguageResolver.effectiveTranslateToEnglish(
                translateToEnglish: true, transcriptionEngine: engine)
            let textPath = shouldRun(engine: engine)
            XCTAssertTrue(engineLevel != textPath,
                "engine \(engine): engine-level=\(engineLevel) text-path=\(textPath) — exactly one must arm")
        }
    }

    // MARK: - translationOffered (the shared UI gate)

    /// With the text path available (macOS 15+), EVERY engine offers
    /// "Translate to English" — natively or via the text path.
    func testEveryEngineOffersTranslateWhenTextPathAvailable() {
        for engine in allEngines {
            XCTAssertTrue(
                TextTranslationPolicy.translationOffered(
                    transcriptionEngine: engine, textTranslationAvailable: true),
                "\(engine) should offer translate on macOS 15+")
        }
    }

    /// Without it (macOS 14), the offer collapses to today's engine-level rule
    /// — ASR-only engines keep the dimmed/absent toggle.
    func testOfferMatchesEngineCapabilityWhenTextPathUnavailable() {
        for engine in allEngines {
            XCTAssertEqual(
                TextTranslationPolicy.translationOffered(
                    transcriptionEngine: engine, textTranslationAvailable: false),
                LanguageResolver.supportsTranslation(transcriptionEngine: engine),
                "\(engine): macOS 14 offer must equal the engine-level rule")
        }
    }

    // MARK: - effectiveTranslateToEnglish / outputLanguageForCleaning

    /// When the text path arms, translation IS in effect: refine prompts and
    /// the RefineOutputGuard expected script must see English output coming.
    func testEffectiveTranslateCountsTheTextPath() {
        XCTAssertTrue(TextTranslationPolicy.effectiveTranslateToEnglish(
            translateToEnglish: true, language: "ru",
            transcriptionEngine: EngineCapabilities.parakeet,
            textTranslationAvailable: true))
        XCTAssertEqual(TextTranslationPolicy.outputLanguageForCleaning(
            language: "ru", translateToEnglish: true,
            transcriptionEngine: EngineCapabilities.parakeet,
            textTranslationAvailable: true), "en")
    }

    /// Without the text path, both derivations are byte-identical to the
    /// LanguageResolver originals for every engine — macOS 14 behavior is
    /// unchanged by this feature.
    func testDerivationsMatchLanguageResolverWhenUnavailable() {
        for engine in allEngines {
            for translate in [true, false] {
                for language in ["ru", "en", "auto"] {
                    XCTAssertEqual(
                        TextTranslationPolicy.effectiveTranslateToEnglish(
                            translateToEnglish: translate, language: language,
                            transcriptionEngine: engine, textTranslationAvailable: false),
                        LanguageResolver.effectiveTranslateToEnglish(
                            translateToEnglish: translate, transcriptionEngine: engine),
                        "\(engine)/\(language)/translate=\(translate)")
                    XCTAssertEqual(
                        TextTranslationPolicy.outputLanguageForCleaning(
                            language: language, translateToEnglish: translate,
                            transcriptionEngine: engine, textTranslationAvailable: false),
                        LanguageResolver.outputLanguageForCleaning(
                            language: language, translateToEnglish: translate,
                            transcriptionEngine: engine),
                        "\(engine)/\(language)/translate=\(translate)")
                }
            }
        }
    }

    /// The engine-level translate on whisper engines is unaffected by the text
    /// path being available — no double counting, same "en" output language.
    func testNativeEnginesUnchangedByAvailability() {
        for engine in [EngineCapabilities.whisperCpp, EngineCapabilities.whisperKit] {
            XCTAssertTrue(TextTranslationPolicy.effectiveTranslateToEnglish(
                translateToEnglish: true, language: "ru",
                transcriptionEngine: engine, textTranslationAvailable: true))
            XCTAssertEqual(TextTranslationPolicy.outputLanguageForCleaning(
                language: "ru", translateToEnglish: true,
                transcriptionEngine: engine, textTranslationAvailable: true), "en")
        }
    }

    /// Spoken language passes through untouched (including "auto") when no
    /// translation is in effect.
    func testOutputLanguagePassthroughWhenNotTranslating() {
        XCTAssertEqual(TextTranslationPolicy.outputLanguageForCleaning(
            language: "ru", translateToEnglish: false,
            transcriptionEngine: EngineCapabilities.parakeet,
            textTranslationAvailable: true), "ru")
        XCTAssertEqual(TextTranslationPolicy.outputLanguageForCleaning(
            language: "auto", translateToEnglish: false,
            transcriptionEngine: EngineCapabilities.parakeet,
            textTranslationAvailable: true), "auto")
    }
}
