import Foundation

/// Pure, Foundation-only decision logic for whether a focused UI element is a
/// *secure* (password) text field. Kept free of AppKit/ApplicationServices so it
/// can be unit-tested via SwiftPM (`swift test`); the AX-querying code lives in
/// `SecureFieldDetector` and calls into this policy.
///
/// The decision is intentionally conservative and FAIL-OPEN: only a positive
/// match on the secure subrole counts as secure. Anything unknown/nil/empty is
/// treated as *not* secure so dictation is never broken for everyone when the
/// Accessibility role can't be determined.
enum SecureFieldPolicy {

    /// The Accessibility subrole AppKit reports for password fields
    /// (`kAXSecureTextFieldSubrole`).
    static let secureTextFieldSubrole = "AXSecureTextField"

    /// Decide whether a focused element is a secure text field from its
    /// Accessibility role/subrole.
    ///
    /// - Parameters:
    ///   - role: The element's `kAXRoleAttribute` (e.g. "AXTextField"), if known.
    ///   - subrole: The element's `kAXSubroleAttribute` (e.g. "AXSecureTextField"), if known.
    /// - Returns: `true` only when the subrole positively identifies a secure
    ///   text field. Nil/unknown role or subrole returns `false` (fail-open).
    static func isSecure(role: String?, subrole: String?) -> Bool {
        isSecure(subrole: subrole)
    }

    /// Decide secureness from the subrole alone. The secure-field signal lives
    /// entirely in the subrole; the role is "AXTextField" for both normal and
    /// secure fields, so it carries no discriminating information here.
    static func isSecure(subrole: String?) -> Bool {
        guard let subrole = subrole?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subrole.isEmpty else {
            return false
        }
        // AX subroles are fixed identifier strings; match exactly (case-sensitive)
        // to avoid misclassifying an unrelated subrole that merely shares casing.
        return subrole == secureTextFieldSubrole
    }
}
