import Foundation
import ServiceManagement
import AppKit

/// macOS `SMAppService.mainApp`-backed `LaunchAtLoginService` (macOS 13+):
/// registers the app as a login item so it relaunches after a reboot / re-login.
///
/// Unlike the legacy `SMLoginItemSetEnabled` / login-items-list approaches, this
/// requires no helper bundle and no manual user step — the app registers itself.
/// Requires a proper signed `.app` bundle (the same requirement we already have
/// for notifications / mic permissions).
///
/// The Apple-only `ServiceManagement` / `AppKit` calls are isolated here; AppState
/// depends on the `LaunchAtLoginService` protocol, not this type.
final class LaunchAtLogin: LaunchAtLoginService {

    /// Whether the app is currently registered to launch at login.
    /// Reflects the real system state, not a cached preference.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `true` when the user has disabled the login item in System Settings >
    /// General > Login Items (we can re-register, but macOS keeps it off until
    /// the user re-approves). Surfaced so the UI can explain why a toggle
    /// "didn't take".
    var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Register or unregister the app as a login item.
    /// - Returns: `true` if the requested state was applied successfully.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                // Re-registering when already enabled is harmless.
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
            return true
        } catch {
            print("[LaunchAtLogin] failed to set enabled=\(enabled): \(error.localizedDescription)")
            return false
        }
    }

    /// Open System Settings to the Login Items pane so the user can approve the
    /// item if macOS has flagged it as requiring approval.
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
