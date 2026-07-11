import Foundation

/// Deterministic guard that catches the one failure mode the automatic AI
/// cleanup can't be trusted to avoid on its own: silently TRANSLATING the
/// dictation instead of just cleaning it.
///
/// The bug: dictating in Russian, the preview overlay shows Russian (the raw
/// transcript) but the pasted text is English. The cleanup prompts all ASK the
/// model to "keep the language", but small on-device models frequently translate
/// Cyrillic → English anyway, and the refined text replaces the final transcript
/// with no validation. The engine translate paths are fine; this is purely the
/// LLM-cleanup acceptance path.
///
/// The fix here is a script-mismatch detector: compute the dominant Unicode
/// script of the INPUT's letters, and if the input is predominantly a non-Latin
/// script but the output has almost none of that script, the "cleanup" translated
/// → REJECT (keep the raw transcript). Latin→Latin and same-script always pass.
///
/// Design bias: this must be CONSERVATIVE. A false rejection merely yields the
/// raw transcript (the same fail-open path used when the LLM errors), so the cost
/// is low — but a wrong flag on legitimately-cleaned text is still user-visible,
/// so the thresholds are set to fire only when the evidence is overwhelming.
///
/// Pure and Foundation-only so it lives in `OpenWhispCore` and is unit-tested
/// without AppState/AppKit.
enum RefineOutputGuard {
    /// Writing systems we track by Unicode scalar range. Latin is the "translate
    /// target" most small models drift toward, so a non-Latin input becoming
    /// almost-all-Latin output is the signal we reject on. We only need enough
    /// scripts to identify the dominant non-Latin one; anything unlisted counts as
    /// "other letter" and never triggers a rejection (conservative by default).
    enum Script: Equatable {
        case latin
        case cyrillic
        case han
        case arabic
        case hebrew
        case greek
        case hangul
        case kana
        case other
    }

    // MARK: - Thresholds (rationale in comments; tune here, nowhere else)

    /// Inputs shorter than this many LETTERS always pass. A handful of letters is
    /// too little signal — a legitimate short Russian phrase whose cleanup happens
    /// to drop a couple of Cyrillic chars could look like a translation. Twelve
    /// letters is ~2-3 short words: enough to establish a dominant script.
    static let minLettersForCheck = 12

    /// The input must be at least this fraction non-Latin letters to be considered
    /// a "non-Latin dictation" worth guarding. 0.40 tolerates heavy mixing —
    /// Russian prose sprinkled with English identifiers, URLs, or code still counts
    /// as a Russian dictation and gets guarded — while a mostly-Latin input (a few
    /// stray Cyrillic chars) is left alone.
    static let minNonLatinInputShare = 0.40

    /// If the output retains LESS than this fraction of the input's dominant
    /// non-Latin script, we treat the script as having "disappeared" → translated.
    /// 0.10 is deliberately near-zero: we only reject when the script is almost
    /// entirely gone. A legitimate same-language cleanup keeps essentially all of
    /// the script (Russian in → Russian out), so it clears this bar by a mile; a
    /// true translation drops it to ~0. The wide gap between "kept" (~1.0) and
    /// "translated" (~0.0) is what makes the guard safe.
    static let minOutputScriptShareToPass = 0.10

    // MARK: - Decision

