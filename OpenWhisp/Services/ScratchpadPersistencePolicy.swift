import Foundation

/// The rule deciding whether a Scratchpad mutation persists **now** or may be
/// coalesced into a debounced background write (MAK-95).
///
/// The bug this closes (docs/BUG_HUNT_2026-07.md): `textDidChange` fired a full
/// synchronous atomic JSON encode of *every* note's body on **every keystroke**.
/// With a few long dictated notes that is O(total scratchpad bytes) of encoding
/// plus a disk write per character, on the main thread.
///
/// The fix mirrors the vocabulary debounce already in `AppState`: coalesce the
/// high-frequency path, keep the low-frequency structural path immediate. This
/// enum is the pure, testable statement of *which is which* — the controller just
/// asks it.
///
/// **Why structural ops stay immediate**: a create/delete/meeting-insert changes
/// which notes *exist*. If the app is killed inside the debounce window, losing a
/// few seconds of typing is recoverable (the text is still on screen until the
/// window closes, and close flushes); losing a whole note the user just created —
/// or resurrecting one they deleted — is not.
public enum ScratchpadPersistencePolicy {

    /// The kind of mutation that just happened.
    public enum Mutation: Equatable {
        /// A body edit from the editor — fires per keystroke. Coalesced.
        case edit
        /// A dictation landed in a note. Coalesced: it arrives at most once per
        /// utterance, but it is immediately followed by editing in the common case,
        /// and the window close / terminate flush covers the tail.
        case dictation
        /// A note was created. Immediate.
        case create
        /// A note was deleted. Immediate.
        case delete
        /// A meeting was inserted as a note. Immediate.
        case meetingInsert
        /// The window closed, the app is terminating, or the model is being handed
        /// off. Immediate, and must flush anything already pending.
        case teardown
    }

    /// How long edits coalesce before the background write runs.
    ///
    /// 0.6s matches the vocabulary debounce — long enough that ordinary typing
    /// (and a burst of dictated chunks) collapses into one write, short enough that
    /// a pause of under a second already has the note on disk.
    public static let debounceInterval: TimeInterval = 0.6

    /// True when the mutation must hit disk synchronously rather than wait for the
    /// debounce timer.
    public static func requiresImmediateWrite(_ mutation: Mutation) -> Bool {
        switch mutation {
        case .edit, .dictation:
            return false
        case .create, .delete, .meetingInsert, .teardown:
            return true
        }
    }

    /// True when the mutation must also **flush** an already-pending debounced
    /// write (rather than merely writing its own snapshot).
    ///
    /// Every immediate mutation writes the whole store, so a pending timer is
    /// redundant afterwards and must be cancelled — otherwise a stale snapshot
    /// captured *before* a delete could land *after* it and resurrect the note.
    /// That makes "flush" and "immediate" the same set today, but they are stated
    /// separately because the reason differs, and the cancel-stale-timer invariant
    /// is what the test actually pins.
    public static func cancelsPendingWrite(_ mutation: Mutation) -> Bool {
        requiresImmediateWrite(mutation)
    }
}
