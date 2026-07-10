import XCTest
@testable import OpenWhispCore

final class DictationTriggerTests: XCTestCase {

    // MARK: - Preset resolution & round-trip

    func testResolvePresets() {
        XCTAssertEqual(DictationTrigger.resolve(mode: "fn", customKeyCode: nil, customModifiers: []), .fn)
        XCTAssertEqual(DictationTrigger.resolve(mode: "controlSpace", customKeyCode: nil, customModifiers: []), .controlSpace)
    }

    func testResolveUnknownModeFallsBackToFn() {
        XCTAssertEqual(DictationTrigger.resolve(mode: "bogus", customKeyCode: 0x0F, customModifiers: .command), .fn)
    }

    func testResolveCustom() {
        let t = DictationTrigger.resolve(mode: "custom", customKeyCode: 0x0F, customModifiers: [.command, .option])
        XCTAssertEqual(t.keyCode, 0x0F)
        XCTAssertEqual(t.modifiers, [.command, .option])
    }

    func testResolveEmptyCustomFallsBackToFn() {
        // A "custom" mode with nothing recorded must never leave dictation with no
        // trigger at all.
        XCTAssertEqual(DictationTrigger.resolve(mode: "custom", customKeyCode: nil, customModifiers: []), .fn)
    }

    func testCustomBareModifierIsBindable() {
        let t = DictationTrigger.resolve(mode: "custom", customKeyCode: nil, customModifiers: .option)
        XCTAssertEqual(t.modifiers, .option)
        XCTAssertNil(t.keyCode)
        XCTAssertTrue(t.isBindable)
    }

    // MARK: - Preset detection

    func testMatchingPresetMode() {
        XCTAssertEqual(DictationTrigger.fn.matchingPresetMode, "fn")
        XCTAssertEqual(DictationTrigger.controlSpace.matchingPresetMode, "controlSpace")
        XCTAssertNil(DictationTrigger(keyCode: 0x0F, modifiers: [.command, .option]).matchingPresetMode)
    }

    func testCustomThatEqualsPresetIsRecognized() {
        // Recording Control+Space by hand should map back to the preset.
        let recorded = DictationTrigger(keyCode: DictationTrigger.spaceKeyCode, modifiers: .control)
        XCTAssertEqual(recorded.matchingPresetMode, "controlSpace")
    }

    // MARK: - Display names

    func testDisplayNamePresets() {
        XCTAssertEqual(DictationTrigger.fn.displayName, "Fn (Globe)")
        XCTAssertEqual(DictationTrigger.controlSpace.displayName, "Control + Space")
    }

    func testDisplayNameChord() {
        XCTAssertEqual(DictationTrigger(keyCode: 0x0F, modifiers: [.option, .command]).displayName, "⌥⌘R")
        XCTAssertEqual(DictationTrigger(keyCode: 0x31, modifiers: [.control, .shift]).displayName, "⌃⇧Space")
    }

    func testDisplayNameGlyphOrderIsCanonical() {
        // Regardless of insertion order, glyphs come out ⌃⌥⇧⌘.
        let t = DictationTrigger(keyCode: 0x00, modifiers: [.command, .control, .shift, .option])
        XCTAssertEqual(t.displayName, "⌃⌥⇧⌘A")
    }

    func testDisplayNameBareModifier() {
        XCTAssertEqual(DictationTrigger(keyCode: nil, modifiers: .option).displayName, "Option")
        XCTAssertEqual(DictationTrigger(keyCode: nil, modifiers: [.control, .command]).displayName, "Control + Command")
    }

    func testDisplayNameNoModifierKey() {
        XCTAssertEqual(DictationTrigger(keyCode: 0x7A, modifiers: []).displayName, "F1")
    }

    func testKeyNameFallbackForUnknownCode() {
        XCTAssertEqual(DictationTrigger.keyName(for: 0x99), "Key 0x99")
    }

