import Foundation

/// Pure decisions for the Sparkle auto-update preference (MAK-56), so the
/// "check for updates automatically" logic is unit-testable without linking
/// AppKit / Sparkle (which the `swift test` core target cannot).
///
/// The single decision here is what the automatic-check toggle resolves to on a
/// given launch. It defaults ON — matching `SUEnableAutomaticChecks` in
/// Info.plist — but a user who has explicitly toggled it OFF must have that
/// choice honored across launches. UserDefaults represents "never set" as `nil`
/// (via `object(forKey:)`), which is exactly the default-ON case; once the user
/// flips the switch, a concrete Bool is stored and wins.
///
/// Kept in OpenWhispCore (Foundation-only) intentionally: no Sparkle symbol is
/// referenced here, so the iOS companion and `swift test` both compile it.
public enum UpdatePreferences {
    /// The UserDefaults key backing the "check automatically" toggle.
    public static let automaticChecksKey = "sparkleAutomaticChecksEnabled"

    /// Resolve whether automatic update checks should be enabled.
    ///
    /// - Parameter storedValue: the persisted preference, or `nil` if the user
    ///   has never touched the toggle (fresh install / upgrade).
    /// - Returns: `true` when unset (default ON) or when explicitly enabled.
    public static func automaticChecksEnabled(storedValue: Bool?) -> Bool {
        storedValue ?? true
    }
}
