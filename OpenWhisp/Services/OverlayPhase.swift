import Foundation

/// Pure decision for what the dictation overlay should communicate, derived from
/// the current session flags. Foundation-only so it lives in OpenWhispCore and is
/// unit-tested independently of SwiftUI.
///
/// The important case for the lost-leading-audio bug is `.arming`: the overlay is
/// shown the instant the hotkey is pressed (`beginSession`), but audio capture is
/// not actually live until the recorder's `AVAudioEngine` has started — which
/// happens behind an async microphone-permission grant and a cold engine start.
/// Speaking during that gap loses the first word or two. `.arming` lets the UI
/// say "not capturing yet" and withhold the green "speak now" cue until capture
/// is genuinely live (`isCapturing == true`).
///
/// We deliberately do NOT keep the microphone warm/always-on (privacy), so the
/// startup gap is real; the fix is to surface it honestly rather than hide it.
enum OverlayPhase: Equatable {
    /// Session requested; capture not yet live. Tell the user to wait — anything
    /// said now may be dropped.
    case arming
    /// Capture is live and the room is quiet (the "green / ready" listening cue).
    case listening
    /// Capture is live and speech energy is present.
    case speaking
    /// Recording ended; transcribing / polishing.
    case finalizing
    /// Terminal error with no active capture/transcription.
    case error

    /// Inputs mirror exactly the AppState flags the overlay already observes.
    /// - Parameters:
    ///   - hasError: a non-nil session error is set.
    ///   - isCapturing: the recorder has reported `.recording` (engine live).
    ///   - isTranscribing: the session is finalizing/polishing.
    ///   - isArming: a session has begun but capture isn't live yet (the gap).
    ///   - audioLevel: normalized live mic level (0–1).
    ///   - speakingThreshold: level above which we render the "speaking" cue.
    static func resolve(
        hasError: Bool,
        isCapturing: Bool,
        isTranscribing: Bool,
        isArming: Bool,
        audioLevel: Float,
        speakingThreshold: Float = 0.06
    ) -> OverlayPhase {
        // Error only "wins" once nothing is actively capturing/transcribing, matching
        // the prior overlay logic (a transient error mid-session shouldn't flicker red).
        if hasError, !isCapturing, !isTranscribing { return .error }
        if isTranscribing { return .finalizing }
        // Arming: session begun, capture not yet live. `isCapturing` going true is
        // the single signal that ends it (AppState clears isArming in lockstep).
        if isArming, !isCapturing { return .arming }
        if audioLevel > speakingThreshold { return .speaking }
        return .listening
    }
}

/// Pure decision for whether the floating LOCAL dictation overlay (the on-screen
/// pill) is shown for a session at all. Distinct from `OverlayPhase`, which says
/// what an already-visible overlay communicates.
///
/// Foundation-only so it lives in OpenWhispCore and is unit-tested independently
/// of AppKit — the show call site is `AppState.beginSession`.
enum OverlayVisibilityPolicy {
    /// Whether to show the local overlay when a session begins.
    ///
    /// - Parameters:
    ///   - setting: the user's `showOverlay` preference.
    ///   - isAgentSession: an agent initiated this session. Forces the overlay on
    ///     regardless of the setting — agent microphone use is never invisible.
    ///   - isCaptionsCapture: this is a stream-overlay captions capture. Forces
    ///     the overlay OFF, outranking the agent rule: the captions are already
    ///     rendered as subtitles in the stream, and the floating pill would sit
    ///     in the middle of the screen the streamer is broadcasting.
    static func showsLocalOverlay(
        setting: Bool,
        isAgentSession: Bool,
        isCaptionsCapture: Bool
    ) -> Bool {
        // Captions capture wins over the agent force-show: an agent-driven
        // capture session is still going out on stream.
        if isCaptionsCapture { return false }
        return setting || isAgentSession
    }
}

/// Pure decision for whether the rotating first-run discoverability hint may be
/// shown in the overlay right now (MAK-25). This is the LIVE-state suppression that
/// must layer on top of `HintRotation` (which decides *which* hint and whether the
/// feature is still on): a hint is a calm, ambient tip and must never intrude on a
/// moment that owns the overlay's attention.
///
/// Foundation-only so it lives in OpenWhispCore and is unit-tested independently of
/// SwiftUI/AppKit. Inputs mirror exactly the AppState flags the overlay observes.
enum OverlayHintGate {
    /// Whether a rotating hint may be shown. Only in the calm listening/speaking
    /// phase of an ORDINARY USER session — suppressed the moment any other overlay
    /// state owns the cue:
    /// - `.arming` / `.finalizing` / `.error` phases (each has its own caption),
    /// - agent sessions (an agent is asking / the human's turn — amber owns it),
    /// - refine (a rewrite is in progress),
    /// - hands-free lock (its own affordance is showing),
    /// - a transcript already on screen (don't crowd the words),
    /// - a clipboard-fallback or revert affordance is up (actionable, takes priority).
    static func shouldShow(
        phase: OverlayPhase,
        isTranscribing: Bool,
        agentActive: Bool,
        refineArmed: Bool,
        dictationLocked: Bool,
        showTranscript: Bool,
        clipboardFallbackActive: Bool,
        revertActive: Bool
    ) -> Bool {
        switch phase {
        case .arming, .finalizing, .error: return false
        case .listening, .speaking: break
        }
        if isTranscribing { return false }
        if agentActive { return false }
        if refineArmed { return false }
        if dictationLocked { return false }
        if showTranscript { return false }
        if clipboardFallbackActive { return false }
        if revertActive { return false }
        return true
    }
}

