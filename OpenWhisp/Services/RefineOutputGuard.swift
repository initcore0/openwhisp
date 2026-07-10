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
    /// looks like a translation of a non-Latin dictation. `false` = accept.
    ///
    /// Passes (returns false) for: same-script cleanups, Latin→Latin, short inputs,
    /// empty/whitespace, and mixed content whose output keeps a comparable share of
    /// the input's non-Latin script.
    static func outputTranslatedAway(input: String, output: String) -> Bool {
        let inputLetters = letters(of: input)
        // Too little signal, or no letters at all → nothing to judge, always pass.
        guard inputLetters.count >= minLettersForCheck else { return false }

        let inputCounts = scriptCounts(inputLetters)
        let inputTotal = Double(inputLetters.count)

        // Identify the dominant non-Latin script of the input.
        guard let (dominant, dominantCount) = dominantNonLatinScript(inputCounts) else {
            // No tracked non-Latin script dominates (Latin input, or an untracked
            // "other" script we don't judge) → pass.
            return false
        }
        let inputNonLatinShare = Double(dominantCount) / inputTotal
        guard inputNonLatinShare >= minNonLatinInputShare else { return false }

        // How much of that same script survives in the output?
        let outputLetters = letters(of: output)
        guard !outputLetters.isEmpty else {
            // Empty/letterless output can't be trusted as a same-language cleanup of
            // a substantial non-Latin input — but empty output is already handled by
            // the caller's existing "LLM returned empty" fallback, so treat a
            // letterless output as "not translated" here and let that path win.
            return false
        }
        let outputCounts = scriptCounts(outputLetters)
        let outputScriptShare = Double(outputCounts[dominant, default: 0]) / Double(outputLetters.count)

        // Reject only when the input was clearly non-Latin AND the script all but
        // vanished from the output.
        return outputScriptShare < minOutputScriptShareToPass
    }

    /// Whether THIS session's automatic cleanup should be language-guarded at all.
    ///
    /// Do NOT guard when a translation is legitimately intended — flagging those
    /// would defeat the feature. Exemptions:
    /// - `translateToEnglish`: the user asked the engine/cleanup to produce English.
    /// - `improveTranslation` mode: the translation-polish carve-out (input was
    ///   already locally translated; output English is expected).
    /// - the explicit refine-with-spoken-instruction flow: the user may have asked
    ///   the model to translate as part of their instruction.
    /// - the agent-bridge refine: agents pass their own instructions and own the
    ///   language contract.
    ///
    /// Pure so the decision is unit-tested without AppState/AppKit.
    static func shouldLanguageGuard(
        translateToEnglish: Bool,
        mode: String,
        isSpokenInstructionRefine: Bool,
        isAgentBridgeRefine: Bool,
        hasCustomModeInstruction: Bool = false
    ) -> Bool {
        if translateToEnglish { return false }
        if mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "improvetranslation" { return false }
        if isSpokenInstructionRefine { return false }
        if isAgentBridgeRefine { return false }
        // A user-authored Mode instruction (MAK-39) owns the language contract the
        // same way a spoken instruction does — it may legitimately say "translate
        // to French". Never second-guess it.
        if hasCustomModeInstruction { return false }
        return true
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

    /// The dominant tracked non-Latin script and its letter count, or nil when no
    /// tracked non-Latin script has any letters (input is Latin-only or entirely
    /// "other").
    private static func dominantNonLatinScript(_ counts: [Script: Int]) -> (Script, Int)? {
        let nonLatin = counts.filter { $0.key != .latin && $0.key != .other && $0.value > 0 }
        guard let best = nonLatin.max(by: { $0.value < $1.value }) else { return nil }
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
