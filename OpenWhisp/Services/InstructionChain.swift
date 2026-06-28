import Foundation

/// Pure decision logic for the two-utterance "refine with a follow-up instruction"
/// flow, kept Foundation-only so it lives in OpenWhispCore and is unit-tested
/// without AppState/AppKit.
///
/// The gesture is an explicit DOUBLE-TAP, decided by feel (eyes closed):
///   1. Press → speak content → release.
///   2. Re-press WITHIN `repressGap` of the release → "refine". This is decided at
///      re-press time from the inter-tap gap, NOT by reacting to anything on screen,
///      and works even if step-1 is still transcribing.
///   3. The next utterance is a natural-language instruction the LLM applies to
///      step-1's text. Step-1's raw text is never pasted; only the refined result.
///
/// When refine is triggered this way it's an explicit command, so any rephrase/
/// translate enhancement from Settings is bypassed — the spoken instruction is the
/// only transformation applied.
enum InstructionChain {
    /// Max gap between releasing the hotkey and pressing it again to count as a
    /// deliberate double-tap (→ refine). A tight inter-tap gap: a quick re-press
    /// means "refine", while a normal next dictation (a beat later) does not. Also
    /// bounds how long step-1's paste is deferred while waiting to see a double-tap.
    static let repressGap: TimeInterval = 0.25

    /// Whether the refine flow is available at all for this configuration. Chaining
    /// only applies to whole-text output modes (preview / paste-at-end): in "type
    /// live" the text is already pasted incrementally, so there's nothing to hold
    /// back and refine. Requires an LLM (the instruction is applied by it).
    static func isAvailable(outputMode: String, llmConfigured: Bool, enabled: Bool) -> Bool {
        guard enabled, llmConfigured else { return false }
        return outputMode == "preview" || outputMode == "finalOnly"
    }

    /// Decide whether a fresh Fn-down at `pressUptime` is a double-tap re-press of a
    /// release at `lastReleaseUptime` (nil = no prior release this cycle).
    static func isDoubleTap(
        lastReleaseUptime: TimeInterval?,
        pressUptime: TimeInterval,
        gap: TimeInterval = repressGap
    ) -> Bool {
        guard let release = lastReleaseUptime else { return false }
        let delta = pressUptime - release
        return delta >= 0 && delta <= gap
    }

    /// Build the LLM directive for a spoken instruction applied to step-1 content.
    /// Natural language, no hardcoded action vocabulary — the model interprets
    /// "make it a telegram post", "перепиши покороче", etc.
    static func directive(forInstruction instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are editing the user's dictated text according to a spoken instruction.
        Instruction: "\(trimmed)"
        Apply it to the text. Preserve meaning, names, URLs, and code unless the \
        instruction says otherwise. Match the language of the text unless asked to \
        translate. Return ONLY the resulting text, with no preamble or quotes.
        """
    }
}
