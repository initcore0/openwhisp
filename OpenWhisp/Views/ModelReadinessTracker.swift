import Combine
import Foundation

/// Publishes the SELECTED engine's `EngineReadiness` for the UI (MAK-94).
///
/// Why it lives here and not on AppState: AppState is under the MAK-32 LOC
/// ratchet (it may only shrink), so this follows the `TranslationPreviewController`
/// pattern — an ObservableObject owned by `OpenWhispApp`, observing AppState's
/// already-published signals via Combine rather than being a new pile of
/// `@Published` properties on the god-object. AppState pays only for the engine
/// callback hand-off (`onReadinessChanged`), which cannot come from outside.
///
/// The decision itself is the pure, unit-tested `EngineReadinessResolver`; this
/// class is wiring: collect observations → resolve → publish.
@MainActor
final class ModelReadinessTracker: ObservableObject {

    /// The selected engine's readiness right now. `.idle` until the first
    /// observation lands.
    @Published private(set) var readiness: EngineReadiness = .idle

    /// The model/variant label to name in the menu row ("parakeet-unified-320ms",
    /// "base.en", …). Tracks the engine selection so the row can't name a model
    /// the user already switched away from.
    @Published private(set) var modelLabel: String = ""

    /// The menu-bar row for the current state, or nil when nothing is worth
    /// showing (idle/ready). `AppMain.showMenu` renders exactly this.
    var menuRow: String? { readiness.menuRow(modelLabel: modelLabel) }

    /// The single tracker the app uses. A shared instance (rather than an
    /// injected one) because its two consumers sit on opposite sides of the app:
    /// `OpenWhispApp` renders the menu row, and `OverlayView` — constructed deep
    /// inside AppState's `OverlayWindowController` — reads it for the loading
    /// phase. Threading it through that construction path would mean new stored
    /// properties on AppState, which the MAK-32 ratchet forbids.
    ///
    /// `AppState.shared` is itself a singleton, so this adds no new lifetime
    /// assumption. Created on first touch (AppMain's `applicationDidFinishLaunching`,
    /// right after the engines are wired) so the Parakeet callback attaches before
    /// the launch-time warm reports anything.
    static let shared = ModelReadinessTracker(appState: .shared)

    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()

    /// The last readiness the Parakeet engine itself reported. Parakeet is the
    /// only engine with a genuine load/download signal, so it is authoritative
    /// for its own state — the resolver's disk/in-flight derivation is the
    /// fallback for before the first callback arrives (and for engine switches).
    private var parakeetReported: EngineReadiness?

    private init(appState: AppState) {
        self.appState = appState
        observe()
        attachParakeetCallback()
        recompute()
    }

    // MARK: - Observation

    /// Watch every AppState signal the resolver consumes. Deliberately one-way:
    /// AppState publishes, this listens (see the ratchet note above).
    private func observe() {
        // Engine / variant selection: a switch re-labels the row AND invalidates
        // whatever the previous engine reported.
        appState.$transcriptionEngine
            .removeDuplicates()
            .sink { [weak self] _ in self?.engineSelectionChanged() }
            .store(in: &cancellables)
        appState.$parakeetVariant
            .removeDuplicates()
            .sink { [weak self] _ in self?.engineSelectionChanged() }
            .store(in: &cancellables)

        // Parakeet's coarse app-side signals (still the source of truth for the
        // download badge and the failure flag).
        appState.$parakeetInFlightVariants
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        appState.$parakeetPrefetchFailed
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        // WhisperKit + worker-status signals for the coarse non-default engines.
        appState.$whisperKitDownloadingModel
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        appState.$whisperKitDownloadProgress
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        appState.$whisperWorkerStatus
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }

    /// `rebuildFileEngine()` constructs a BRAND-NEW `ParakeetStreamingEngine` on
    /// every engine/model settings change, which drops the callback we attached
    /// to the previous instance — so re-attach whenever the selection changes,
    /// and drop the stale report. This is the "cold → loading → ready after a
    /// settings change" path the ticket calls out: AppState's `rebuildFileEngine`
    /// ends in `warmWhisperServerIfPossible()`, which re-kicks
    /// `prefetchParakeetVariant()`, so the fresh engine reports through the newly
    /// attached callback.
    private func engineSelectionChanged() {
        parakeetReported = nil
        // ORDERING (verified): Combine delivers a `@Published` change to sinks
        // BEFORE the property's `didSet` body runs — and it is that `didSet`
        // which calls `rebuildFileEngine()` and constructs the replacement
        // `ParakeetStreamingEngine`. Attaching synchronously here would therefore
        // bind the callback to the engine instance that is about to be discarded,
        // and the new one would report into the void — a silently dead wiring of
        // exactly the kind this project has been bitten by before (see memory:
        // wiring-review-lessons). Hopping to the next main-actor turn lets
        // `didSet` finish (rebuild + re-warm) so we attach to the LIVE engine.
        Task { @MainActor in
            self.attachParakeetCallback()
            self.recompute()
        }
        // Still recompute now so the label/state don't lag a turn behind.
        recompute()
    }

