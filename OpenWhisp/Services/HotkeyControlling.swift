import Foundation

/// Platform-agnostic global-hotkey seam (Phase 2.5 core extraction).
///
/// AppState depends on this protocol instead of the concrete macOS
/// `HotkeyMonitor` (CGEventTap + NSEvent), so a port supplies its own backend
/// (Windows: `RegisterHotKey` / `WH_KEYBOARD_LL`). The callbacks carry no
/// platform types, so the orchestration in AppState never names AppKit.
protocol HotkeyControlling: AnyObject {
    /// Which gesture triggers dictation: "fn" or "controlSpace".
    var triggerMode: String { get set }
    /// Push-to-talk pressed (begin dictation).
    var onHotkeyDown: (() -> Void)? { get set }
    /// Push-to-talk released (end dictation).
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
