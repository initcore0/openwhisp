import Foundation

/// The set of modifier keys a custom dictation trigger requires. A bitmask so it
/// persists as a single Int (`rawValue`) and maps cleanly onto both the Carbon
/// keycodes and the CGEvent/NSEvent modifier flags the macOS monitor inspects.
///
/// Deliberately side-agnostic (Command, not Left/Right Command): the dictation
/// trigger is a chord you press deliberately, so "any Command" is the friendly
/// behaviour — unlike the refine key, which is a single side-specific modifier
/// tap. Foundation-only so it lives in OpenWhispCore and is unit-tested without
/// AppKit.
struct TriggerModifiers: OptionSet, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = TriggerModifiers(rawValue: 1 << 0)
    static let option  = TriggerModifiers(rawValue: 1 << 1)
    static let shift   = TriggerModifiers(rawValue: 1 << 2)
    static let command = TriggerModifiers(rawValue: 1 << 3)
    /// The Fn/Globe modifier. Rarely combinable, but a valid lone trigger.
    static let function = TriggerModifiers(rawValue: 1 << 4)

    /// In the order they appear in a macOS shortcut glyph string (⌃⌥⇧⌘).
    static let displayOrder: [(TriggerModifiers, String, String)] = [
        (.control,  "⌃", "Control"),
        (.option,   "⌥", "Option"),
        (.shift,    "⇧", "Shift"),
        (.command,  "⌘", "Command"),
        (.function, "🌐", "Fn"),
    ]

    /// Concatenated glyphs (⌃⇧ …) in canonical order; empty when no modifiers.
    var glyphs: String {
        Self.displayOrder.reduce(into: "") { acc, entry in
            if contains(entry.0) { acc += entry.1 }
        }
    }
}

/// A fully-remappable dictation trigger (MAK-17): either one of the two built-in
/// quick-pick presets (Fn/Globe, Control+Space) or an arbitrary user-recorded
/// keycode + modifier combo. Generalizes the old two-value `triggerMode` string
/// while staying backward compatible — "fn" and "controlSpace" are still the
/// persisted mode ids, and "custom" selects the recorded binding.
///
/// Pure/Foundation-only: the keycode→flag matching against real CGEvents lives in
/// the app-only `HotkeyMonitor`; everything here (preset mapping, display-name
/// formatting, conflict detection) is unit-tested in OpenWhispCore.
struct DictationTrigger: Equatable {
    /// The primary (non-modifier) key's virtual keycode, or nil when the trigger
    /// is a bare modifier (e.g. Fn alone). Modifiers are carried separately.
    let keyCode: Int64?
    /// Required modifier chord. For a bare-modifier trigger like Fn this is the
    /// modifier itself with `keyCode == nil`.
    let modifiers: TriggerModifiers

    // MARK: - Well-known keycodes (Carbon kVK_*)

    static let spaceKeyCode: Int64 = 0x31   // kVK_Space
    static let fnKeyCode: Int64 = 0x3F      // kVK_Function

    // MARK: - Presets

    /// The Fn/Globe preset: a bare Fn modifier, no primary key.
    static let fn = DictationTrigger(keyCode: nil, modifiers: .function)
    /// The Control+Space preset.
    static let controlSpace = DictationTrigger(keyCode: spaceKeyCode, modifiers: .control)

    /// Resolve the effective trigger from the persisted settings triple. `mode`
    /// is the discriminator ("fn" | "controlSpace" | "custom"); the custom
    /// keycode/modifiers are only consulted for "custom". A "custom" mode with no
    /// usable binding (nil keycode AND no modifiers) falls back to the Fn preset
    /// so dictation is never left with no trigger at all.
    static func resolve(mode: String, customKeyCode: Int64?, customModifiers: TriggerModifiers) -> DictationTrigger {
        switch mode {
        case "fn":           return .fn
        case "controlSpace": return .controlSpace
        case "custom":
            let candidate = DictationTrigger(keyCode: customKeyCode, modifiers: customModifiers)
            return candidate.isBindable ? candidate : .fn
        default:             return .fn
        }
    }

    /// True when this binding can actually fire: it has either a primary key or at
    /// least one modifier. An all-empty binding can never match an event.
    var isBindable: Bool {
        keyCode != nil || !modifiers.isEmpty
    }

    /// Which of the two quick-pick presets this binding equals, if any — so the
    /// UI can highlight a preset instead of showing "Custom" when a recorded
    /// combo happens to match one. nil for a genuinely custom binding.
    var matchingPresetMode: String? {
        if self == .fn { return "fn" }
        if self == .controlSpace { return "controlSpace" }
        return nil
    }

    // MARK: - Display

    /// Human-readable shortcut, e.g. "⌃Space", "Fn (Globe)", "⌥⌘R".
    var displayName: String {
        // Preset niceties first.
        if self == .fn { return "Fn (Globe)" }
        if self == .controlSpace { return "Control + Space" }

        let mods = modifiers.glyphs
        guard let keyCode else {
            // Bare-modifier trigger: name the modifier(s).
            let names = TriggerModifiers.displayOrder
                .filter { modifiers.contains($0.0) }
                .map { $0.2 }
            return names.isEmpty ? "None" : names.joined(separator: " + ")
        }
        let key = Self.keyName(for: keyCode)
        return mods.isEmpty ? key : "\(mods)\(key)"
    }

    /// A short label for the primary key of a keycode. Covers the common keys a
    /// user is likely to bind; unknown codes render as "Key 0x…" so the UI is
    /// never blank. Foundation-only (no AppKit key-translation).
    static func keyName(for keyCode: Int64) -> String {
        if let named = namedKeys[keyCode] { return named }
        return "Key 0x\(String(keyCode, radix: 16, uppercase: true))"
    }

