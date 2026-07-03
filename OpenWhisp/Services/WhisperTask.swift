import Foundation

/// Resolves the engine-facing language setting into the two parameters whisper
/// actually needs: the source language code and whether to translate to English.
///
/// Translate-to-English is its own setting (`translateToEnglish`, split from the
/// old "English — Whisper translate to English" picker overload). AppState maps
/// it to the `translateToEnglishSetting` sentinel at the engine boundary:
/// whisper's `--translate` ALWAYS targets English and needs the SOURCE language
/// auto-detected, so the sentinel maps to (language: "auto", translate: true).
/// Every plain language choice ("auto", "en", "ru", …) transcribes in that
/// language with no translation — "en" now honestly means "the speech is
/// English" (the migration rewrote stored old-overload values).
///
/// Pure Foundation, so it lives in OpenWhispCore and is unit-tested — this is the
/// branch that was wrong (the app sent `-l en` and never translated).
enum WhisperTask {
    /// Engine-facing sentinel for "translate whatever is spoken to English".
    /// Deliberately not a language code, so it can never collide with one.
    static let translateToEnglishSetting = "translate-en"

    struct Resolved: Equatable {
        /// Source language code to pass to whisper ("auto" or a specific code).
        var language: String
        /// Whether to pass --translate (CLI) / translate=true (server).
        var translate: Bool
    }

    static func resolve(languageSetting: String) -> Resolved {
        if languageSetting == translateToEnglishSetting {
            return Resolved(language: "auto", translate: true)
        }
        return Resolved(language: languageSetting.isEmpty ? "auto" : languageSetting, translate: false)
    }
}
