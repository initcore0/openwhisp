import Foundation

/// The pure delivery fence for the Scratchpad's in-flight AI request (MAK-99).
///
/// An AI action is a slow, asynchronous round-trip over a *specific* note. Between
/// the request and its reply the user can switch notes, close the panel, edit the
/// text, or start another action. A late result that paints into whatever note
/// happens to be open is the bug this type exists to prevent — the same hazard
/// `TranslationPreviewController` solves with its `generation` counter.
///
/// The rule: a request is stamped with a monotonically increasing **token** and the
/// **note id** it was launched for. A result is delivered only if BOTH still match
/// the session's current state. Anything that invalidates the request — a note
/// switch, a panel close, a cancel, or a newer request — bumps the token, so every
/// older reply is discarded on arrival.
///
/// Foundation-only and free of any UI, so the "should this result be painted?"
/// decision is pinned by `swift test` instead of being asserted by eye against a
/// live LLM.
public struct ScratchpadAISession: Equatable, Sendable {

    /// A launched request's identity. Opaque to callers — hand it back with the
    /// result and let `accepts` decide.
    public struct Ticket: Equatable, Sendable {
        /// The session token this request was launched under.
        public let token: Int
        /// The note the request was launched for.
        public let noteID: UUID
        /// The action in flight (so the UI can label the spinner).
        public let action: ScratchpadAI.Action

        public init(token: Int, noteID: UUID, action: ScratchpadAI.Action) {
            self.token = token
            self.noteID = noteID
            self.action = action
        }
    }

    /// The token the next request will carry. Bumped by every invalidation.
    private var token: Int = 0

    /// The request currently in flight, if any.
    public private(set) var inFlight: Ticket?

    public init() {}

    /// True while a request is in flight — one action at a time, so the UI disables
    /// the menu and shows a spinner.
    public var isBusy: Bool { inFlight != nil }

    /// The action in flight, for the busy label.
    public var busyAction: ScratchpadAI.Action? { inFlight?.action }

    /// Launch a request for `noteID`, returning its ticket.
    ///
    /// Bumps the token first, so any request already in flight is implicitly
    /// invalidated — a second action started before the first returns can never have
    /// both results land.
    public mutating func begin(noteID: UUID, action: ScratchpadAI.Action) -> Ticket {
        token += 1
        let ticket = Ticket(token: token, noteID: noteID, action: action)
        inFlight = ticket
        return ticket
    }

    /// Whether a returning result may be delivered.
    ///
    /// Requires the ticket to be the one still in flight AND its note to be the one
    /// still selected. The note check is belt-and-braces: `noteChanged` already
    /// invalidates on a switch, but a caller that forgets to call it still can't
    /// paint a summary into the wrong note.
    public func accepts(_ ticket: Ticket, currentNoteID: UUID?) -> Bool {
        guard let inFlight, inFlight == ticket else { return false }
        return ticket.noteID == currentNoteID
    }

    /// Retire the in-flight request after its result was handled (accepted or not).
    ///
    /// Only clears when `ticket` IS the in-flight one: a stale reply arriving after a
    /// newer request was launched must not clear the newer request's busy state.
    public mutating func finish(_ ticket: Ticket) {
        guard inFlight == ticket else { return }
        inFlight = nil
    }

    /// Invalidate any in-flight request: the user switched notes, closed the panel,
    /// or cancelled. The reply will be discarded when it arrives.
    public mutating func cancel() {
        token += 1
        inFlight = nil
    }

    /// Convenience for a note switch: cancels only when the selection actually moved
    /// away from the note the in-flight request belongs to.
    ///
    /// Returns whether anything was cancelled (so the caller can clear a status line).
    @discardableResult
    public mutating func noteChanged(to newNoteID: UUID?) -> Bool {
        guard let inFlight, inFlight.noteID != newNoteID else { return false }
        cancel()
        return true
    }
}
