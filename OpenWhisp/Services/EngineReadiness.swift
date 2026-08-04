import Foundation

/// Whether the SELECTED transcription engine can start capturing *right now*
/// (MAK-94).
///
/// The gap this closes: Parakeet (the default) pays a multi-second model load on
/// the first dictation after a launch/update — and, on a first run, a ~600 MB
/// download before that. A warm path already exists
/// (`AppState.warmWhisperServerIfPossible()` → `prefetchParakeetVariant()` →
/// `ParakeetStreamingEngine.prefetchAwaiting()`), but it was entirely INVISIBLE:
/// nothing in the menu bar said "loading", and pressing the hotkey during the
/// window produced no prompt feedback. This type is the honest, testable answer
/// to "is the engine ready, and if not, what is it doing?".
///
/// Pure + Foundation-only so it lives in OpenWhispCore and is unit-tested away
/// from AppKit; the app-side `ModelReadinessTracker` only feeds it observations.
public enum EngineReadiness: Equatable {
    /// Nothing in flight and nothing loaded — the engine will load lazily on the
    /// first session. Treated as "not ready" by `isReady`, but it is NOT a state
    /// worth reporting in the menu (no work is happening to report).
    case idle
    /// Model bytes are being fetched. `progress` is 0...1 when the backend
    /// reports it (WhisperKit's Progress callback, FluidAudio's ProgressHandler)
    /// and nil before the first report — an indeterminate "Downloading…" then.
    case downloading(progress: Double?)
    /// Bytes are on disk; the model/session is being loaded into memory (the
    /// several-second CoreML/ANE compile+load that the owner reported as a dead
    /// wait).
    case loading
    /// The engine can start capturing immediately.
    case ready
    /// The load or download failed; `reason` is user-facing.
    case failed(String)

    /// True only in `.ready`. Every other state means a session started now will
    /// wait — which is exactly when the overlay must say so.
    public var isReady: Bool { self == .ready }

    /// True while the engine is actively working toward readiness. Drives both
    /// the menu-bar row and the overlay's `.loadingModel` phase — and, crucially,
    /// the arming-timeout suppression (a genuine load must not be mistaken for a
    /// wiring bug and flipped to a lying "Listening…").
    public var isWorking: Bool {
        switch self {
        case .downloading, .loading: return true
        case .idle, .ready, .failed: return false
        }
    }

    /// User-facing menu row for this state, or nil when there is nothing worth
    /// showing (`idle` / `ready` — the menu stays uncluttered when all is well).
    ///
    /// - Parameter modelLabel: the model/variant being prepared, e.g.
    ///   "parakeet-unified-320ms" or "base.en". Shown so a user with a slow first
    ///   run knows *what* is loading.
    public func menuRow(modelLabel: String) -> String? {
        switch self {
        case .idle, .ready:
            return nil
        case .downloading(let progress):
            guard let progress, progress.isFinite, progress > 0 else {
                return "Downloading \(modelLabel)…"
            }
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            return "Downloading \(modelLabel)… \(percent)%"
        case .loading:
            return "Loading \(modelLabel)…"
        case .failed(let reason):
            return "Model unavailable — \(reason)"
        }
    }
}

/// Derives `EngineReadiness` for the selected engine from the signals the app
/// already tracks. One resolver per engine family, all pure.
///
/// Scope note (MAK-94): Parakeet is the default and the path that must be exact.
/// The other engines get correct-but-COARSE readiness — enough that the overlay
/// and menu never lie, without inventing signals those backends don't expose.
public enum EngineReadinessResolver {