/// Pure decision for the post-dictation overlay's "revert to original" affordance
/// (MAK-35 follow-up). The History list already offers a per-entry revert; this
/// brings the SAME one-click restore to the overlay the instant a dictation lands,
/// so the user can undo an AI-cleanup change without opening Settings.
///
/// Foundation-only so it lives in OpenWhispCore and is unit-tested independently of
/// SwiftUI/AppKit — the overlay view just maps this decision to a control.
enum OverlayRevert {
    /// Whether the overlay should show the revert control right now, and what the
    /// raw pre-cleanup words are.
    ///
    /// The affordance is shown only when the most-recent history entry actually has
    /// something to revert to (`revertTarget != nil` — the AI cleanup changed the
    /// words this session) AND the overlay is in a settled post-dictation state, not
    /// mid-session. Offering "revert" while still capturing/finalizing would be
    /// meaningless (the entry isn't recorded yet) and visually noisy.
    ///
    /// - Parameters:
    ///   - mostRecentRevertTarget: `history.first?.revertTarget` — the raw words the
    ///     newest entry can be restored to, or nil when nothing changed / no history.
    ///   - isRecording: capture is live.
    ///   - isTranscribing: the session is finalizing/polishing.
    ///   - isArming: a session has begun but capture isn't live yet.
    ///   - refineArmed: a refine (spoken-instruction rewrite) is in progress.
    /// - Returns: the raw target to restore when the control should be shown; nil to
    ///   hide it.
    static func target(
        mostRecentRevertTarget: String?,
        isRecording: Bool,
        isTranscribing: Bool,
        isArming: Bool,
        refineArmed: Bool
    ) -> String? {
        guard let raw = mostRecentRevertTarget, !raw.isEmpty else { return nil }
        // Only in a settled, post-dictation overlay — never while a session (or a
        // refine) is still live. A new dictation supersedes the previous revert.
        guard !isRecording, !isTranscribing, !isArming, !refineArmed else { return nil }
        return raw
    }
}

/// Pure decision for an in-place replacement of the just-inserted dictation with the
/// user's raw pre-cleanup words (MAK-35 follow-up). Right after a dictation the caret
/// sits immediately after the inserted text, so replacing that text in-place is the
/// higher-value revert (the History revert only copies to the clipboard). But it is
/// only SAFE when the focused field still ends with exactly what we inserted — if the
/// user moved the caret, clicked elsewhere, or typed since, a blind replace could
/// clobber their content. This helper makes that safety call without touching AX, so
/// it's fully unit-tested; the caller (TextInserter) only performs the field mutation.
enum ReplaceLastInsertion {
    /// Decide the exact new value the focused field should hold to swap the inserted
    /// text for `raw`, or nil when an in-place replace is unsafe/unnecessary (the
    /// caller then leaves the field alone and relies on the clipboard-copy fallback).
    ///
    /// Safe iff the current value ends with the text we inserted (allowing for a
    /// single trailing space the insert may have appended) — then and only then do we
    /// know precisely which characters are "ours" to replace, and everything before
    /// them is the user's untouched content.
    ///
    /// - Parameters:
    ///   - currentValue: the focused element's whole current value (nil = unreadable).
    ///   - inserted: the text this session inserted (before any trailing space).
    ///   - raw: the raw pre-cleanup words to restore in its place.
    /// - Returns: the full replacement value for the field, or nil to skip the replace.
    static func newValue(currentValue: String?, inserted: String, raw: String) -> String? {
        guard let currentValue else { return nil }
        let insertedTrimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to swap (empty inserted) or a no-op swap (raw == inserted): skip.
        guard !insertedTrimmed.isEmpty, insertedTrimmed != rawTrimmed else { return nil }

        // The field must END with our inserted text (optionally followed by the single
        // trailing space the insert appends) — otherwise we can't identify our slice
        // and must not touch the field. The comparison folds typography (smart quotes,
        // dashes, …) so a field that substituted those on insert still matches — the
        // same normalization the AX insert verifier uses.
        let candidates = [insertedTrimmed + " ", insertedTrimmed]
        for tail in candidates {
            // Walk back through the REAL current string, growing a suffix until its
            // folded form equals the folded tail. Matching on folded strings but
            // slicing the real one keeps the user's untouched prefix byte-exact even
            // when the app rendered our text with different glyphs.
            guard let prefix = realPrefixDroppingFoldedSuffix(from: currentValue, foldedTail: InsertVerifier.foldTypography(tail))
            else { continue }
            let trailer = tail.hasSuffix(" ") ? " " : ""
            return prefix + rawTrimmed + trailer
        }
        return nil
    }

    /// Return the real (byte-exact) prefix of `value` left after dropping a suffix
    /// whose typography-folded form equals `foldedTail`, or nil when no such suffix
    /// exists. Grows the candidate suffix one real character at a time so a glyph the
    /// app substituted (e.g. a curly apostrophe for a straight one, or `…` for `...`)
    /// still matches while the returned prefix stays exactly as the field holds it.
    private static func realPrefixDroppingFoldedSuffix(from value: String, foldedTail: String) -> String? {
        guard !foldedTail.isEmpty else { return nil }
        var suffix = ""
        var idx = value.endIndex
        // Bound the walk to a few chars beyond the folded length — folding only ever
        // shrinks or keeps length except ellipsis (1→3), so the real suffix can be at
        // most `foldedTail.count` characters.
        while idx > value.startIndex, suffix.count <= foldedTail.count {
            idx = value.index(before: idx)
            suffix = String(value[idx]) + suffix
            if InsertVerifier.foldTypography(suffix) == foldedTail {
                return String(value[value.startIndex..<idx])
            }
        }
        return nil
    }
}
