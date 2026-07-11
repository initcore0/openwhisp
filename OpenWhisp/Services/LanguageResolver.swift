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
enum LanguageResolver {
    /// The transcription engine's `appleSpeech` identifier (Apple's on-device
    /// recognizer). Kept for call sites that name it directly.
    static let appleSpeechEngine = "appleSpeech"

    /// Engines with no speech→English translation path; the single source of
    /// truth for the suppression rule (and the settings UI's translate gate).
    static let noTranslateEngines: Set<String> = [appleSpeechEngine, "parakeet"]

    static func supportsTranslation(transcriptionEngine: String) -> Bool {
        !noTranslateEngines.contains(transcriptionEngine)
    }

    /// Language string to pass to `engine.start(language:)` / the file engine.
    /// Returns the `translate-to-English` sentinel when translating (and the engine
    /// supports it), else the spoken language ("auto" = detect).
    static func engineLanguageSetting(
        language: String,
        translateToEnglish: Bool,
        transcriptionEngine: String
    ) -> String {
        if translateToEnglish && supportsTranslation(transcriptionEngine: transcriptionEngine) {
            return WhisperTask.translateToEnglishSetting
        }
        return language
    }

    /// Language of the OUTPUT text, used to pick formatting rules (spoken
    /// punctuation, capitalization): English when translating, else the spoken
    /// language.
    static func outputLanguageForCleaning(
        language: String,
        translateToEnglish: Bool,
        transcriptionEngine: String
    ) -> String {
        (translateToEnglish && supportsTranslation(transcriptionEngine: transcriptionEngine)) ? "en" : language
    }
}