    /// Readiness for the selected engine.
    ///
    /// - Parameters:
    ///   - engine: the `transcriptionEngine` setting value.
    ///   - parakeet: Parakeet-specific observations (the precise path).
    ///   - whisperKitDownloadingModel: non-nil while a managed WhisperKit model
    ///     download is in flight.
    ///   - whisperKitDownloadProgress: 0...1 for that download, when known.
    ///   - whisperKitModelStaged: the selected WhisperKit model's weights are on
    ///     disk.
    ///   - workerStatus: the file engine's worker status string
    ///     ("Preparing … model…" / "… ready"), the only load signal
    ///     whisper.cpp/WhisperKit expose.
    public static func resolve(
        engine: String,
        parakeet: ParakeetObservation,
        whisperKitDownloadingModel: String?,
        whisperKitDownloadProgress: Double?,
        whisperKitModelStaged: Bool,
        workerStatus: String
    ) -> EngineReadiness {
        switch engine {
        case "parakeet":
            return resolveParakeet(parakeet)
        case "whisperKit":
            return resolveWhisperKit(
                downloadingModel: whisperKitDownloadingModel,
                progress: whisperKitDownloadProgress,
                staged: whisperKitModelStaged,
                workerStatus: workerStatus
            )
        case "appleSpeech":
            // Apple's Speech framework starts synchronously off an already
            // on-device recognizer — there is no model load to wait through, and
            // `onStarted` fires inside `start()`. Always ready is the honest
            // answer, not a coarse approximation.
            return .ready
        case "speechAnalyzer":
            // macOS 26 SpeechAnalyzer provisions its locale asset on first use.
            // The engine exposes no readiness signal of its own, so the worker
            // status is all there is — coarse by design.
            return resolveFromWorkerStatus(workerStatus)
        default:
            // whisper.cpp: same worker-status-only situation.
            return resolveFromWorkerStatus(workerStatus)
        }
    }

    // MARK: - Parakeet (the precise path)

    /// Everything the app knows about the Parakeet streaming model's state.
    /// Deliberately a value type so tests script it directly.
    public struct ParakeetObservation: Equatable {
        /// A prefetch/load task is running for the selected variant.
        public var prefetchInFlight: Bool
        /// The variant's model files verified complete on disk (bytes down;
        /// `ParakeetModelIntegrity` → `.complete`, not mere folder presence).
        public var modelOnDisk: Bool
        /// The engine holds a loaded `ParakeetStreamSession` — the one true
        /// "can start capturing now" signal.
        public var sessionLoaded: Bool
        /// The last prefetch failed with the model still absent.
        public var prefetchFailed: Bool

        public init(
            prefetchInFlight: Bool = false,
            modelOnDisk: Bool = false,
            sessionLoaded: Bool = false,
            prefetchFailed: Bool = false
        ) {
            self.prefetchInFlight = prefetchInFlight
            self.modelOnDisk = modelOnDisk
            self.sessionLoaded = sessionLoaded
            self.prefetchFailed = prefetchFailed
        }
    }

    /// Parakeet's derivation, in strict precedence order.
    ///
    /// The load/download split is what makes this useful: FluidAudio downloads
    /// into the repo folder and only then compiles + loads the CoreML session, so
    /// `modelOnDisk && !sessionLoaded && prefetchInFlight` is precisely the
    /// several-second LOAD the owner sees as a dead wait. Reporting that as
    /// "Downloading…" (the pre-MAK-94 badge's only vocabulary) was misleading on
    /// every launch after the first.
    static func resolveParakeet(_ o: ParakeetObservation) -> EngineReadiness {
        // A loaded session outranks everything: the engine can capture now, even
        // if a redundant prefetch is still settling.
        if o.sessionLoaded { return .ready }
        if o.prefetchFailed { return .failed(ParakeetFailureCopy.downloadFailed) }
        if o.prefetchInFlight {
            // Bytes present → this is the in-memory load; otherwise it's the
            // first-run fetch. Real fractions arrive via the engine's own
            // readiness callback, which outranks this resolver — nil is only
            // the before-first-report placeholder.
            return o.modelOnDisk ? .loading : .downloading(progress: nil)
        }
        // Nothing in flight: the model will load lazily at the first session.
        // Still not `.ready` — the load has not been paid.
        return .idle
    }

    // MARK: - WhisperKit (coarse)

    static func resolveWhisperKit(
        downloadingModel: String?,
        progress: Double?,
        staged: Bool,
        workerStatus: String
    ) -> EngineReadiness {
        if downloadingModel != nil { return .downloading(progress: progress) }
        if !staged { return .idle }
        return resolveFromWorkerStatus(workerStatus)
    }

    // MARK: - Worker-status fallback (coarse)

    /// Map a file engine's worker-status string onto readiness. Reuses
    /// `FinalizingCaption.isLoading` so the overlay's finalize caption and this
    /// readiness agree on what "loading" means — one vocabulary, one place.
    static func resolveFromWorkerStatus(_ status: String) -> EngineReadiness {
        if FinalizingCaption.isLoading(status) { return .loading }
        if status.lowercased().contains("ready") { return .ready }
        return .idle
    }
}
