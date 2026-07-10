import Foundation

/// Platform-agnostic global-hotkey seam (Phase 2.5 core extraction).
///
/// AppState depends on this protocol instead of the concrete macOS
/// `HotkeyMonitor` (CGEventTap + NSEvent), so a port supplies its own backend
/// (Windows: `RegisterHotKey` / `WH_KEYBOARD_LL`). The callbacks carry no
/// platform types, so the orchestration in AppState never names AppKit.
protocol HotkeyControlling: AnyObject {
    /// Which gesture triggers dictation: "fn", "controlSpace", or "custom".
    /// For "custom", `customTrigger` supplies the recorded keycode + modifiers.
    var triggerMode: String { get set }
    /// The user-recorded arbitrary trigger, consulted only when
    /// `triggerMode == "custom"` (MAK-17). nil leaves the two presets in charge.
    var customTrigger: DictationTrigger? { get set }
    /// How the trigger activates dictation: "hold" (press-to-talk) or "toggle"
    /// (hands-free lock — tap to start, tap/Esc to stop). See
    /// `ActivationInteraction`. In hold mode a quick double-tap still escalates
    /// to a locked session (the gesture path).
    var hotkeyMode: String { get set }
    /// Which single key triggers refine (held-to-talk). One of the ids in
    /// `RefineKey` (e.g. "rightOption"); "off" disables the refine key.
    var refineKey: String { get set }
    /// Dictation begins. `locked` is true for a hands-free (toggle/double-tap)
    /// session that stays open until an explicit stop/cancel; false for an
    /// ordinary press-to-talk hold.
    var onHotkeyDown: ((_ locked: Bool) -> Void)? { get set }
    /// Dictation ends normally (deliver the transcript) — the trigger release in
    /// hold mode, or the stop tap in toggle/locked mode.
    var onHotkeyUp: (() -> Void)? { get set }
    /// Refine key pressed (begin capturing a spoken instruction to refine the
    /// selection or last dictation). A dedicated chord, separate from dictation.
    var onRefineDown: (() -> Void)? { get set }
    /// Refine key released (end instruction capture; apply it).
    var onRefineUp: (() -> Void)? { get set }
    /// Cancel key (Esc) pressed during a session.
    var onCancel: (() -> Void)? { get set }
    /// Whether the OS granted the low-level event-capture permission. Surfaced so
    /// the UI can prompt the user to fix it.
    var onPermissionStateChanged: ((Bool) -> Void)? { get set }

    /// Force the activation interaction back to idle without emitting a callback —
    /// for when a session ends by a path OTHER than the trigger (silence safety
    /// auto-stop, an agent preempting the mic, a transcription error). Without it a
    /// locked session ended off-trigger would leave the machine thinking it's still
    /// open, so the next tap would read as a stop rather than a fresh start.
    func resetActivation()

    func start()
    func stop()
}

/// The press/release edge a raw key event implies, given the current held state.
///
/// All four macOS handlers (CGEvent/NSEvent × fn/control-space) reduce to the
/// same debounced edge detection — "transition to pressed" or "transition to
/// released," never re-firing while held. Centralizing it here makes that logic
/// pure and unit-tested instead of copy-pasted four times. Foundation-only.
enum HotkeyGesture: Equatable {
    /// The trigger just became active (fire `onHotkeyDown`).
    case down
    /// The trigger just became inactive (fire `onHotkeyUp`).
    case up
    /// No state change (held, or an unrelated event) — do nothing.
    case none

    /// - Parameters:
    ///   - isActive: whether the trigger condition holds for this event
    ///     (e.g. key is down with the right modifier, or the Fn flag is set).
    ///   - wasPressed: our current debounced "held" state.
    /// - Returns: the edge to act on. `down` only when becoming active from
    ///   not-pressed; `up` only when becoming inactive from pressed.
    static func resolve(isActive: Bool, wasPressed: Bool) -> HotkeyGesture {
        switch (isActive, wasPressed) {
        case (true, false): return .down
        case (false, true): return .up
        default:            return .none
        }
    }
}
