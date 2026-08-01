import XCTest
@testable import OpenWhispCore

/// The onboarding model step is engine-aware (Parakeet is the default, so a
/// fresh install downloads a Parakeet model whose progress lives apart from the
/// whisper.cpp flags the step used to read). These pin the mapping.
final class OnboardingModelStatusTests: XCTestCase {

    /// Convenience: call the resolver with everything "not downloading / not
    /// installed" and let each test flip only the fields it cares about.
    private func status(
        engine: String,
        parakeetInstalled: Bool = false,
        parakeetInFlight: Bool = false,
        parakeetFailed: Bool = false,
        whisperCppDownloading: Bool = false,
        whisperCppProgress: Double? = nil,
        whisperCppFailed: Bool = false,
        whisperKitStaged: Bool = false,
        whisperKitDownloading: Bool = false,
        whisperKitProgress: Double? = nil,
        whisperKitFailed: Bool = false
    ) -> OnboardingModelStatus.State {
        OnboardingModelStatus.state(
            engine: engine,
            parakeetInstalled: parakeetInstalled,
            parakeetInFlight: parakeetInFlight,
            parakeetFailed: parakeetFailed,
            whisperCppDownloading: whisperCppDownloading,
            whisperCppProgress: whisperCppProgress,
            whisperCppFailed: whisperCppFailed,
            whisperKitStaged: whisperKitStaged,
            whisperKitDownloading: whisperKitDownloading,
            whisperKitProgress: whisperKitProgress,
            whisperKitFailed: whisperKitFailed
        )
    }

    // MARK: - Fresh install provisions PARAKEET ONLY (MAK-93)

    /// A fresh install shows ONE download — the selected (default) engine's.
    /// AppState's launch used to also fire an unconditional whisper.cpp
    /// `ensureModelExists()`, so a new Mac fetched a GGML `.bin` for an engine
    /// the user never chose, on top of the Parakeet model. That call is gone;
    /// provisioning routes through the engine-aware `ensureSelectedEngineModel()`.
    ///
    /// The pure half of that guarantee, pinned here: with the Parakeet default
    /// selected, the step's state is driven ONLY by the Parakeet signals — the
    /// whisper.cpp and WhisperKit inputs cannot move it. If a stray whisper
    /// download ever gets kicked off again, it cannot masquerade as onboarding
    /// progress, and "ready" still means the Parakeet model specifically.
    func testFreshInstallDefaultEngineIgnoresWhisperFamilySignals() {
        // Every combination of whisper.cpp / WhisperKit noise, including a
        // full-blown in-flight download and a failure, on a fresh (nothing
        // installed) Parakeet default.
        for whisperCppDownloading in [true, false] {
            for whisperKitDownloading in [true, false] {
                for failed in [true, false] {
                    XCTAssertEqual(
                        status(engine: "parakeet",
                               parakeetInFlight: true,
                               whisperCppDownloading: whisperCppDownloading,
                               whisperCppProgress: 0.5,
                               whisperCppFailed: failed,
                               whisperKitStaged: true,
                               whisperKitDownloading: whisperKitDownloading,
                               whisperKitProgress: 0.5,
                               whisperKitFailed: failed),
                        .downloading(progress: nil),
                        "Parakeet progress must not be reported via whisper-family signals")
                    // ...and readiness means PARAKEET is on disk, never a staged
                    // WhisperKit model.
                    XCTAssertEqual(
                        status(engine: "parakeet",
                               parakeetInstalled: true,
                               whisperCppDownloading: whisperCppDownloading,
                               whisperCppFailed: failed,
                               whisperKitStaged: true,
                               whisperKitDownloading: whisperKitDownloading,
                               whisperKitFailed: failed),
                        .ready)
                }
            }
        }
    }

    /// A staged WhisperKit model is NOT a substitute for the selected engine's:
    /// with Parakeet selected and nothing Parakeet-side on disk, onboarding must
    /// still report a download rather than a false "ready".
    func testStagedWhisperKitModelDoesNotSatisfyParakeetDefault() {
        XCTAssertEqual(
            status(engine: "parakeet", whisperKitStaged: true),
            .downloading(progress: nil))
    }

    // MARK: - Parakeet (the default)

    func testParakeetInstalledIsReady() {
        XCTAssertEqual(status(engine: "parakeet", parakeetInstalled: true), .ready)
    }

    func testParakeetInFlightIsIndeterminateDownloading() {
        // FluidAudio exposes no percentage — must be an indeterminate spinner,
        // never a determinate bar stuck at 0.
        XCTAssertEqual(
            status(engine: "parakeet", parakeetInFlight: true),
            .downloading(progress: nil)
        )
    }

