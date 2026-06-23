import Foundation

/// Platform-agnostic launch-at-login seam (Phase 2.5 core extraction).
///
/// AppState depends on this protocol instead of the concrete `SMAppService`
/// wrapper so the toggle logic is testable and a port can supply its own backend
/// (Windows: `Run` registry key / Startup folder / Task Scheduler; Linux: an
/// autostart `.desktop` entry).
protocol LaunchAtLoginService: AnyObject {
    /// The real, current system state — not a cached preference.
    var isEnabled: Bool { get }
    /// True when the OS has the login item registered but disabled pending user
    /// approval (macOS Login Items). Lets the UI explain a toggle that "didn't take".
    var requiresApproval: Bool { get }
    /// Register/unregister. Returns whether the requested state was applied.
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool
    /// Open the OS settings pane where the user can approve the login item.
    func openSettings()
}

/// Pure decision logic for reconciling a desired launch-at-login toggle against
/// what the system actually accepted. Foundation-only and unit-tested, so the
/// branchy re-sync behavior in AppState isn't trapped inside a `didSet`.
enum LaunchAtLoginReconciler {
    struct Outcome: Equatable {
        /// What the toggle should be set to (the real system state).
        var resolvedValue: Bool
        /// True when the user must approve the item in System Settings.
        var needsApprovalMessage: Bool
    }

    /// - Parameters:
    ///   - desired: the value the user toggled to.
    ///   - applied: whether `setEnabled(desired)` reported success.
    ///   - actual: the real system state read back after applying.
    ///   - requiresApproval: whether the system flagged the item as needing approval.
    static func reconcile(
        desired: Bool,
        applied: Bool,
        actual: Bool,
        requiresApproval: Bool
    ) -> Outcome {
        let diverged = (applied == false) || (actual != desired)
        return Outcome(
            resolvedValue: actual,
            needsApprovalMessage: diverged && requiresApproval
        )
    }
}
