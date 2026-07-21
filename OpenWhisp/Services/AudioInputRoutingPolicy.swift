import Foundation

/// Pure decision logic for routing dictation capture to a chosen input device.
///
/// Foundation-only (no CoreAudio) so it lives in OpenWhispCore and is unit-testable
/// without a live audio stack. The concrete CoreAudio resolution + application lives
/// app-side in `AudioInputRouter` (macOS only); this type answers only *what should
/// happen* given the stored `microphoneID` setting and whether that UID resolved to a
/// real device.
///
/// The stored `microphoneID` is a device **UID** (what the Settings picker tags each
/// device with), or the empty string meaning "follow the system default input".
enum AudioInputRoutingPolicy {

    /// What the capture layer should do for a given `microphoneID` setting.
    enum Decision: Equatable {
        /// No specific device pinned — capture from whatever the OS default input is.
        case systemDefault
        /// Route capture to the pinned device (carrying the trimmed UID; the caller
        /// re-resolves it to a live device at application time).
        case useDevice(uid: String)
        /// A device WAS pinned but isn't currently connected (its UID no longer
        /// matches any enumerated input — e.g. AirPods put back in their case).
        /// Capture proceeds on the SYSTEM DEFAULT input and the caller surfaces
        /// `fallbackNotice` so the user knows which mic is live. The pinned UID is
        /// kept in settings, so the device is used again the moment it reconnects.
        ///
        /// This is distinct from the historical silent-wrong-mic bug: that bug was a
        /// CONNECTED selection whose routing was never applied (or failed to apply),
        /// which remains a hard error at the `useDevice` application sites. Refusing
        /// to capture at all for a disconnected mic just wedged the session at
        /// "Starting…" with no path forward (the AirPods-disconnect hang).
        case fallbackToDefault(uid: String)
    }

    /// Decide how to route, given the stored setting and whether the resolver found a
    /// matching device. `deviceResolved` is the app-side CoreAudio lookup result
    /// (`AudioInputRouter.resolve(uid:) != nil`); passing it in keeps this pure.
    ///
    /// - `microphoneID` empty  → `.systemDefault` (regardless of `deviceResolved`).
    /// - non-empty + resolved  → `.useDevice`.
    /// - non-empty + unresolved → `.fallbackToDefault` (caller captures the system
    ///   default and surfaces `fallbackNotice`).
    static func decide(microphoneID: String, deviceResolved: Bool) -> Decision {
        let uid = microphoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return .systemDefault }
        return deviceResolved ? .useDevice(uid: uid) : .fallbackToDefault(uid: uid)
    }

    /// User-facing message when a pinned device is CONNECTED but routing capture to
    /// it failed (resolve/apply raced a disconnect or CoreAudio refused the switch).
    /// Kept identical across the capture paths that surface it.
    static func unresolvedMessage(uid: String) -> String {
        "Selected microphone isn't available. Reconnect it or pick another in Settings → Dictation."
    }

    /// User-facing notice when a pinned-but-disconnected device made capture fall
    /// back to the system default input. Informational, not an error — the session
    /// still runs.
    static func fallbackNotice(uid: String) -> String {
        "Saved microphone is disconnected — using the default input."
    }

    /// Convenience for session-state callers that only need to know whether the
    /// decision was the announced fallback (same inputs as `decide`).
    static func fellBackToDefault(microphoneID: String, deviceResolved: Bool) -> Bool {
        if case .fallbackToDefault = decide(
            microphoneID: microphoneID, deviceResolved: deviceResolved) { return true }
        return false
    }

    /// Live-capture status line, annotated when the pinned mic fell back to the
    /// default so the active input is never misrepresented in the UI.
    static func listeningStatus(micFellBackToDefault: Bool) -> String {
        micFellBackToDefault ? "Listening... (default mic)" : "Listening..."
    }
}
