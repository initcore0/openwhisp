import Foundation
import ApplicationServices

/// MAK-34 — the app-side Accessibility read for screen-context awareness.
///
/// Reads the currently-focused element's whole text value via the same
/// system-wide AX plumbing used by `SelectionReader` / `TextInserter` /
/// `SecureFieldDetector`. Kept out of `OpenWhispCore` (it needs
/// `ApplicationServices`); the pure logic that decides *whether* to call this and
/// what to do with the result lives in `ScreenContext.swift` (unit-tested).
///
/// This type ONLY reads — it never writes, never persists, and returns nothing
/// when AX isn't trusted or the field can't be read (fail-closed here: no read ⇒
/// no context, which is the safe default for a privacy feature).
///
/// SECURITY: the caller MUST have already cleared `ScreenContextGate` (opt-in,
/// per-app allowlist, NOT a secure field). This reader re-checks the secure-field
/// signal itself as belt-and-suspenders so it can never return the contents of a
/// password field even if a caller forgets the gate.
enum ScreenContextReader {

    /// The focused field's existing text, or nil when unavailable / disallowed.
    /// Returns nil for a secure field regardless of what the caller passed.
    static func readFocusedFieldText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard focusErr == .success, let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        // Belt-and-suspenders: never read a secure field's value, even though the
        // caller is expected to have gated on this already.
        let role = copyStringAttribute(element, kAXRoleAttribute)
        let subrole = copyStringAttribute(element, kAXSubroleAttribute)
        if SecureFieldPolicy.isSecure(role: role, subrole: subrole) { return nil }

        guard let value = copyStringAttribute(element, kAXValueAttribute) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        return value as? String
    }
}
