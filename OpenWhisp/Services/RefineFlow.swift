import Foundation

// MARK: - Refine flow state machine (pure, unit-tested)
//
// The two-utterance "refine with a follow-up instruction" flow was historically
// spread across ~6 implicit boolean flags on AppState (refineArmed,
// isInstructionSession, awaitingStep1, refineFromSelection, refineLLMInFlight,
// plus timing off lastReleaseUptime). Every subtle bug — wrong text used as the
// instruction, stuck overlay, wedge on empty transcripts, hard-to-hit timing —
// came from those flags getting into a combination no one designed.
//
// `RefineFlow` makes the lifecycle ONE explicit state with defined transitions.
// It is pure: it holds no AppKit/engine references, takes `Event`s, mutates its
// `State`, and returns `Effect`s that AppState performs (start a capture, run the
// LLM, insert text, hide the overlay…). This is what's unit-tested; AppState just
// wires events in and executes effects out.
//
// Terminology: "step 1" = the content being refined (a just-dictated result or a
// text selection). "instruction" = the spoken command applied to it.
struct RefineFlow {

    // MARK: State

    enum State: Equatable {
        /// No refine in progress.
        case inactive
        /// Refine engaged; the instruction utterance is being captured. `step1` is
        /// the content to refine once known (nil while a just-dictated step-1 is
        /// still transcribing). `fromSelection` = step-1 came from a text selection
        /// (so on "no instruction" we must NOT paste over the user's text).
        case capturing(step1: String?, fromSelection: Bool)
        /// The LLM refine request is in flight.
        case applying(step1: String, instruction: String, fromSelection: Bool)
    }

    // MARK: Events (things that happen in the app)

    enum Event: Equatable {
        /// User re-pressed to engage refine. `step1` is the resolved content if we
        /// already have it (a text selection, or a just-finalized dictation), or nil
        /// if a dictation is still transcribing and step-1 will arrive shortly.
        case engage(step1: String?, fromSelection: Bool)
        /// A pending step-1 dictation finalized (only meaningful while capturing
        /// with step1 == nil).
        case step1Finalized(String)
        /// The instruction utterance finalized.
        case instructionFinalized(String)
        /// The LLM refine call returned.
        case llmSucceeded(String)
        case llmFailed(String)
        /// User cancelled (Esc), started a brand-new dictation, or the watchdog
        /// fired to recover a wedged flow.
        case abort
    }

    // MARK: Effects (things AppState should do)

    enum Effect: Equatable {
        /// Begin capturing the instruction utterance (start a recording/streaming
        /// session dedicated to the instruction).
        case startInstructionCapture
        /// Run the LLM: apply `instruction` to `step1`.
        case runLLM(step1: String, instruction: String)
        /// Insert `text` as the final result. `replacingSelection` is true when
        /// step-1 came from a selection (semantics differ for the caller).
        case insert(text: String, replacingSelection: Bool)
        /// Nothing to refine / no instruction heard from a dictation source with no
        /// usable text — just tear down the overlay/session cleanly.
        case finishQuietly(status: String)
        /// Show a transient status string (no other side effect).
        case status(String)
    }

    // MARK: - Machine

    private(set) var state: State = .inactive

    var isActive: Bool { state != .inactive }
    /// True only while the LLM call is genuinely in flight — the watchdog uses this
    /// to distinguish "working" from "wedged".
    var isApplying: Bool { if case .applying = state { return true }; return false }

    /// Apply an event, returning the effects to perform (in order). Pure aside from
    /// mutating `state`.
    mutating func handle(_ event: Event) -> [Effect] {
        // Switch on the EVENT first, then the relevant state(s) within — this keeps
        // the machine exhaustive without enumerating every (state, event) pair, and
        // makes each event's rules read top-to-bottom.
        switch event {

        // --- Engage refine -------------------------------------------------------
        case let .engage(step1, fromSelection):
            // From inactive OR capturing (rapid re-press → fresh capture, don't
            // stack). Ignored once the LLM is already applying.
            if case .applying = state { return [] }
            state = .capturing(step1: trimmedOrNil(step1), fromSelection: fromSelection)
            return [.startInstructionCapture]

        // --- Step-1 (the content) finalized while we were waiting for it ----------
        case let .step1Finalized(text):
            // Only meaningful while capturing with an unresolved step-1.
            guard case let .capturing(nil, fromSelection) = state else { return [] }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Nothing was dictated for step-1 — abandon cleanly (the rapid/empty
                // re-press case that used to wedge the overlay).
                state = .inactive
                return [.finishQuietly(status: "Nothing to refine")]
            }
            state = .capturing(step1: trimmed, fromSelection: fromSelection)
            return []

        // --- Instruction finalized ----------------------------------------------
        case let .instructionFinalized(text):
            guard case let .capturing(step1, fromSelection) = state else { return [] }
            let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = step1?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if content.isEmpty {
                // No content to refine (step-1 never resolved) — abandon.
                state = .inactive
                return [.finishQuietly(status: "Nothing to refine")]
            }
            if instruction.isEmpty {
                // Heard no instruction. For a dictation, insert step-1 unchanged;
                // for a selection, leave the user's text as-is.
                state = .inactive
                return fromSelection
                    ? [.finishQuietly(status: "No instruction heard")]
                    : [.insert(text: content, replacingSelection: false),
                       .status("No instruction heard; inserted text")]
            }
            state = .applying(step1: content, instruction: instruction, fromSelection: fromSelection)
            return [.runLLM(step1: content, instruction: instruction)]

        // --- LLM result ----------------------------------------------------------
        case let .llmSucceeded(result):
            guard case let .applying(step1, _, fromSelection) = state else { return [] }
            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = cleaned.isEmpty ? step1 : cleaned
            state = .inactive
            return [.insert(text: text, replacingSelection: fromSelection),
                    .status("Instruction applied")]

        case let .llmFailed(message):
            guard case let .applying(step1, _, fromSelection) = state else { return [] }
            state = .inactive
            return [.insert(text: step1, replacingSelection: fromSelection),
                    .status("Refine failed: \(message); inserted text")]

        // --- Abort (cancel / new dictation / watchdog) ---------------------------
        case .abort:
            guard state != .inactive else { return [] }
            state = .inactive
            return [.finishQuietly(status: "Ready")]
        }
    }

    /// Force the machine back to inactive without emitting effects (belt-and-braces
    /// reset used when the caller tears everything down itself).
    mutating func reset() {
        state = .inactive
    }

    private func trimmedOrNil(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
