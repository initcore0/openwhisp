import Foundation

/// Should a dictation session translate its final TEXT — on-device, after the
/// ASR engine produced it?
///
/// The text path exists for one gap in the capability matrix: a user who wants
/// "Translate to English" while dictating with a fast streaming engine that
/// cannot itself translate (Parakeet, Apple Speech, SpeechAnalyzer — ASR-only,
/// see `EngineCapabilities.translation`). Historically that combination silently
/// gated translation OFF (`LanguageResolver.effectiveTranslateToEnglish` returns
/// false there). The text path recovers it WITHOUT a second ASR runtime (the
/// mistake of the retired dual-runtime approach, PR #219): the engine keeps
/// driving the live preview in the spoken language, and the session's FINAL
/// transcript is translated as text (Apple's Translation framework, macOS 15+)
/// before it is pasted. No audio tap, so it works identically for every
/// streaming engine.
///
/// This is the single, pure, unit-tested predicate that decides whether to arm
/// that path — a capability question, never an engine-name check at the call
/// site (the rule this repo keeps re-learning):
///
///   1. the user asked to translate (`translateToEnglish`),
///   2. the OS has an on-device text translator (`textTranslationAvailable` —
///      macOS 15+; the app itself still runs on macOS 14, where the feature is
///      simply unavailable),
///   3. the spoken language is NOT already English (en→en is a no-op; "auto"
///      qualifies — the speaker may be dictating a non-English language),
///   4. the active engine CANNOT translate natively — otherwise the normal
///      engine-level translate path already owns it. Deliberately the same
///      predicate the engine-level path arms on
///      (`LanguageResolver.supportsTranslation`), so the two paths are exact
///      complements: no session ever translates twice or falls in the gap.
///
/// **The fallback is always "leave the text untranslated", never "lose text":**
/// when the translator fails or times out, the caller pastes the ORIGINAL
/// transcript unchanged.
public enum TextTranslationPolicy {

    /// Whether the text-translation path should run on this session's final
    /// transcript.
    public static func shouldTranslateFinal(
        translateToEnglish: Bool,
        language: String,
        transcriptionEngine: String,
        textTranslationAvailable: Bool
    ) -> Bool {
        guard translateToEnglish, textTranslationAvailable else { return false }
        // English source → nothing to translate. "auto" is not English.
        if isEnglish(language) { return false }
        // The engine translates itself → the engine-level path owns it.
        if LanguageResolver.supportsTranslation(transcriptionEngine: transcriptionEngine) {
            return false
        }
        return true
    }

    /// Whether the UI should OFFER "Translate to English" for this engine at
    /// all: either the engine translates natively (whisper family) or the text
    /// path can cover it (macOS 15+). The single gate for every offer surface
    /// (menu bar, Dictation pane) so they can never disagree — a past bug was
    /// exactly those two surfaces drifting apart.
    public static func translationOffered(
        transcriptionEngine: String,
        textTranslationAvailable: Bool
    ) -> Bool {
        LanguageResolver.supportsTranslation(transcriptionEngine: transcriptionEngine)
            || textTranslationAvailable
    }

    /// The translate intent actually IN EFFECT for a session, counting BOTH
    /// paths: the engine-level translate (whisper family) and the text path.
    /// Downstream consumers that describe the session's OUTPUT — refine prompts,
    /// `RefineOutputGuard.expectedCleanupScript` — must key on this, not on
    /// `LanguageResolver.effectiveTranslateToEnglish` alone: when the text path
    /// arms, the final transcript the refine layer sees IS English.
    public static func effectiveTranslateToEnglish(
        translateToEnglish: Bool,
        language: String,
        transcriptionEngine: String,
        textTranslationAvailable: Bool
    ) -> Bool {
        LanguageResolver.effectiveTranslateToEnglish(
            translateToEnglish: translateToEnglish,
            transcriptionEngine: transcriptionEngine)
            || shouldTranslateFinal(
                translateToEnglish: translateToEnglish,
                language: language,
                transcriptionEngine: transcriptionEngine,
                textTranslationAvailable: textTranslationAvailable)
    }

    /// Language of the OUTPUT text for formatting rules — the text-path-aware
    /// superset of `LanguageResolver.outputLanguageForCleaning`: English when
    /// either translate path is in effect, else the spoken language.
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