    func testParakeetNotYetInstalledOrInFlightStillReadsDownloading() {
        // The launch prefetch kicks a moment after onboarding opens; until the
        // folder exists we must NOT claim "ready" for a model that isn't there
        // (the exact false-ready bug the resolver was written to close).
        XCTAssertEqual(status(engine: "parakeet"), .downloading(progress: nil))
    }

    func testParakeetFailedPrefetchIsFailed() {
        // A finished-but-failed prefetch (offline first-run) with no model on
        // disk must surface the retryable failure card, not a perpetual spinner.
        XCTAssertEqual(status(engine: "parakeet", parakeetFailed: true), .failed)
    }

    func testParakeetInFlightBeatsAStaleFailure() {
        // A retry sets a fresh prefetch in flight; while it runs we show
        // downloading, even if the previous attempt's failure flag lingers.
        XCTAssertEqual(
            status(engine: "parakeet", parakeetInFlight: true, parakeetFailed: true),
            .downloading(progress: nil)
        )
    }

    func testParakeetInstalledBeatsAStaleFailure() {
        // Model is on disk — ready wins over any leftover failure flag.
        XCTAssertEqual(
            status(engine: "parakeet", parakeetInstalled: true, parakeetFailed: true),
            .ready
        )
    }

    // MARK: - WhisperKit (lean-build default)

    func testWhisperKitStagedIsReady() {
        XCTAssertEqual(status(engine: "whisperKit", whisperKitStaged: true), .ready)
    }

    func testWhisperKitDownloadingShowsProgress() {
        XCTAssertEqual(
            status(engine: "whisperKit", whisperKitDownloading: true, whisperKitProgress: 0.4),
            .downloading(progress: 0.4)
        )
    }

    func testWhisperKitDownloadingAtZeroIsIndeterminate() {
        // 0.0 means "started, nothing yet" — indeterminate, not a stuck-empty bar.
        XCTAssertEqual(
            status(engine: "whisperKit", whisperKitDownloading: true, whisperKitProgress: 0),
            .downloading(progress: nil)
        )
    }

    // MARK: - Apple Speech

    func testAppleSpeechIsAlwaysReady() {
        XCTAssertEqual(status(engine: "appleSpeech"), .ready)
    }

    // MARK: - Apple SpeechAnalyzer (MAK-59)

    func testSpeechAnalyzerIsAlwaysReady() {
        // The locale model auto-installs on first use — onboarding must never
        // show a whisper.cpp download card for it.
        XCTAssertEqual(status(engine: "speechAnalyzer"), .ready)
    }

    // MARK: - whisper.cpp (real percentage + discrete failure)

    func testWhisperCppReadyWhenIdle() {
        XCTAssertEqual(status(engine: "whisper"), .ready)
    }

    func testWhisperCppDownloadingShowsProgress() {
        XCTAssertEqual(
            status(engine: "whisper", whisperCppDownloading: true, whisperCppProgress: 0.7),
            .downloading(progress: 0.7)
        )
    }

    func testWhisperCppFailedIsFailed() {
        XCTAssertEqual(
            status(engine: "whisper", whisperCppFailed: true),
            .failed
        )
    }

    func testWhisperCppFailedButStillDownloadingReportsDownloading() {
        // A retry-in-progress overrides a stale failure flag.
        XCTAssertEqual(
            status(engine: "whisper", whisperCppDownloading: true,
                   whisperCppProgress: 0.2, whisperCppFailed: true),
            .downloading(progress: 0.2)
        )
    }

    func testWhisperKitFailedIsFailed() {
        // Offline first run on a lean (WhisperKit-default) build: a failed
        // download with nothing staged must surface the retryable failure card,
        // not spin forever (the exact bug the parakeetFailed input fixed).
        XCTAssertEqual(
            status(engine: "whisperKit", whisperKitFailed: true),
            .failed
        )
    }

    func testWhisperKitFailedButRetryingReportsDownloading() {
        XCTAssertEqual(
            status(engine: "whisperKit", whisperKitDownloading: true,
                   whisperKitProgress: 0.3, whisperKitFailed: true),
            .downloading(progress: 0.3)
        )
    }

    func testWhisperKitStagedBeatsStaleFailure() {
        XCTAssertEqual(
            status(engine: "whisperKit", whisperKitStaged: true, whisperKitFailed: true),
            .ready
        )
    }

    func testProgressAboveOneIsClamped() {
        XCTAssertEqual(
            status(engine: "whisper", whisperCppDownloading: true, whisperCppProgress: 1.5),
            .downloading(progress: 1.0)
        )
    }
}
