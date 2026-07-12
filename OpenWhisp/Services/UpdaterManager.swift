import Foundation

#if SPARKLE
import Sparkle
import AppKit

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` (MAK-56).
///
/// Menu-bar (LSUIElement / accessory) apps have no main window, but Sparkle 2's
/// standard user driver drives its own windows, so nothing extra is needed —
/// `SPUStandardUpdaterController(startingUpdater:…)` works from a background app.
///
/// The whole type is gated behind `#if SPARKLE`: a `SPARKLE=0` lean build (CI's
/// lean variant, forks that don't want the framework) compiles a no-op stand-in
/// below, so the rest of the app can reference `UpdaterManager.shared`
/// unconditionally.
@MainActor
final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    private override init() {
        // startingUpdater:true starts the update cycle immediately. The feed URL,
        // public EdDSA key, and SUEnableAutomaticChecks default all come from
        // Info.plist — no code configuration needed.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        // Honor the user's explicit persisted choice. Sparkle already respects
        // SUEnableAutomaticChecks for the never-set case; we only override when a
        // concrete value was stored (the resolver treats nil as "default ON").
        let stored = UserDefaults.standard.object(forKey: UpdatePreferences.automaticChecksKey) as? Bool
        controller.updater.automaticallyChecksForUpdates =
            UpdatePreferences.automaticChecksEnabled(storedValue: stored)
    }

    /// Whether Sparkle is compiled in (true in this build variant).
    var isAvailable: Bool { true }

    /// Reflects Sparkle's live automatic-check state.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            // Persist so the choice survives relaunch (see UpdatePreferences).
            UserDefaults.standard.set(newValue, forKey: UpdatePreferences.automaticChecksKey)
        }
    }

    /// Present Sparkle's "Check for Updates…" flow (manual, user-initiated).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

#else

import AppKit

/// SPARKLE=0 lean build: a no-op stand-in so call sites compile unchanged. The
/// Settings pane hides the update controls when `isAvailable` is false.
@MainActor
final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()
    private override init() { super.init() }

    var isAvailable: Bool { false }
    var automaticallyChecksForUpdates: Bool {
        get { false }
        set { _ = newValue }
    }
    func checkForUpdates() {}
}

#endif
