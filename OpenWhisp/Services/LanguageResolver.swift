import Foundation

/// Pure language/translate resolution for a dictation session (Phase 2.5 core
/// extraction). Given the user's language + translate settings and the active
/// engine, it derives (a) the language string handed to the transcription engine
/// and (b) the language used for output-formatting rules. Both were inline
/// computed-property logic on the app-only `AppState`; extracting them here makes
/// the translate/auto/appleSpeech matrix `swift test`-able without AppKit and keeps
/// AppState and tests from drifting on the rules.
///
/// The one subtlety it encodes: **Apple Speech has no translate concept** — it
/// always transcribes in the given locale — so translation is suppressed for that
/// engine on both derivations.
enum LanguageResolver {
    /// The transcription engine's `appleSpeech` identifier (Apple's on-device
    /// recognizer). Kept here as the single source of truth for the suppression rule.
    static let appleSpeechEngine = "appleSpeech"

    /// Language string to pass to `engine.start(language:)` / the file engine.
    /// Returns the `translate-to-English` sentinel when translating (and the engine
    /// supports it), else the spoken language ("auto" = detect).
    static func engineLanguageSetting(
        language: String,
        translateToEnglish: Bool,
        transcriptionEngine: String
    ) -> String {
        if translateToEnglish && transcriptionEngine != appleSpeechEngine {
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
        (translateToEnglish && transcriptionEngine != appleSpeechEngine) ? "en" : language
    }
}
