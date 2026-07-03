import Foundation

/// The selectable "refine" trigger key. A SINGLE key (held-to-talk), detected by
/// keycode — deliberately NOT a modifier chord like Fn+Ctrl, whose flag state
/// oscillates while held and made refine unusable.
///
/// Left-hand modifiers are offered alongside the right-hand ones because
/// MacBook keyboards have NO right Control key at all (the original default),
/// and compact layouts vary — the default is Left Control, which exists on
/// every Mac keyboard. Control keys conflict with the Control+Space dictation
/// trigger; see `conflictsWithTrigger`.
///
/// Foundation-only so it lives in OpenWhispCore and the id↔keycode mapping is
/// unit-tested without AppKit.
enum RefineKey: String, CaseIterable {
    case off
    case leftControl
    case leftOption
    case leftCommand
    case rightCommand
    case rightOption
    case rightShift
    case rightControl

    /// The default for a fresh install: present on every Mac keyboard and
    /// comfortable to tap while Fn (the default dictation key) is held.
    static let defaultKey: RefineKey = .leftControl

    /// The virtual keycode for this key (from Carbon/HIToolbox kVK_* constants).
    /// nil for `.off`. Modifier keys report this keycode in flagsChanged events.
    var keyCode: Int64? {
        switch self {
        case .off:           return nil
        case .leftControl:   return 0x3B   // kVK_Control
        case .leftOption:    return 0x3A   // kVK_Option
        case .leftCommand:   return 0x37   // kVK_Command
        case .rightCommand:  return 0x36   // kVK_RightCommand
        case .rightOption:   return 0x3D   // kVK_RightOption
        case .rightShift:    return 0x3C   // kVK_RightShift
        case .rightControl:  return 0x3E   // kVK_RightControl
        }
    }

    /// Human-readable label for the settings picker.
    var label: String {
        switch self {
        case .off:           return "Off"
        case .leftControl:   return "Left Control (⌃)"
        case .leftOption:    return "Left Option (⌥)"
        case .leftCommand:   return "Left Command (⌘)"
        case .rightCommand:  return "Right Command (⌘)"
        case .rightOption:   return "Right Option (⌥)"
        case .rightShift:    return "Right Shift (⇧)"
        case .rightControl:  return "Right Control (⌃) — not on MacBook keyboards"
        }
    }

    /// Short glyph for status/overlay hints.
    var glyph: String {
        switch self {
        case .off:                          return ""
        case .leftControl, .rightControl:   return "⌃"
        case .leftOption, .rightOption:     return "⌥"
        case .leftCommand, .rightCommand:   return "⌘"
        case .rightShift:                   return "⇧"
        }
    }

    /// True when this key can't coexist with the given dictation trigger:
    /// Control+Space matches EITHER Control key, so holding Control to start
    /// dictation would read as a refine tap. The hotkey monitor suppresses the
    /// combination and the Settings UI warns about it.
    func conflictsWithTrigger(_ triggerMode: String) -> Bool {
        triggerMode == "controlSpace" && (self == .leftControl || self == .rightControl)
    }

    static func from(id: String) -> RefineKey {
        RefineKey(rawValue: id) ?? defaultKey
    }
}
