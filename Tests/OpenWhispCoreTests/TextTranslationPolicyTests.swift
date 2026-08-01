import XCTest
@testable import OpenWhispCore

/// The arm/offer decisions for the on-device TEXT translation path (Apple
/// Translation, macOS 15+), which now owns translation for EVERY engine: the
/// session's FINAL transcript is translated as text after the engine produced
/// it. Replaces the retired dual-runtime approach (PR #219) — one ASR runtime,
/// no audio tap, and on failure the ORIGINAL text is kept, never lost.
///
/// The old "exactly one of {engine-native, text} arms" complement contract is
/// GONE: engine-native translate is retired (dormant, see `WhisperTask`), so the
/// text path is the only path. These tests pin the replacement contract —
/// **engine-independence** — by asserting engine-by-engine over `allEngineIDs`
/// that the decision does not vary with the engine at all.
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

    /// THE CONTRACT: translate on + non-English + a text translator → the text
    /// path runs, for EVERY engine including the whisper family that could once
    /// translate natively. No audio tap is involved, so the engine is irrelevant.
    func testArmsForEveryEngine() {
        for engine in allEngines {
            XCTAssertTrue(shouldRun(engine: engine), "text path should arm for \(engine)")
        }
    }

    /// Engine-independence, stated directly: across the whole input cross
    /// product the answer never varies with the engine. This is what replaces
    /// the retired "exact complements" contract — a new engine cannot fall in a
    /// gap because there is no per-engine branch left to fall through.
    func testDecisionIsIndependentOfEngine() {
        for translate in [true, false] {
            for language in ["ru", "en", "en-US", "auto", "ja"] {
                for available in [true, false] {
                    let expected = shouldRun(
                        translate: translate, language: language,
                        engine: EngineCapabilities.parakeet, available: available)
                    for engine in allEngines {
                        XCTAssertEqual(
                            shouldRun(translate: translate, language: language,
                                      engine: engine, available: available),
                            expected,
                            "\(engine)/\(language)/translate=\(translate)/available=\(available) must match every other engine")
                    }
                }
            }
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

    /// The whisper family now goes through the TEXT path like everyone else —
    /// its native translate task is retired. Previously these two asserted the
    /// opposite (the engine-level path owned them).
    func testArmsForWhisperFamilyToo() {
        XCTAssertTrue(shouldRun(engine: EngineCapabilities.whisperCpp))
        XCTAssertTrue(shouldRun(engine: EngineCapabilities.whisperKit))
    }

    /// No on-device translator → nothing translates, for every engine. Below the
    /// macOS 15 floor this is unreachable in the shipping app; it stays pinned
    /// as the belt-and-braces degradation (transcript kept in the spoken
    /// language, never dropped).
    func testDoesNotArmWhenTextTranslationUnavailable() {
        for engine in allEngines {
            XCTAssertFalse(shouldRun(engine: engine, available: false),
                "\(engine) must not arm without a text translator")
        }
    }

    /// The engine-native translate task must be UNREACHABLE: the resolver never
    /// emits the whisper sentinel, whatever the engine or translate flag. This
    /// is the other half of "the text path owns translation" — if this
    /// regresses, whisper sessions would translate twice.
    func testEngineSentinelIsNeverEmitted() {
        for engine in allEngines {
            for translate in [true, false] {
                for language in ["ru", "en", "auto"] {
                    let setting = LanguageResolver.engineLanguageSetting(
                        language: language, translateToEnglish: translate,
                        transcriptionEngine: engine)
                    XCTAssertEqual(setting, language,
                        "\(engine)/\(language)/translate=\(translate): engine must get the plain language")
                    XCTAssertNotEqual(setting, WhisperTask.translateToEnglishSetting,
                        "\(engine): the engine-native translate sentinel is retired")
                }
            }
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

    /// Without a text translator NO engine offers it — including the whisper
    /// family, whose native task is retired. (Unreachable at the macOS 15 floor;
    /// pinned so the offer gate can't quietly resurrect engine capability.)
    func testNoEngineOffersTranslateWithoutTextPath() {
        for engine in allEngines {
            XCTAssertFalse(
                TextTranslationPolicy.translationOffered(
                    transcriptionEngine: engine, textTranslationAvailable: false),
                "\(engine): the offer is an OS question now, not an engine one")
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

    /// Without a text translator NOTHING translates: both derivations report
    /// "no translation in effect" and pass the spoken language through, for
    /// every engine. The whisper family no longer gets an exemption here — that
    /// is precisely the retired engine-native path.
    func testDerivationsReportNoTranslationWhenUnavailable() {
        for engine in allEngines {
            for translate in [true, false] {
                for language in ["ru", "en", "auto"] {
                    XCTAssertFalse(
                        TextTranslationPolicy.effectiveTranslateToEnglish(
                            translateToEnglish: translate, language: language,
                            transcriptionEngine: engine, textTranslationAvailable: false),
                        "\(engine)/\(language)/translate=\(translate)")
                    XCTAssertEqual(
                        TextTranslationPolicy.outputLanguageForCleaning(
                            language: language, translateToEnglish: translate,
                            transcriptionEngine: engine, textTranslationAvailable: false),
                        language,
                        "\(engine)/\(language)/translate=\(translate)")
                }
            }
        }
    }

    /// With the text path available, the whisper family behaves like every other
    /// engine: translation in effect and English output language — reached via
    /// the TEXT path, not the engine's own task.
    func testWhisperFamilyTranslatesViaTextPath() {
        for engine in [EngineCapabilities.whisperCpp, EngineCapabilities.whisperKit] {
            XCTAssertTrue(TextTranslationPolicy.effectiveTranslateToEnglish(
                translateToEnglish: true, language: "ru",
                transcriptionEngine: engine, textTranslationAvailable: true))
            XCTAssertEqual(TextTranslationPolicy.outputLanguageForCleaning(
                language: "ru", translateToEnglish: true,
                transcriptionEngine: engine, textTranslationAvailable: true), "en")
            // ...and the engine itself is told the plain spoken language.
            XCTAssertEqual(
                LanguageResolver.engineLanguageSetting(
                    language: "ru", translateToEnglish: true, transcriptionEngine: engine),
                "ru")
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
