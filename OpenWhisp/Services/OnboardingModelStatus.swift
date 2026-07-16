import Foundation

/// Pure decision logic for the onboarding "model" step, so it can be unit-tested
/// independently of SwiftUI/AppState.
///
/// Why this exists: the model step used to read ONLY the whisper.cpp download
/// flags (`isModelDownloading` / `modelDownloadProgress` / `modelDownloadStatus`
/// / `modelDownloadFailed`). Once Parakeet became the default engine (MAK-46),
/// a fresh install downloads a Parakeet model whose progress lives in a totally
/// separate place (`parakeetInFlightVariants` — a coarse in-flight flag, no
/// percentage, since FluidAudio exposes none). With the old wiring the step
/// would cheerfully say "Your speech model is ready" while Parakeet was still
/// downloading in the background, and the first dictation would stall.
///
/// This maps whichever engine is active to the ONE readiness state the step
/// renders, so the copy, icon, and progress bar always describe the model that's
/// actually being fetched. Parakeet (and WhisperKit-preloading) report only
/// indeterminate progress; whisper.cpp still carries a real percentage.
public enum OnboardingModelStatus {
    /// What the onboarding model step should display.
    public enum State: Equatable {
        /// The active engine's model is on disk (or needs no download, e.g. Apple
        /// Speech) — the step shows the green "ready" card.
        case ready
        /// A download is running. `progress` is the 0…1 fraction when the engine
        /// reports one (whisper.cpp), or nil for engines that only expose a coarse
        /// in-flight state (Parakeet / a WhisperKit preload) — the step then shows
        /// an indeterminate spinner.
        case downloading(progress: Double?)
        /// The download failed and can be retried (only the whisper.cpp path
        /// surfaces a discrete failure today).
        case failed
    }

    /// Resolve the model step's state from the active engine and the per-engine
    /// download signals AppState publishes.
    ///
    /// - Parameters:
    ///   - engine: the `transcriptionEngine` setting value.
    ///   - parakeetInstalled: whether the selected Parakeet variant's repo folder
    ///     is on disk (`ParakeetDownloadStatePolicy` → `.installed`).
    ///   - parakeetInFlight: whether a Parakeet prefetch is running for the
    ///     selected variant.
    ///   - parakeetFailed: the last Parakeet prefetch failed and the model isn't
    ///     on disk (`AppState.parakeetPrefetchFailed`) — surfaces the retryable
    ///     failure card instead of a perpetual spinner.
    ///   - whisperCppDownloading: `isModelDownloading` (whisper.cpp GGML fetch).
    ///   - whisperCppProgress: `modelDownloadProgress` (0…1) or nil.
    ///   - whisperCppFailed: `modelDownloadFailed`.
    ///   - whisperKitStaged: whether the selected WhisperKit CoreML model is on disk.
    ///   - whisperKitDownloading: a WhisperKit model download is in flight.
    ///   - whisperKitProgress: the WhisperKit download fraction (0…1).
    ///   - whisperKitFailed: the last WhisperKit download failed and the model
    ///     isn't staged (`AppState.whisperKitDownloadFailed`) — surfaces the
    ///     retryable failure card. Without it an offline first run on a
    ///     WhisperKit-default (lean) build was a spinner that never ended, the
    ///     exact bug the `parakeetFailed` input fixed for the default engine.
    public static func state(
        engine: String,
        parakeetInstalled: Bool,
        parakeetInFlight: Bool,
        parakeetFailed: Bool = false,
        whisperCppDownloading: Bool,
        whisperCppProgress: Double?,
        whisperCppFailed: Bool,
        whisperKitStaged: Bool,
        whisperKitDownloading: Bool,
        whisperKitProgress: Double?,
        whisperKitFailed: Bool = false
    ) -> State {
        switch engine {
        case "parakeet":
            if parakeetInstalled { return .ready }
            if parakeetInFlight { return .downloading(progress: nil) }
            // A finished-but-failed prefetch (offline first-run) with no model on
            // disk: show the retryable failure card, not a spinner that never ends.
            if parakeetFailed { return .failed }
            // Not on disk and no prefetch running yet — the launch prefetch kicks
            // it momentarily; show downloading so the copy is honest rather than
            // claiming "ready" for a model that isn't there.
            return .downloading(progress: nil)
        case "whisperKit":
            if whisperKitStaged { return .ready }
            if whisperKitDownloading {
                return .downloading(progress: normalizedProgress(whisperKitProgress))
            }
            // Finished-but-failed download with no model staged: the retryable
            // failure card, not a spinner that never ends (mirrors Parakeet).
            if whisperKitFailed { return .failed }
            return .downloading(progress: nil)
        case "appleSpeech":
            // Built into macOS — nothing to download, always ready.
            return .ready
        default:
            // whisper.cpp — the only path with a discrete failure + real percentage.
            if whisperCppFailed && !whisperCppDownloading { return .failed }
            if whisperCppDownloading {
                return .downloading(progress: normalizedProgress(whisperCppProgress))
            }
            return .ready
        }
    }

    /// A progress value is only meaningful as a determinate bar when it's a real
    /// fraction in (0, 1]. Zero (nothing yet) and nil both mean "no number to
    /// show" — render the indeterminate spinner instead of a stuck-at-empty bar.
    private static func normalizedProgress(_ progress: Double?) -> Double? {
        guard let progress, progress > 0 else { return nil }
        return min(progress, 1)
    }
}
