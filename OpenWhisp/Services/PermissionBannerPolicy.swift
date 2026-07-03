import Foundation

/// Pure decision logic for the launch-time permission recheck banners, so it can
/// be unit-tested independently of the SwiftUI/AppState layer.
///
/// Why this exists: reinstalling the app (e.g. from a fresh DMG) changes the
/// code signature, which makes macOS silently drop the TCC Accessibility grant.
/// Onboarding is gated on a persisted `didCompleteOnboarding` flag, so a
/// reinstalled app used to assume it was set up and never re-checked — hotkey
/// and text insertion were silently broken. The fix is to re-evaluate the LIVE
/// permission state on launch (and whenever the app becomes active) and surface
/// a gentle, dismissible banner per missing permission. This type decides WHICH
/// banners to show; reading the actual system state stays app-side.
struct PermissionBannerPolicy: Equatable {

    /// The permissions the recheck covers.
    enum Permission: String, CaseIterable, Equatable, Hashable {
        /// AXIsProcessTrusted() — required for text insertion and selection reading.
        case accessibility
        /// Inferred from whether the hotkey CGEventTap could be created — required
        /// for the global push-to-talk key. There is no direct "is granted" API.
        case inputMonitoring

        /// Short banner headline.
        var bannerTitle: String {
            switch self {
            case .accessibility:   return "Accessibility is off"
            case .inputMonitoring: return "Input Monitoring is off"
            }
        }

        /// One-sentence consequence + reassurance, in plain language.
        var bannerMessage: String {
            switch self {
            case .accessibility:
                return "OpenWhisp can't insert dictated text into other apps. This can happen after reinstalling — macOS forgets the permission for the new copy."
            case .inputMonitoring:
                return "Your dictation hotkey won't work until OpenWhisp can detect key presses. Enable OpenWhisp in the list, then return here."
            }
        }

        /// Label for the deep-link button into System Settings.
        var bannerButtonTitle: String { "Open System Settings" }
    }

    /// Banners the user dismissed for this session. Deliberately NOT persisted:
    /// persisting "don't show again" across launches would recreate the original
    /// bug (a stale flag hiding a live problem).
    private var dismissed: Set<Permission> = []

    init() {}

    /// Which banners to show given the live permission signals.
    ///
    /// - Parameters:
    ///   - accessibilityGranted: the live `AXIsProcessTrusted()` value. Never a
    ///     cached/persisted value — caching is exactly what broke reinstalls.
    ///   - inputMonitoringGranted: `nil` while unknown (before the event-tap
    ///     attempt has reported), otherwise the inferred granted state. Unknown
    ///     shows no banner — we only warn on a confirmed failure.
    ///
    /// Granting a permission clears its dismissal, so a later revocation (e.g.
    /// another reinstall) surfaces the banner again instead of staying muted.
    mutating func visibleBanners(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool?
    ) -> [Permission] {
        if accessibilityGranted { dismissed.remove(.accessibility) }
        if inputMonitoringGranted == true { dismissed.remove(.inputMonitoring) }

        var banners: [Permission] = []
        if !accessibilityGranted, !dismissed.contains(.accessibility) {
            banners.append(.accessibility)
        }
        if inputMonitoringGranted == false, !dismissed.contains(.inputMonitoring) {
            banners.append(.inputMonitoring)
        }
        return banners
    }

    /// Hide a banner for the rest of the session (until the permission is
    /// granted, which re-arms it — see `visibleBanners`).
    mutating func dismiss(_ permission: Permission) {
        dismissed.insert(permission)
    }
}
