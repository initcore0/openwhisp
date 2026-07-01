import Foundation

/// The selectable "refine" trigger key. A SINGLE key (held-to-talk), detected by
/// keycode — deliberately NOT a modifier chord like Fn+Ctrl, whose flag state
/// oscillates while held and made refine unusable. Right-hand modifiers are the
/// default choices: rarely used, comfortable to hold, and stable under the event
/// tap.
///
/// Foundation-only so it lives in OpenWhispCore and the id↔keycode mapping is
/// unit-tested without AppKit.
enum RefineKey: String, CaseIterable {
    case off
    case rightOption
    case rightCommand
    case rightControl
    case rightShift

    /// The virtual keycode for this key (from Carbon/HIToolbox kVK_* constants).
    /// nil for `.off`. Modifier keys report this keycode in flagsChanged events.
    var keyCode: Int64? {
        switch self {
        case .off:           return nil
        case .rightOption:   return 0x3D   // kVK_RightOption
        case .rightCommand:  return 0x36   // kVK_RightCommand
        case .rightControl:  return 0x3E   // kVK_RightControl
        case .rightShift:    return 0x3C   // kVK_RightShift
        }
    }

    /// Human-readable label for the settings picker.
    var label: String {
        switch self {
        case .off:           return "Off"
        case .rightOption:   return "Right Option (⌥)"
        case .rightCommand:  return "Right Command (⌘)"
        case .rightControl:  return "Right Control (⌃)"
        case .rightShift:    return "Right Shift (⇧)"
        }
    }

    /// Short glyph for status/overlay hints.
    var glyph: String {
        switch self {
        case .off:           return ""
        case .rightOption:   return "⌥"
        case .rightCommand:  return "⌘"
        case .rightControl:  return "⌃"
        case .rightShift:    return "⇧"
        }
    }

    static func from(id: String) -> RefineKey {
        RefineKey(rawValue: id) ?? .rightOption
    }
}
