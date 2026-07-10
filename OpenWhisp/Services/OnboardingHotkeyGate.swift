import Foundation

/// Pure decision logic for the onboarding hotkey + "try it" steps, so it can be
/// unit-tested independently of the SwiftUI/AppState layer.
///
/// Why this exists (MAK-24): onboarding used to check only Microphone and
/// Accessibility. A user could reach the "try it" step WITHOUT Input Monitoring
/// granted, so the global push-to-talk CGEventTap never fires — the very first
/// hotkey is dead and the test silently waits forever. macOS exposes a live
/// preflight for this (IOHIDCheckAccess for ListenEvent); this type turns that
/// live signal into the two UI decisions the onboarding flow needs, without
/// touching AppKit/IOKit so it stays testable.
enum OnboardingHotkeyGate {

    /// Live Input-Monitoring authorization, as reported by the platform preflight
    /// (IOHIDCheckAccess). `unknown` covers the case where we can't tell — we then
    /// trust rather than alarm.
    enum InputMonitoringStatus: Equatable {
        case granted
        case denied
        case unknown
    }

    /// What the hotkey step should tell the user about their push-to-talk key.
    enum HotkeyReadiness: Equatable {
        /// Input Monitoring is confirmed granted — the hotkey will fire.
        case ready
        /// Input Monitoring is confirmed denied — the hotkey CANNOT fire; show the
        /// inline "Open System Settings → Input Monitoring" fix + live re-check.
        case blocked
        /// We can't confirm the state (no signal yet) — proceed but keep the
        /// reassuring "macOS may ask…" note rather than a hard warning.
        case unconfirmed
    }

    /// Map the live preflight status to the hotkey step's readiness.
    static func readiness(inputMonitoring status: InputMonitoringStatus) -> HotkeyReadiness {
        switch status {
        case .granted: return .ready
        case .denied:  return .blocked
        case .unknown: return .unconfirmed
        }
    }

    /// Whether the "try it" step should warn that the hotkey can't fire. We only
    /// warn on a CONFIRMED denial — never on `unknown` (that would false-alarm on
    /// systems where we can't read the state). This is the guard that stops the
    /// flow from presenting a hotkey that is guaranteed dead.
    static func shouldWarnHotkeyDead(inputMonitoring status: InputMonitoringStatus) -> Bool {
        status == .denied
    }
}
