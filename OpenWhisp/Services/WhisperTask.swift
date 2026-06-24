import Foundation

/// Resolves the user's Language setting into the two parameters whisper actually
/// needs: the source language code and whether to translate to English.
///
/// The Language picker's "English — Whisper translate to English" is special:
/// whisper's `--translate` ALWAYS targets English and needs the SOURCE language
/// auto-detected, so "en" must map to (language: "auto", translate: true), NOT
/// (language: "en"), which would tell whisper the source is English and skip
/// translation. Every other choice ("auto", "ru", …) transcribes in that language
/// with no translation.
///
/// Pure Foundation, so it lives in OpenWhispCore and is unit-tested — this is the
/// branch that was wrong (the app sent `-l en` and never translated).
enum WhisperTask {
    struct Resolved: Equatable {
        /// Source language code to pass to whisper ("auto" or a specific code).
        var language: String
        /// Whether to pass --translate (CLI) / translate=true (server).
        var translate: Bool
    }

    static func resolve(languageSetting: String) -> Resolved {
        if languageSetting == "en" {
            return Resolved(language: "auto", translate: true)
        }
        return Resolved(language: languageSetting.isEmpty ? "auto" : languageSetting, translate: false)
    }
}
