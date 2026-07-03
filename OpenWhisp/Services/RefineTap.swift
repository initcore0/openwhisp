import Foundation

/// Decides whether a refine-key press was a deliberate BARE TAP — pressed and
/// released quickly with no other input in between — as opposed to the key
/// being used as a modifier in a shortcut (⌃C, ⌃-click, ⌃⌘-arrow, ⌃-scroll…).
///
/// Needed since the refine key moved to the LEFT modifiers: with the old
/// right-side keys a bare press was almost always intentional, but Left
/// Control participates in everyday shortcuts, and treating every ⌃ press as
/// "arm refine" silently armed refine in the background — the next dictation
/// then started in refine mode with no visible cause.
///
/// Foundation-only so it lives in OpenWhispCore and is unit-tested; the
/// hotkey monitor feeds it edges and other-input events.
struct RefineTapRecognizer {
    /// Longest press that still counts as a tap. Longer means the key is being
    /// held as a modifier (or the user changed their mind).
    let maxTapDuration: TimeInterval

    private var downAt: Date?
    private var sawOtherInput = false

    init(maxTapDuration: TimeInterval = 0.6) {
        self.maxTapDuration = maxTapDuration
    }

    /// The refine key's press edge.
    mutating func keyDown(at date: Date = Date()) {
        downAt = date
        sawOtherInput = false
    }

    /// Any OTHER input while the refine key is held — a key press, a mouse
    /// click, a scroll, or another modifier going down. The hold is a
    /// shortcut, not a tap. No-op while the refine key isn't held.
    mutating func otherInput() {
        if downAt != nil { sawOtherInput = true }
    }

    /// The refine key's release edge. Returns true for a clean tap — the
    /// caller triggers refine then, on the UP edge.
    mutating func keyUp(at date: Date = Date()) -> Bool {
        defer { downAt = nil }
        guard let downAt, !sawOtherInput else { return false }
        return date.timeIntervalSince(downAt) <= maxTapDuration
    }
}