    private static let namedKeys: [Int64: String] = [
        0x31: "Space", 0x24: "Return", 0x30: "Tab", 0x33: "Delete",
        0x35: "Esc", 0x39: "Caps Lock", 0x3F: "Fn",
        // Letters (kVK_ANSI_*)
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        // Digits
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        // Function row
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        // Arrows
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        // Punctuation likely to be bound
        0x2B: ",", 0x2F: ".", 0x2C: "/", 0x29: ";", 0x27: "'", 0x21: "[",
        0x1E: "]", 0x2A: "\\", 0x32: "`", 0x1B: "-", 0x18: "=",
    ]

    // MARK: - Conflict detection

    /// A reason a candidate binding is a bad idea, for the capture UI's warning.
    enum Conflict: Equatable {
        /// Collides with the selected refine key (they'd fight for the same tap).
        case refineKey
        /// A no-modifier single key would fire on ordinary typing.
        case bareKey
        /// A well-known system shortcut (⌘Space Spotlight, ⌘Tab, ⌘Q…).
        case systemShortcut(String)
    }

    /// Detect why a candidate custom trigger is problematic, or nil if it's fine.
    /// Ordered by severity: an unusable bare key first, then a system-shortcut
    /// clash, then a refine-key clash (a warning the user can still accept).
    func conflict(refineKey: RefineKey) -> Conflict? {
        // A primary key with NO modifiers would trigger on normal typing (except
        // the dedicated Fn key and the function row / Esc, which aren't text).
        if let keyCode, modifiers.isEmpty, Self.isTypingKey(keyCode) {
            return .bareKey
        }
        if let name = systemShortcutName {
            return .systemShortcut(name)
        }
        if clashesWithRefineKey(refineKey) {
            return .refineKey
        }
        return nil
    }

    /// The name of the reserved system shortcut this binding shadows, if any.
    var systemShortcutName: String? {
        guard let keyCode else { return nil }
        for (code, mods, name) in Self.reservedShortcuts where code == keyCode && modifiers == mods {
            return name
        }
        return nil
    }

    /// Common macOS shortcuts a trigger must not steal. Not exhaustive — the
    /// worst offenders that would make the Mac unusable if swallowed.
    private static let reservedShortcuts: [(Int64, TriggerModifiers, String)] = [
        (0x31, .command,             "Spotlight (⌘Space)"),
        (0x30, .command,             "App Switcher (⌘Tab)"),
        (0x0C, .command,             "Quit (⌘Q)"),
        (0x0D, .command,             "Close Window (⌘W)"),
        (0x08, .command,             "Copy (⌘C)"),
        (0x09, .command,             "Paste (⌘V)"),
        (0x07, .command,             "Cut (⌘X)"),
        (0x00, .command,             "Select All (⌘A)"),
        (0x06, .command,             "Undo (⌘Z)"),
        (0x1D, [.command, .option],  "Force Quit (⌘⌥Esc)"),
        (0x31, [.command, .option],  "Spotlight window search"),
    ]

    /// True when the trigger would collide with the refine key. The refine key is
    /// a single held modifier; a trigger clashes if it's the *same lone modifier*
    /// (both would react to the same tap) — mirrors RefineKey.conflictsWithTrigger
    /// but generalized to arbitrary bindings.
    func clashesWithRefineKey(_ refineKey: RefineKey) -> Bool {
        guard let refineMod = Self.modifier(forRefineKey: refineKey) else { return false }
        // Only a bare-modifier trigger equal to exactly the refine modifier
        // clashes; a chord (e.g. ⌥Space) coexists fine with a lone-⌥ refine tap
        // because the refine tap recognizer already rejects chorded holds.
        return keyCode == nil && modifiers == refineMod
    }

    /// Which side-agnostic trigger modifier a refine key corresponds to. nil for
    /// `.off` (no refine key) or refine keys with no trigger-modifier analogue.
    static func modifier(forRefineKey refineKey: RefineKey) -> TriggerModifiers? {
        switch refineKey {
        case .off: return nil
        case .leftControl, .rightControl:  return .control
        case .leftOption, .rightOption:    return .option
        case .leftCommand, .rightCommand:  return .command
        case .rightShift:                  return .shift
        }
    }

    /// Whether a keycode produces text when typed alone (so binding it with no
    /// modifier would be a disaster). Letters, digits, punctuation, Space, Return,
    /// Tab, Delete. The function row, Esc, arrows, and Fn are safe as lone keys.
    static func isTypingKey(_ keyCode: Int64) -> Bool {
        typingKeyCodes.contains(keyCode)
    }

    private static let typingKeyCodes: Set<Int64> = {
        var codes: Set<Int64> = [0x31, 0x24, 0x30, 0x33] // Space, Return, Tab, Delete
        // Letters
        codes.formUnion([0x00,0x0B,0x08,0x02,0x0E,0x03,0x05,0x04,0x22,0x26,0x28,0x25,
                         0x2E,0x2D,0x1F,0x23,0x0C,0x0F,0x01,0x11,0x20,0x09,0x0D,0x07,0x10,0x06])
        // Digits
        codes.formUnion([0x1D,0x12,0x13,0x14,0x15,0x17,0x16,0x1A,0x1C,0x19])
        // Punctuation
        codes.formUnion([0x2B,0x2F,0x2C,0x29,0x27,0x21,0x1E,0x2A,0x32,0x1B,0x18])
        return codes
    }()
}