    /// `true` when the cleanup output must be REJECTED (kept-original) because it
    /// looks like a translation of the dictation into a DIFFERENT writing system.
    ///
    /// Symmetric (fix for the English → Russian regression): it flags translation in
    /// BOTH directions. The original bug was non-Latin → Latin (Russian dictation
    /// "cleaned" into English); the inverse is Latin → non-Latin (English dictation
    /// "cleaned" into Russian, when a stale target-language picker told the polish
    /// prompt to produce Russian). Either way the input has a clear dominant script
    /// and the output is predominantly a DIFFERENT tracked script → REJECT.
    ///
    /// Passes (returns false) for: same-script cleanups (Latin→Latin, Cyrillic→
    /// Cyrillic, …), short inputs, empty/whitespace, output whose dominant script
    /// matches the input's, and — when `expectedOutputScript` is supplied by an
    /// intended translate-to-X flow — output that lands in that expected script.
    ///
    /// - `expectedOutputScript`: the script an INTENDED translation targets (e.g. a
    ///   translate-to-Russian flow passes `.cyrillic`). When the output's dominant
    ///   script equals this, the "different script" is expected → ACCEPT. Nil for
    ///   plain same-language cleanups (any script change is then a rejection).
    static func outputTranslatedAway(
        input: String,
        output: String,
        expectedOutputScript: Script? = nil
    ) -> Bool {
        let inputLetters = letters(of: input)
        // Too little signal, or no letters at all → nothing to judge, always pass.
        guard inputLetters.count >= minLettersForCheck else { return false }

        let inputCounts = scriptCounts(inputLetters)
        let inputTotal = Double(inputLetters.count)

        // Identify the dominant script of the input — including Latin, so English
        // dictations are judged too. "other"/untracked scripts never anchor a
        // rejection (conservative).
        guard let (inputScript, inputScriptCount) = dominantTrackedScript(inputCounts) else {
            return false
        }
        let inputShare = Double(inputScriptCount) / inputTotal
        // The input must be clearly dominated by one tracked script to be worth
        // judging. Reuses the same tolerant threshold as before (heavy mixing —
        // e.g. English identifiers in Russian, or code in English — still counts).
        guard inputShare >= minNonLatinInputShare else { return false }

        let outputLetters = letters(of: output)
        guard !outputLetters.isEmpty else {
            // Empty/letterless output is handled by the caller's existing "LLM
            // returned empty" fallback; treat it as "not translated" here.
            return false
        }
        let outputCounts = scriptCounts(outputLetters)
        let outputTotal = Double(outputLetters.count)

        // If enough of the INPUT's script survives in the output, this is a
        // same-language cleanup → ACCEPT. (Covers Russian→Russian, Latin→Latin.)
        let keptShare = Double(outputCounts[inputScript, default: 0]) / outputTotal
        guard keptShare < minOutputScriptShareToPass else { return false }

        // The input's script all but vanished. Identify what the output became.
        guard let (outputScript, outputScriptCount) = dominantTrackedScript(outputCounts) else {
            // Output has no dominant tracked script (all "other") → don't judge.
            return false
        }
        // Only reject when the output is CLEARLY a different tracked script, not a
        // faint smear of one — same overwhelming-evidence bar as the input side.
        let outputShare = Double(outputScriptCount) / outputTotal
        guard outputShare >= minNonLatinInputShare, outputScript != inputScript else {
            return false
        }

        // An intended translation that landed in its expected script is fine.
        if let expectedOutputScript, outputScript == expectedOutputScript {
            return false
        }

        // Input was clearly one script, output is clearly a different (unexpected)
        // one → the "cleanup" translated. REJECT.
        return true
    }