    func testEveryNamedKeyRoundTrips() {
        // Space and letters must produce their expected labels.
        XCTAssertEqual(DictationTrigger.keyName(for: 0x31), "Space")
        XCTAssertEqual(DictationTrigger.keyName(for: 0x35), "Esc")
        XCTAssertEqual(DictationTrigger.keyName(for: 0x00), "A")
    }

    // MARK: - Modifier glyphs

    func testModifierGlyphs() {
        XCTAssertEqual(TriggerModifiers([.control, .command]).glyphs, "⌃⌘")
        XCTAssertEqual(TriggerModifiers([]).glyphs, "")
        XCTAssertEqual(TriggerModifiers.function.glyphs, "🌐")
    }

    // MARK: - Bare-key conflict

    func testBareTypingKeyIsAConflict() {
        // A letter with no modifier would fire on ordinary typing.
        let t = DictationTrigger(keyCode: 0x00, modifiers: []) // A
        XCTAssertEqual(t.conflict(refineKey: .off), .bareKey)
    }

    func testBareFunctionKeyIsNotAConflict() {
        // F-row keys don't produce text, so a lone binding is fine.
        XCTAssertNil(DictationTrigger(keyCode: 0x7A, modifiers: []).conflict(refineKey: .off)) // F1
    }

    // MARK: - Escape conflict

    func testEscapeKeyIsAlwaysAConflict() {
        // Esc is the session cancel key: an Esc trigger (with ANY modifiers)
        // would cancel the session it just started.
        XCTAssertEqual(DictationTrigger(keyCode: 0x35, modifiers: []).conflict(refineKey: .off), .escapeKey)
        XCTAssertEqual(DictationTrigger(keyCode: 0x35, modifiers: [.command, .option]).conflict(refineKey: .off), .escapeKey)
    }

    func testForceQuitDigitZeroIsNotFalselyReserved() {
        // ⌘⌥0 (keycode 0x1D is the digit 0, NOT Esc) must not be flagged as
        // Force Quit — regression for a wrong-keycode reserved entry.
        XCTAssertNil(DictationTrigger(keyCode: 0x1D, modifiers: [.command, .option]).conflict(refineKey: .off))
    }

    func testModifiedTypingKeyIsNotBareConflict() {
        // ⌥A is a fine deliberate chord.
        XCTAssertNil(DictationTrigger(keyCode: 0x00, modifiers: .option).conflict(refineKey: .off))
    }

    // MARK: - System-shortcut conflict

    func testSpotlightConflict() {
        let t = DictationTrigger(keyCode: 0x31, modifiers: .command) // ⌘Space
        XCTAssertEqual(t.conflict(refineKey: .off), .systemShortcut("Spotlight (⌘Space)"))
    }

    func testQuitConflict() {
        let t = DictationTrigger(keyCode: 0x0C, modifiers: .command) // ⌘Q
        XCTAssertEqual(t.conflict(refineKey: .off), .systemShortcut("Quit (⌘Q)"))
    }

    func testNonReservedChordHasNoSystemConflict() {
        // ⌥⌘R isn't a reserved system shortcut.
        XCTAssertNil(DictationTrigger(keyCode: 0x0F, modifiers: [.option, .command]).systemShortcutName)
    }

    // MARK: - Refine-key conflict

    func testBareModifierClashesWithSameRefineKey() {
        // A lone-Option trigger fights an Option refine key.
        let t = DictationTrigger(keyCode: nil, modifiers: .option)
        XCTAssertEqual(t.conflict(refineKey: .leftOption), .refineKey)
        XCTAssertEqual(t.conflict(refineKey: .rightOption), .refineKey)
        XCTAssertTrue(t.clashesWithRefineKey(.leftOption))
    }

    func testBareModifierDoesNotClashWithDifferentRefineKey() {
        let t = DictationTrigger(keyCode: nil, modifiers: .option)
        XCTAssertNil(t.conflict(refineKey: .leftControl))
        XCTAssertNil(t.conflict(refineKey: .off))
    }

