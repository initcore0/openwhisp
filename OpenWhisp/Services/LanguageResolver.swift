import Foundation

/// Pure language/translate resolution for a dictation session (Phase 2.5 core
/// extraction). Given the user's language + translate settings and the active
/// engine, it derives (a) the language string handed to the transcription engine
/// and (b) the language used for output-formatting rules. Both were inline
/// computed-property logic on the app-only `AppState`; extracting them here makes
/// the translate/auto/appleSpeech matrix `swift test`-able without AppKit and keeps
/// AppState and tests from drifting on the rules.
///
/// The one subtlety it encodes: **Apple Speech and Parakeet have no translate
/// concept** — Apple Speech always transcribes in the given locale, and Parakeet
/// is ASR-only (MAK-46) — so translation is suppressed for those engines on both
/// derivations.
///
/// **Scope note.** Since translation unified on the Apple Translation text path,
/// this type no longer decides whether a session translates — `TextTranslationPolicy`
/// does, for every engine. What survives here is the ENGINE-CAPABILITY vocabulary
/// (`supportsTranslation` / `noTranslateEngines`) plus the engine-native
/// derivations, which are still the honest answer to "could this engine translate
/// by itself?" and are used by capability tests and engine-facing code. Session
/// policy must go through `TextTranslationPolicy`.
public enum LanguageResolver {
    /// The transcription engine's `appleSpeech` identifier (Apple's on-device
    /// recognizer). Kept for call sites that name it directly.
    public static let appleSpeechEngine = "appleSpeech"

    /// Apple SpeechAnalyzer (macOS 26, MAK-59). Like the other Apple recognizer,
    /// it is ASR-only — it transcribes in the given locale and has no
    /// speech→English translate task.
    public static let speechAnalyzerEngine = "speechAnalyzer"

    /// Engines with no speech→English translation path; the single source of
    /// truth for the suppression rule (and the settings UI's translate gate).
    public static let noTranslateEngines: Set<String> = [appleSpeechEngine, "parakeet", speechAnalyzerEngine]

    public static func supportsTranslation(transcriptionEngine: String) -> Bool {
        !noTranslateEngines.contains(transcriptionEngine)
    }

    /// The translate intent that is actually IN EFFECT for a session: the stored
    /// toggle, gated on the engine being able to act on it. On no-translate
    /// engines the transcript stays in the spoken language, so every downstream
    /// consumer (refine prompts, the RefineOutputGuard expected script) must see
    /// `false` here — keying on the raw stored flag re-arms the exact
    /// silent-translation bug the guard exists to prevent (a stale `true` carried
    /// over from a whisper engine would make the guard EXPECT Latin output).
    public static func effectiveTranslateToEnglish(
        translateToEnglish: Bool,
        transcriptionEngine: String
    ) -> Bool {
        translateToEnglish && supportsTranslation(transcriptionEngine: transcriptionEngine)
    }

    /// Language string to pass to `engine.start(language:)` / the file engine:
    /// always the spoken language ("auto" = detect).
    ///
    /// **Translation is no longer an engine concern.** The on-device Apple
    /// Translation TEXT path (`TextTranslationPolicy`, macOS 15+ — the whole
    /// supported floor) now owns translation for EVERY engine, so this never
    /// emits the `WhisperTask.translateToEnglishSetting` sentinel and the
    /// whisper family's native speech→English translate task is unreachable
    /// (the mapping code stays, dormant). One translation implementation means
    /// one behaviour to reason about: the engine always transcribes in the
    /// spoken language and the final TEXT is translated afterwards.
    public static func engineLanguageSetting(
        language: String,
        translateToEnglish _: Bool,
        transcriptionEngine _: String
    ) -> String {
        language
    }

    /// Human-readable name for a spoken-language code, for menus/status rows
    /// (extracted from AppState under the MAK-32 ratchet). Unknown codes fall
    /// back to the uppercased code rather than failing.
    public static func displayName(for code: String) -> String {
        switch code {
        case "auto": return "Auto Detect"
        case "en": return "English"
        case "ru": return "Russian"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "ja": return "Japanese"
        case "zh": return "Chinese"
        case "ko": return "Korean"
        case "ar": return "Arabic"
        default: return code.uppercased()
        }
    }

    /// Language of the OUTPUT text, used to pick formatting rules (spoken
    /// punctuation, capitalization): English when translating, else the spoken
    /// language.
    public static func outputLanguageForCleaning(
        language: String,
        translateToEnglish: Bool,
        transcriptionEngine: String
    ) -> String {
        (translateToEnglish && supportsTranslation(transcriptionEngine: transcriptionEngine)) ? "en" : language
    }
}
