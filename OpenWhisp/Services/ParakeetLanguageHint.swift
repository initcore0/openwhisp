import Foundation

/// Maps OpenWhisp's engine-facing language setting to the language hint the
/// FluidAudio batch (TDT v3) and multilingual-streaming Parakeet managers accept.
///
/// Two shapes, because the two FluidAudio managers take different code forms:
///   - `batchLanguageCode` → a bare 2-letter ISO code ("ru", "de") or nil for
///     auto. FluidAudio's batch `transcribe(language:)` wants a `Language`
///     rawValue (the `TokenLanguageFilter.Language` enum), which is 2-letter;
///     an unknown / regional code degrades to nil (auto) rather than erroring.
///   - `multilingualLanguageCode` → the manager's own "en-US"/"auto" style code;
///     unknown codes are passed through and the manager falls back to its
///     `default_prompt_id` ("auto"), so we never need to gate here.
///
/// Pure + Foundation-only so it lives in OpenWhispCore and is unit-tested; the
/// FluidAudio managers themselves are behind the app-glob `#if PARAKEET`.
enum ParakeetLanguageHint {
    /// The whisper translate-to-English sentinel and the "auto"/empty settings
    /// all mean "let the model decide" for Parakeet (which is ASR-only and never
    /// translates — see LanguageResolver). Returns nil (auto) for those.
    private static func normalizedSetting(_ setting: String) -> String? {
        let s = setting.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s == "auto" { return nil }
        // Guard against the translate sentinel leaking in (LanguageResolver already
        // suppresses translate for parakeet, but be defensive at this seam).
        if s == WhisperTask.translateToEnglishSetting.lowercased() { return nil }
        return s
    }

    /// Lowercased base language code from a setting, or nil when the setting
    /// means "let the model decide" (auto/empty/translate sentinel).
    /// "de-DE" → "de", "en_US" → "en". THE single normalization for parakeet
    /// language decisions — ParakeetLanguageGate keys its English-only refusal
    /// on this too, so the gate and the hints can't drift.
    static func baseCode(from setting: String) -> String? {
        guard let s = normalizedSetting(setting) else { return nil }
        // Split "de-de"/"de_de" → "de".
        let dashed = s.replacingOccurrences(of: "_", with: "-")
        let base = dashed.split(separator: "-", maxSplits: 1).first.map(String.init) ?? dashed
        return base.isEmpty ? nil : base
    }

    /// Bare 2-letter code for the batch engine's `Language(rawValue:)`, or nil for
    /// auto (the engine silently ignores an unknown code — degrades to auto).
    static func batchLanguageCode(from setting: String) -> String? {
        baseCode(from: setting)
    }

    /// "en-US"/"auto"-style code for the multilingual streaming manager. Keeps the
    /// region if present ("de-DE"), otherwise passes the bare code ("ru"); "auto"
    /// / empty / translate → "auto". The manager's `promptId(forLanguage:)` maps it
    /// (with its own normalizations) and falls back to auto for unknown codes.
    static func multilingualLanguageCode(from setting: String) -> String {
        guard let s = normalizedSetting(setting) else { return "auto" }
        return s.replacingOccurrences(of: "_", with: "-")
    }
}
