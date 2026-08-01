import Foundation

/// Should a dictation session translate its final TEXT — on-device, after the
/// ASR engine produced it?
///
/// **The text path owns translation for EVERY engine.** It started as a patch
/// for one gap in the capability matrix — a user who wanted "Translate to
/// English" on a fast streaming engine that cannot itself translate (Parakeet,
/// Apple Speech, SpeechAnalyzer — ASR-only, see `EngineCapabilities.translation`)
/// — and then, with the macOS floor at 15, became the single implementation:
/// every engine transcribes in the spoken language and the session's FINAL
/// transcript is translated as text (Apple's Translation framework) before it is
/// pasted. No audio tap and no second ASR runtime (the mistake of the retired
/// dual-runtime approach, PR #219), so it behaves identically everywhere.
///
/// The whisper family's native speech→English translate task is consequently
/// **retired (dormant)**: `LanguageResolver.engineLanguageSetting` no longer
/// emits the `WhisperTask.translateToEnglishSetting` sentinel, so nothing
/// reaches it. `WhisperTask` / `WhisperKitTaskMapper` still compile and are
/// still unit-tested — the mapping is correct, merely unreachable — which keeps
/// re-arming it a one-line change rather than an archaeology project. The old
/// "the two paths are exact complements" contract is therefore GONE: there is
/// one path, and asking the engine whether it could translate is no longer part
/// of the session decision.
///
/// This is the single, pure, unit-tested predicate that decides whether to arm
/// it — a capability question about the OS, never an engine-name check at the
/// call site (the rule this repo keeps re-learning):
///
///   1. the user asked to translate (`translateToEnglish`),
///   2. the OS has an on-device text translator (`textTranslationAvailable` —
///      macOS 15+, i.e. the whole supported floor; the flag stays as cheap
///      belt-and-braces rather than a real branch in the product),
///   3. the spoken language is NOT already English (en→en is a no-op; "auto"
///      qualifies — the speaker may be dictating a non-English language).
///
/// **The fallback is always "leave the text untranslated", never "lose text":**
/// when the translator fails or times out, the caller pastes the ORIGINAL
/// transcript unchanged.
public enum TextTranslationPolicy {

    /// Whether the text-translation path should run on this session's final
    /// transcript. Engine-independent: the engine's own translate capability is
    /// deliberately NOT consulted (see the type comment — the text path owns
    /// every engine now).
    public static func shouldTranslateFinal(
        translateToEnglish: Bool,
        language: String,
        transcriptionEngine _: String,
        textTranslationAvailable: Bool
    ) -> Bool {
        guard translateToEnglish, textTranslationAvailable else { return false }
        // English source → nothing to translate. "auto" is not English.
        return !isEnglish(language)
    }

    /// Whether the UI should OFFER "Translate to English" at all. Now purely an
    /// OS question — the text path covers every engine — so the offer is on
    /// wherever the on-device translator exists (macOS 15+, the whole supported
    /// floor). The single gate for every offer surface (menu bar, Dictation
    /// pane) so they can never disagree — a past bug was exactly those two
    /// surfaces drifting apart.
    public static func translationOffered(
        transcriptionEngine _: String,
        textTranslationAvailable: Bool
    ) -> Bool {
        textTranslationAvailable
    }

    /// The translate intent actually IN EFFECT for a session. With translation
    /// unified on the text path this is exactly `shouldTranslateFinal` — the
    /// engine-native disjunct is gone because that path is unreachable.
    /// Downstream consumers that describe the session's OUTPUT — refine prompts,
    /// `RefineOutputGuard.expectedCleanupScript` — must key on this, never on
    /// the raw stored toggle: when the text path does not arm (English source,
    /// or no translator), the transcript stays in the spoken language.
    public static func effectiveTranslateToEnglish(
        translateToEnglish: Bool,
        language: String,
        transcriptionEngine: String,
        textTranslationAvailable: Bool
    ) -> Bool {
        shouldTranslateFinal(
            translateToEnglish: translateToEnglish,
            language: language,
            transcriptionEngine: transcriptionEngine,
            textTranslationAvailable: textTranslationAvailable)
    }

    /// Language of the OUTPUT text for formatting rules: English when the
    /// translate path is in effect, else the spoken language.
    public static func outputLanguageForCleaning(
        language: String,
        translateToEnglish: Bool,
        transcriptionEngine: String,
        textTranslationAvailable: Bool
    ) -> String {
        effectiveTranslateToEnglish(
            translateToEnglish: translateToEnglish,
            language: language,
            transcriptionEngine: transcriptionEngine,
            textTranslationAvailable: textTranslationAvailable) ? "en" : language
    }

    /// Whether the language code names English (so translating is a no-op).
    /// Uses the same base-code stripping as the Parakeet language gate so
    /// regional tags ("en-US") count.
    private static func isEnglish(_ language: String) -> Bool {
        ParakeetLanguageHint.baseCode(from: language) == "en"
    }
}
