import Foundation

/// Variant-aware language gate for the Parakeet streaming engine (MAK-46).
///
/// The English streaming variants (Unified / EOU) are English-only: a user with a
/// FIXED non-English dictation language would get silent English-ish garbage, so
/// we refuse up front (the same "never silently translate/mangle" principle as
/// RefineOutputGuard) and point them at the multilingual variant.
///
/// The multilingual (Nemotron) variant accepts any language — a fixed code maps
/// to its prompt id, and unknown codes fall back to auto-detect inside FluidAudio
/// (see NemotronMultilingualStreamingConfig.promptId(forLanguage:)) — so it is
/// never refused. "auto" is always allowed.
///
/// Pure + core so the gate is unit-tested.
enum ParakeetLanguageGate {
    /// Returns a user-facing refusal message when the fixed language can't be
    /// honored by the given variant, nil when the session may proceed.
    ///
    /// - Parameters:
    ///   - languageSetting: the dictation language ("auto"/"en"/"ru"/"de-DE"…).
    ///   - multilingual: whether the active variant is the multilingual manager.
    static func refusalMessage(languageSetting: String, multilingual: Bool) -> String? {
        // Multilingual variants accept everything (unknowns → auto-detect).
        if multilingual { return nil }
        // Shared normalization with the hint mapper (ParakeetLanguageHint), so
        // "what language did the user fix" is decided in exactly one place:
        // nil = auto/empty/translate → allowed; "en" in any regional form → allowed.
        switch ParakeetLanguageHint.baseCode(from: languageSetting) {
        case nil, "en": return nil
        default:
            return "This Parakeet variant is English-only. Switch the dictation language to English or Auto, pick the Parakeet Multilingual variant, or choose another engine."
        }
    }
}
