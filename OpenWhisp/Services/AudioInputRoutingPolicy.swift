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
        /// This is the intended behavior for an empty `microphoneID`, and it must NOT
        /// be reached as a silent fallback when a pinned device fails to resolve.
        case systemDefault
        /// Route capture to the pinned device (carrying the trimmed UID; the caller
        /// re-resolves it to a live device at application time).
        case useDevice(uid: String)
        /// A device WAS pinned but couldn't be resolved (disconnected, or its UID no
        /// longer matches any enumerated input). The caller must surface this — never
        /// silently fall back to the system default, which is the historical bug that
        /// made a non-default selection silently capture the built-in mic.
        case unresolved(uid: String)
    }

    /// Decide how to route, given the stored setting and whether the resolver found a
    /// matching device. `deviceResolved` is the app-side CoreAudio lookup result
    /// (`AudioInputRouter.resolve(uid:) != nil`); passing it in keeps this pure.
    ///
    /// - `microphoneID` empty  → `.systemDefault` (regardless of `deviceResolved`).
    /// - non-empty + resolved  → `.useDevice`.
    /// - non-empty + unresolved → `.unresolved` (caller surfaces an error).
    static func decide(microphoneID: String, deviceResolved: Bool) -> Decision {
        let uid = microphoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return .systemDefault }
        return deviceResolved ? .useDevice(uid: uid) : .unresolved(uid: uid)
    }

    /// User-facing message for an unresolved pinned device. Kept here so the wording
    /// is identical across the capture paths that surface it.
    static func unresolvedMessage(uid: String) -> String {
        "Selected microphone isn't available. Reconnect it or pick another in Settings → Dictation."
    }
}