    func testChordDoesNotClashWithRefineKey() {
        // ⌥Space (a chord) coexists with a lone-Option refine tap.
        let t = DictationTrigger(keyCode: DictationTrigger.spaceKeyCode, modifiers: .option)
        XCTAssertFalse(t.clashesWithRefineKey(.leftOption))
        XCTAssertNil(t.conflict(refineKey: .leftOption))
    }

    func testRefineKeyModifierMapping() {
        XCTAssertEqual(DictationTrigger.modifier(forRefineKey: .leftControl), .control)
        XCTAssertEqual(DictationTrigger.modifier(forRefineKey: .rightShift), .shift)
        XCTAssertEqual(DictationTrigger.modifier(forRefineKey: .leftCommand), .command)
        XCTAssertNil(DictationTrigger.modifier(forRefineKey: .off))
    }

    // MARK: - Event-flag matching (exact vs. superset)

    private let ctrl = DictationTrigger.EventFlagBits.control
    private let opt  = DictationTrigger.EventFlagBits.option
    private let shft = DictationTrigger.EventFlagBits.shift
    private let cmd  = DictationTrigger.EventFlagBits.command
    private let fn   = DictationTrigger.EventFlagBits.function

    func testModifiersHeldIsSupersetMatch() {
        XCTAssertTrue(DictationTrigger.modifiersHeld([.command, .shift], rawFlags: cmd | shft))
        // Extra modifier held: still satisfied (keeps an active session alive).
        XCTAssertTrue(DictationTrigger.modifiersHeld([.command, .shift], rawFlags: cmd | shft | opt))
        // Missing a required modifier: not held.
        XCTAssertFalse(DictationTrigger.modifiersHeld([.command, .shift], rawFlags: cmd))
    }

    func testModifiersExactlyRejectsExtraModifiers() {
        // A ⌘⇧X binding must NOT activate on ⌘⇧⌥X — that's a different shortcut.
        XCTAssertTrue(DictationTrigger.modifiersExactly([.command, .shift], rawFlags: cmd | shft))
        XCTAssertFalse(DictationTrigger.modifiersExactly([.command, .shift], rawFlags: cmd | shft | opt))
        XCTAssertFalse(DictationTrigger.modifiersExactly([.command, .shift], rawFlags: cmd))
        // A lone-⌥ trigger must not fire inside an ⌥⌘ chord.
        XCTAssertFalse(DictationTrigger.modifiersExactly(.option, rawFlags: opt | cmd))
        XCTAssertTrue(DictationTrigger.modifiersExactly(.option, rawFlags: opt))
    }

    func testExactMatchToleratesImplicitFnFlag() {
        // Arrows/F-keys set the Fn flag implicitly — a ⌘← binding must still
        // activate even though the event carries the Fn bit.
        XCTAssertTrue(DictationTrigger.modifiersExactly(.command, rawFlags: cmd | fn))
        // But a required Fn is still required.
        XCTAssertFalse(DictationTrigger.modifiersExactly([.command, .function], rawFlags: cmd))
        XCTAssertTrue(DictationTrigger.modifiersExactly([.command, .function], rawFlags: cmd | fn))
    }

    func testImpliesFnFlag() {
        XCTAssertTrue(DictationTrigger.impliesFnFlag(0x7B))  // ←
        XCTAssertTrue(DictationTrigger.impliesFnFlag(0x7A))  // F1
        XCTAssertFalse(DictationTrigger.impliesFnFlag(0x0F)) // R
        XCTAssertFalse(DictationTrigger.impliesFnFlag(DictationTrigger.spaceKeyCode))
    }

    // MARK: - Conflict severity ordering

    func testSystemShortcutTakesPrecedenceOverRefineClash() {
        // ⌘Space is both reserved AND could be a refine command clash target;
        // system shortcut is the reported reason (higher severity).
        let t = DictationTrigger(keyCode: 0x31, modifiers: .command)
        XCTAssertEqual(t.conflict(refineKey: .leftCommand), .systemShortcut("Spotlight (⌘Space)"))
    }
}
