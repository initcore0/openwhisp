import Foundation

/// The Parakeet streaming variants OpenWhisp ships are English-only (see
/// ParakeetCatalog). A user with a FIXED non-English dictation language would
/// get silent English-ish garbage — refuse up front instead (the same "never
/// silently translate/mangle" principle as RefineOutputGuard).
///
/// "auto" is allowed: it means "whatever I speak", and for the spike we accept
/// that non-English speech through an English model degrades — the Settings row
/// says English-only. Pure + core so the gate is unit-tested.
enum ParakeetLanguageGate {
    /// Returns a user-facing refusal message when the fixed language can't be
    /// honored, nil when the session may proceed.
    static func refusalMessage(languageSetting: String) -> String? {
        let setting = languageSetting.trimmingCharacters(in: .whitespaces).lowercased()
        if setting.isEmpty || setting == "auto" { return nil }
        if setting == "en" || setting.hasPrefix("en-") || setting.hasPrefix("en_") { return nil }
        return "The Parakeet engine is English-only. Switch the dictation language to English or Auto, or choose another engine."
    }
}
