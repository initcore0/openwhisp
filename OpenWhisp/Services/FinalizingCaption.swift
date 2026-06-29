import Foundation

/// Pure decision for the caption shown under the overlay pill while a session is
/// finalizing (recording stopped, transcription in progress). Foundation-only so
/// it lives in OpenWhispCore and is unit-tested.
///
/// The point: in paste-at-end (finalOnly) mode there's no live transcript, so the
/// overlay would otherwise show just the finalizing pulse with no words — and on a
/// COLD WhisperKit model load the wait can be long enough to look hung. When the
/// engine reports it's loading/preparing the model, surface THAT instead of the
/// generic "Finalizing…" so the user knows the app is working, not stuck.
enum FinalizingCaption {
    /// Substrings (lowercased) in the worker status that mean "model is loading" —
    /// worth showing to the user during finalize instead of the generic caption.
    /// Matches WhisperKitEngine's "Preparing WhisperKit model…" status.
    private static let loadingMarkers = ["preparing", "loading", "warming", "waiting for model"]

    /// Resolve the caption, or nil when nothing should be shown (not finalizing).
    /// - Parameters:
    ///   - isTranscribing: the session is finalizing/transcribing.
    ///   - statusMessage: the generic session status (e.g. "Finalizing…").
    ///   - workerStatus: the transcription engine's worker status (model load state).
    ///   - usesWhisperKit: whether the active file backend is WhisperKit (whose cold
    ///     load is the slow case worth surfacing).
    static func resolve(
        isTranscribing: Bool,
        statusMessage: String,
        workerStatus: String,
        usesWhisperKit: Bool
    ) -> String? {
        guard isTranscribing else { return nil }

        // Prefer the model-load status while the (WhisperKit) engine is preparing —
        // that's the long, hang-looking wait the user needs reassurance through.
        if usesWhisperKit, isLoading(workerStatus) {
            return "Loading model…"
        }

        let trimmed = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Finalizing…" : trimmed
    }

    /// True when a worker status string indicates the model is still loading.
    static func isLoading(_ workerStatus: String) -> Bool {
        let s = workerStatus.lowercased()
        return loadingMarkers.contains { s.contains($0) }
    }
}
