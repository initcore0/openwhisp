import Foundation

/// The Meme Generator's busy-state machine (spike v3).
///
/// ## Why this is a type instead of a `Bool`
///
/// The owner's report was "stuck loading, and I can't switch templates during or
/// after". The cause was structural rather than a single missed line: v2 tracked
/// in-flight work with a `Bool` cleared by a `finish()` that several exit paths never
/// reached. Specifically, every superseded-ticket bail read
///
/// ```swift
/// guard !self.isCancelled, myTicket == self.ticket else { return }
/// ```
///
/// and returned WITHOUT clearing `isBusy`. That is correct only if some other task
/// owns the flag — true when a newer request superseded this one, false when the
/// window was cancelled and re-shown, or when the LLM call threw between the two
/// guards. Any of those left `isBusy == true` forever, which disabled Generate AND
/// (because `select(template:)` began with `guard !isBusy`) froze the candidate strip
/// and the Browse grid — exactly the two symptoms reported.
///
/// Making the state a value with ONE transition function fixes the class of bug: a
/// phase can only change through `begin`/`finish`/`cancel`/`timeout`, each of which
/// is total, and `swift test` can drive every ordering including the out-of-order and
/// duplicate ones that a `Bool` gets wrong.
public struct MemeGenerationState: Equatable, Sendable {

    /// What the surface is doing.
    public enum Phase: Equatable, Sendable {
        /// Nothing in flight.
        case idle
        /// The LLM is being warmed at window-open. The user may still browse and
        /// switch templates; only Generate waits.
        case warming
        /// Loading the template catalog.
        case loadingCatalog
        /// Waiting on the LLM.
        case asking
        /// Downloading a template image.
        case downloading(templateName: String)

        /// True when a generate round-trip is in flight.
        ///
        /// Note `warming` is NOT busy. Warming happens on window open, before the
        /// user has asked for anything; blocking the UI on it would trade a cold
        /// first Generate for a frozen window, which is a worse bug than the one
        /// being fixed.
        public var isGenerating: Bool {
            switch self {
            case .idle, .warming: return false
            case .loadingCatalog, .asking, .downloading: return true
            }
        }

        /// The line shown under the controls while this phase runs.
        public var statusText: String {
            switch self {
            case .idle:                    return ""
            case .warming:                 return "Preparing model…"
            case .loadingCatalog:          return "Loading templates…"
            case .asking:                  return "Asking the model…"
            case .downloading(let name):   return "Downloading \(name)…"
            }
        }
    }

    public private(set) var phase: Phase
    /// The ticket of the work that currently owns the phase. A result carrying an
    /// older ticket is ignored — including its attempt to clear the phase, which is
    /// what stops a late failure from unsticking a newer, legitimately-running
    /// request.
    public private(set) var ticket: Int

    public init(phase: Phase = .idle, ticket: Int = 0) {
        self.phase = phase
        self.ticket = ticket
    }

    public var isGenerating: Bool { phase.isGenerating }

    /// True when the user may pick a different template right now.
    ///
    /// **Always true.** This is a deliberate answer to "can't switch templates during
    /// or after": switching templates re-renders the SAME caption boxes onto an image
    /// that is either already cached or a single GET away — it involves no LLM
    /// round-trip and no catalog fetch, so there is no reason a generation in flight
    /// should block it. v2 gated it on `!isBusy` purely by reflex, and that reflex is
    /// what made a stuck flag freeze the whole surface.
    ///
    /// Kept as a named property rather than inlining `true` at the call site so the
    /// decision is stated once, testable, and hard to silently regress.
    public var canSelectTemplate: Bool { true }

    /// True when Generate should be offered. Warming blocks it — but see
    /// `generateBlockedReason`, which makes that wait honest rather than a dead button.
    public var canGenerate: Bool { phase == .idle }

    /// Why Generate is unavailable, or nil when it is available.
    ///
    /// The v2 bug report was "first Generate fails with a network error and model
    /// loading". The model was simply not up yet, and the surface let the user fire a
    /// request into a socket nothing was listening on. Saying "Preparing model…" and
    /// waiting is the honest version of the same moment.
    public func generateBlockedReason() -> String? {
        switch phase {
        case .idle:       return nil
        case .warming:    return "Preparing model…"
        default:          return phase.statusText
        }
    }

    // MARK: - Transitions

    /// Begin a new unit of work, taking a fresh ticket.
    ///
    /// Returns the ticket the caller must carry through its async work and present
    /// back on every subsequent transition. Incrementing on every begin is what makes
    /// a superseded result identifiable.
    public mutating func begin(_ phase: Phase) -> Int {
        ticket += 1
        self.phase = phase
        return ticket
    }

    /// Move to another phase WITHIN the same unit of work (catalog → asking →
    /// downloading), keeping the ticket.
    ///
    /// Returns false — and changes nothing — when the ticket is stale, so a
    /// superseded task can't drag the UI back to its own phase.
    @discardableResult
    public mutating func advance(_ phase: Phase, ticket incoming: Int) -> Bool {
        guard incoming == ticket else { return false }
        self.phase = phase
        return true
    }

    /// End the unit of work identified by `incoming`.
    ///
    /// This is THE fix for the stuck state, and its contract is the important part:
    /// finishing is **idempotent and total**. Calling it twice is safe, calling it
    /// from an error path is safe, and calling it with a stale ticket is a no-op that
    /// leaves the newer work's phase intact. Every exit path in the model calls this
    /// — success, parse rejection, transport failure, timeout, and cancel — so there
    /// is no path left that can end without clearing the phase.
    ///
    /// The return value says whether THIS call is the one that ended the work, so a
    /// caller can write the final status exactly once. A redundant second finish
    /// returns false rather than letting, say, a timeout overwrite the success
    /// message that already landed.
    @discardableResult
    public mutating func finish(ticket incoming: Int) -> Bool {
        guard incoming == ticket, phase != .idle else { return false }
        phase = .idle
        return true
    }

    /// Abandon whatever is in flight and refuse its result.
    ///
    /// Used by the Cancel button and by window close. Bumping the ticket is what
    /// makes the abandoned work's later `finish` a no-op *and* stops it writing a
    /// meme into a closed window.
    public mutating func cancel() {
        ticket += 1
        phase = .idle
    }

    /// Whether a result carrying `incoming` is still wanted.
    public func accepts(ticket incoming: Int) -> Bool { incoming == ticket }

    // MARK: - Timeout

    /// The hard ceiling on one generate round-trip.
    ///
    /// A local model on a cold cache can genuinely take a while, so this is generous
    /// — but it is FINITE, which is the point. v2 had no ceiling at all: an LLM call
    /// that never returned left the surface busy forever with no way back except
    /// closing the window. Whatever the number, "eventually recovers by itself" beats
    /// "waits forever".
    public static let generateTimeout: TimeInterval = 120

    /// The message shown when the ceiling is hit.
    public static let timeoutMessage =
        "The model didn't answer within \(Int(generateTimeout)) seconds. It may still be "
        + "loading — try Generate again, or pick a template yourself with Browse all."
}