    private func attachParakeetCallback() {
        appState.parakeetStreamEngine?.onReadinessChanged = { [weak self] readiness in
            guard let self else { return }
            self.parakeetReported = readiness
            self.recompute()
        }
    }

    // MARK: - Resolution

    /// Collect the current observations and publish the resolved readiness.
    private func recompute() {
        modelLabel = currentModelLabel()

        let engine = appState.transcriptionEngine
        // Parakeet's own callback wins while it's the selected engine: it's the
        // only signal that distinguishes the load from the download, and the only
        // one that knows a session is genuinely resident.
        if engine == "parakeet", let reported = parakeetReported {
            readiness = reported
            return
        }

        let variant = ParakeetCatalog.normalize(appState.parakeetVariant)
        let observation = EngineReadinessResolver.ParakeetObservation(
            prefetchInFlight: appState.parakeetInFlightVariants.contains(variant),
            // Verified completeness, not folder presence — a torn download must
            // resolve as "still downloading", never as bytes-staged .loading.
            modelOnDisk: FluidAudioModelsLocator.verdict(forVariant: variant) == .complete,
            sessionLoaded: appState.parakeetStreamEngine?.isSessionLoaded ?? false,
            prefetchFailed: appState.parakeetPrefetchFailed
        )

        readiness = EngineReadinessResolver.resolve(
            engine: engine,
            parakeet: observation,
            whisperKitDownloadingModel: appState.whisperKitDownloadingModel,
            // `whisperKitDownloadProgress` is 0 before the first progress report;
            // pass nil so the row reads a plain "Downloading …" rather than "0%".
            whisperKitDownloadProgress: appState.whisperKitDownloadProgress > 0
                ? appState.whisperKitDownloadProgress : nil,
            whisperKitModelStaged: WhisperKitModelCatalog.isStaged(appState.whisperKitModel),
            workerStatus: appState.whisperWorkerStatus
        )
    }

    // MARK: - Arming timeout

    /// Run the streaming session's arming-timeout fallback, readiness-aware
    /// (MAK-94).
    ///
    /// Before this, AppState slept a flat `captureStartTimeout` and then flipped
    /// the session to "Listening…" unconditionally. That fallback exists to
    /// unstick a signal-WIRING bug — but on the cold-start path it fired in the
    /// middle of a genuine model load and made the UI claim capture over a dead
    /// mic, which is exactly the dishonesty this ticket is about.
    ///
    /// Now: poll at the same interval; while `EngineReadiness.isWorking` keep the
    /// honest loading phase; the moment readiness resolves, flip to Listening as
    /// before; past the hard cap, fail loudly. The decision is the pure, tested
    /// `StreamingRoutePolicy.armingTimeoutAction` — this is only the loop.
    ///
    /// Lives here rather than on AppState so the god-object gains no lines
    /// (MAK-32 ratchet); AppState just hands over two closures.
    func runArmingTimeout(
        interval: TimeInterval = StreamingRoutePolicy.captureStartTimeout,
        maxWait: TimeInterval = StreamingRoutePolicy.modelLoadArmingMaxWait,
        sleep: @escaping (TimeInterval) async -> Void = {
            try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        onBeginListening: @escaping () -> Void,
        onStuck: @escaping () -> Void
    ) {
        Task { @MainActor in
            var elapsed: TimeInterval = 0
            while true {
                await sleep(interval)
                elapsed += interval
                switch StreamingRoutePolicy.armingTimeoutAction(
                    engineIsLoadingModel: readiness.isWorking,
                    elapsed: elapsed,
                    maxWait: maxWait
                ) {
                case .beginListening:
                    // The session fence lives in `handleStreamingCaptureStarted`
                    // (captureStartedAction): a late/duplicate call is a no-op.
                    onBeginListening()
                    return
                case .keepWaiting:
                    continue
                case .failStuck:
                    onStuck()
                    return
                }
            }
        }
    }

    /// The user-facing name of the model being prepared for the selected engine.
    private func currentModelLabel() -> String {
        switch appState.transcriptionEngine {
        case "parakeet":       return ParakeetCatalog.normalize(appState.parakeetVariant)
        case "whisperKit":     return appState.whisperKitModel
        case "appleSpeech":    return "Apple Speech"
        case "speechAnalyzer": return "Apple SpeechAnalyzer"
        default:               return appState.modelName
        }
    }
}
