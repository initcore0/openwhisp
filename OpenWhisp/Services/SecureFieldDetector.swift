import Foundation
import ApplicationServices

/// Detects whether the system-wide focused UI element is a secure (password)
/// text field, using the Accessibility API. The pure decision logic lives in
/// `SecureFieldPolicy` (Foundation-only, unit-tested); this type only handles
/// the AX plumbing that can't run without a live UI.
///
/// Behavior is FAIL-OPEN: any AX error or unknown role/subrole returns `false`
/// (not secure), so dictation is never broken when the role can't be read. We
/// refuse to dictate ONLY when a secure field is positively detected.
enum SecureFieldDetector {

    /// Returns `true` only when the currently focused element is positively
    /// identified as a secure text field. Returns `false` on any AX error,
    /// missing attribute, or non-secure element (fail-open).
    static func focusedFieldIsSecure() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusErr == .success, let focused = focusedRef else {
            // Couldn't determine focus (no AX permission, nothing focused, etc.):
            // fail open and let dictation proceed.
            return false
        }
        // Safe: AX focused-element queries always return an AXUIElement.
        let element = focused as! AXUIElement

        let role = copyStringAttribute(element, kAXRoleAttribute)
        let subrole = copyStringAttribute(element, kAXSubroleAttribute)
        return SecureFieldPolicy.isSecure(role: role, subrole: subrole)
    }

    /// Copy a string-valued AX attribute, returning `nil` on any error or if the
    /// value isn't a string.
    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        return value as? String
    }
}