    /// Map a language code (as used by the app's target-language / cleaning-language
    /// settings) to the writing system an intended translation into it would produce.
    /// Only codes whose script we track return a value; anything else is nil (the
    /// guard then has no expected script and treats any script change as suspect,
    /// which is the safe default — a false accept, not a false reject).
    static func script(forLanguageCode code: String) -> Script? {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ru", "uk", "be", "bg", "sr", "mk": return .cyrillic
        case "en", "es", "fr", "de", "it", "pt", "nl", "pl", "tr", "id", "vi",
             "sv", "da", "no", "fi", "cs", "ro", "hu":
            return .latin
        case "el": return .greek
        case "he": return .hebrew
        case "ar", "fa", "ur": return .arabic
        case "zh": return .han
        case "ja": return .kana
        case "ko": return .hangul
        default: return nil
        }
    }

    /// Whether THIS session's automatic cleanup should be language-guarded at all.
    ///
    /// Only paths whose language contract is OWNED by a free-form instruction are
    /// exempted outright — the guard can't know what script those legitimately
    /// produce:
    /// - the explicit refine-with-spoken-instruction flow (the user may have asked
    ///   the model to translate as part of their instruction),
    /// - the agent-bridge refine (agents pass their own instructions),
    /// - a user-authored Mode instruction (MAK-39; may say "translate to French").
    ///
    /// NOTE (fix): `translateToEnglish` and `improveTranslation` are NO LONGER blanket
    /// exemptions. They ARE intended translations, but with a KNOWN target script, so
    /// the call site keeps the guard on and passes `expectedOutputScript` to
    /// `outputTranslatedAway` — the guard then accepts output in the expected script
    /// but still rejects a drift into some OTHER script (the English → Russian bug:
    /// improveTranslation with a stale target-language picker produced Russian for an
    /// English dictation, and the old blanket exemption let it through).
    ///
    /// Pure so the decision is unit-tested without AppState/AppKit.
    static func shouldLanguageGuard(
        isSpokenInstructionRefine: Bool,
        isAgentBridgeRefine: Bool,
        hasCustomModeInstruction: Bool = false
    ) -> Bool {
        if isSpokenInstructionRefine { return false }
        if isAgentBridgeRefine { return false }
        if hasCustomModeInstruction { return false }
        return true
    }

    /// The writing system the automatic cleanup is LEGITIMATELY allowed to produce
    /// (its intended translation target), or nil when no translation is intended and
    /// the output must stay in the input's own script.
    ///
    /// - `translateToEnglish`: whisper translated the audio INTO English, so the
    ///   polish output is expected in Latin. This is the ONLY condition that
    ///   expects a script change: the `improveTranslation` prompt itself only runs
    ///   when `translateToEnglish` is on (see
    ///   `CleanupIntensity.wholeTextCustomInstruction` — a stale improveTranslation
    ///   mode with translate-to-English OFF gets the plain same-language intensity
    ///   prompt), so mode alone must NOT relax the guard: a Russian dictation
    ///   cleaned under that stale mode still has to stay Russian. There is no
    ///   user-settable target — the old en/ru picker was removed because a stale
    ///   "ru" turned English dictations Russian (the reported regression).
    ///
    /// Passed to `outputTranslatedAway` as `expectedOutputScript`. When nil, any
    /// script change is a rejection (the plain same-language cleanup contract).
    static func expectedCleanupScript(
        translateToEnglish: Bool,
        mode: String,
        translationTargetLanguage: String
    ) -> Script? {
        // The engine's translate task only ever produces English, so Latin is the
        // only expected script. `mode` and `translationTargetLanguage` are
        // intentionally not consulted — see the doc above — but kept in the
        // signature so call sites state the full session context they resolve from.
        _ = mode
        _ = translationTargetLanguage
        if translateToEnglish { return .latin }
        return nil
    }

    // MARK: - Script analysis

    /// The letters of a string: Unicode scalars that are alphabetic. Digits,
    /// punctuation, whitespace, symbols, and emoji are ignored — they carry no
    /// language-script signal and would only dilute the ratios.
    private static func letters(of string: String) -> [Unicode.Scalar] {
        string.unicodeScalars.filter { $0.properties.isAlphabetic }
    }

    private static func scriptCounts(_ scalars: [Unicode.Scalar]) -> [Script: Int] {
        var counts: [Script: Int] = [:]
        for scalar in scalars {
            counts[script(of: scalar), default: 0] += 1
        }
        return counts
    }

    /// The dominant TRACKED script and its letter count, or nil when only the
    /// untracked `.other` bucket has letters. Latin is a tracked script here (unlike
    /// the old non-Latin-only helper) so English inputs/outputs are judged too — the
    /// symmetric guard needs to name Latin as both a source and a target script.
    private static func dominantTrackedScript(_ counts: [Script: Int]) -> (Script, Int)? {
        let tracked = counts.filter { $0.key != .other && $0.value > 0 }
        guard let best = tracked.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }

    /// Classify one scalar into a writing system by codepoint range. Ranges cover
    /// the common blocks (base + supplements/extensions) for each script; anything
    /// outside them is `.other` and never drives a rejection.
    private static func script(of scalar: Unicode.Scalar) -> Script {
        let v = scalar.value
        switch v {
        // Latin: Basic Latin letters, Latin-1 Supplement, Extended-A/B, Extended Additional.
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x024F, 0x1E00...0x1EFF:
            return .latin
        // Greek and Coptic + Greek Extended.
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        // Cyrillic + Cyrillic Supplement/Extended.
        case 0x0400...0x04FF, 0x0500...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        // Hebrew.
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return .hebrew
        // Arabic (base + supplement + extended + presentation forms).
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        // Hangul (Jamo + Compatibility Jamo + Syllables).
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
            return .hangul
        // Japanese kana: Hiragana + Katakana (+ phonetic extensions).
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF:
            return .kana
        // Han / CJK unified ideographs (base + Ext A + compatibility).
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return .han
        default:
            return .other
        }
    }
}
