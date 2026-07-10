import Foundation

/// A non-primary mouse button that can be bound as a dictation trigger (MAK-42).
///
/// macOS delivers non-primary mouse buttons through `otherMouseDown`/`otherMouseUp`
/// events carrying a `buttonNumber`: 2 = middle, 3 = "Mouse 4" (back), 4 = "Mouse 5"
/// (forward), and higher numbers for gaming-mouse side buttons. The left (0) and
/// right (1) buttons are deliberately NOT bindable — they're load-bearing for normal
/// clicking, and binding them would swallow every click.
///
/// A `MouseTrigger` maps 1:1 to a raw button number. It is stored/selected by a
/// stable string id (`"mouse2"` … `"mouse10"`, plus `"off"`), so the id↔button↔label
/// mapping can be `swift test`-ed without CGEventTap. The event-tap plumbing lives in
/// the app-only `HotkeyMonitor`.
enum MouseTrigger: Equatable {
    /// No mouse-button trigger bound.
    case off
    /// A bound non-primary mouse button, identified by its raw `otherMouse*`
    /// button number (>= 2; 0/1 are the non-bindable left/right buttons).
    case button(Int)

    /// The default for a fresh install: no mouse trigger (keyboard only).
    static let defaultTrigger: MouseTrigger = .off

    /// The lowest bindable button number. 0 (left) and 1 (right) are reserved.
    static let minButtonNumber = 2
    /// The highest button we offer in the picker (covers common gaming mice).
    static let maxButtonNumber = 10

    /// The raw `otherMouse*` button number for this trigger, or nil for `.off`.
    var buttonNumber: Int? {
        switch self {
        case .off:              return nil
        case .button(let n):    return n
        }
    }

    /// The stable id used for persistence and the settings picker.
    var id: String {
        switch self {
        case .off:              return "off"
        case .button(let n):    return "mouse\(n)"
        }
    }

    /// Parse a stored id back to a trigger. Unknown / out-of-range ids fall back to
    /// `.off` (never a crash, never an accidental left/right-button binding).
    static func from(id: String) -> MouseTrigger {
        if id == "off" { return .off }
        guard id.hasPrefix("mouse"),
              let n = Int(id.dropFirst("mouse".count)),
              isBindable(buttonNumber: n) else {
            return .off
        }
        return .button(n)
    }

    /// Only buttons within the bindable range (>= 2, up to the offered max) may be
    /// bound. Guards both the id parser and the live event tap so the left/right
    /// buttons can never become a trigger.
    static func isBindable(buttonNumber n: Int) -> Bool {
        n >= minButtonNumber && n <= maxButtonNumber
    }

    /// Human-readable label for the settings picker. Middle and the back/forward
    /// side buttons get familiar names; the rest are numbered "Mouse N" the way
    /// gaming-mouse software labels them (button 3 → "Mouse 4").
    var label: String {
        switch self {
        case .off:
            return "Off"
        case .button(2):
            return "Middle button"
        case .button(3):
            return "Mouse 4 (back)"
        case .button(4):
            return "Mouse 5 (forward)"
        case .button(let n):
            // Gaming-mouse convention: physical "Mouse N" = button number N+1.
            return "Mouse \(n + 1)"
        }
    }

    /// Every selectable option for the settings picker: Off, then each bindable
    /// button in order.
    static var allSelectable: [MouseTrigger] {
        [.off] + (minButtonNumber...maxButtonNumber).map { .button($0) }
    }
}
