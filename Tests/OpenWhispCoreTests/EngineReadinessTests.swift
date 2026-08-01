import XCTest
@testable import OpenWhispCore

/// MAK-94 — the selected engine's model readiness.
///
/// The owner-reported gap: the first dictation after a launch/update waits
/// several seconds on a Parakeet model load with NO indication anywhere, and a
/// hotkey press during that window feels dead. These tests pin the derivation
/// that makes the wait visible — in particular the DOWNLOAD vs LOAD split, which
/// the pre-MAK-94 code conflated into one "Downloading…" badge that was simply
/// wrong on every launch after the first.
final class EngineReadinessTests: XCTestCase {

    private typealias Observation = EngineReadinessResolver.ParakeetObservation

    // MARK: - Parakeet (the precise, default path)

    /// Bytes absent + a prefetch running = a genuine first-run download.
    /// FluidAudio reports no progress, so the state carries nil (never a fake %).
    func testParakeetDownloadingWhenModelNotOnDisk() {
        let state = EngineReadinessResolver.resolveParakeet(
            Observation(prefetchInFlight: true, modelOnDisk: false)
        )
        XCTAssertEqual(state, .downloading(progress: nil))
    }

    /// THE regression this feature exists for: bytes already on disk and a
    /// prefetch still in flight is the in-memory CoreML LOAD — the several-second
    /// wait on every launch. It must read `.loading`, not `.downloading`.
    func testParakeetLoadingWhenModelOnDiskButNotLoaded() {
        let state = EngineReadinessResolver.resolveParakeet(
            Observation(prefetchInFlight: true, modelOnDisk: true, sessionLoaded: false)
        )
        XCTAssertEqual(state, .loading)
    }

    func testParakeetReadyWhenSessionLoaded() {
        let state = EngineReadinessResolver.resolveParakeet(
            Observation(prefetchInFlight: false, modelOnDisk: true, sessionLoaded: true)
        )
        XCTAssertEqual(state, .ready)
        XCTAssertTrue(state.isReady)
    }

    /// A resident session outranks a still-settling redundant prefetch: the
    /// engine can capture NOW, so the overlay must not push the user into a
    /// loading phase it doesn't need to wait through.
    func testParakeetLoadedSessionOutranksInFlightPrefetch() {
        let state = EngineReadinessResolver.resolveParakeet(
            Observation(prefetchInFlight: true, modelOnDisk: true, sessionLoaded: true)
        )
        XCTAssertEqual(state, .ready)
    }

    func testParakeetFailedSurfacesReason() {
        let state = EngineReadinessResolver.resolveParakeet(
            Observation(prefetchInFlight: false, modelOnDisk: false, prefetchFailed: true)
        )
        guard case .failed(let reason) = state else { return XCTFail("expected .failed, got \(state)") }
        XCTAssertFalse(reason.isEmpty)
    }

    /// Nothing in flight and nothing loaded: the model will load lazily at the
    /// first session. Idle is NOT ready (the load has not been paid) but is also
    /// not worth a menu row — no work is happening to report.
    func testParakeetIdleWhenNothingInFlight() {
        let state = EngineReadinessResolver.resolveParakeet(Observation())
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(state.isReady)
        XCTAssertFalse(state.isWorking)
        XCTAssertNil(state.menuRow(modelLabel: "parakeet-unified-320ms"))
    }

    /// The full cold-start sequence a first run walks, in order.
    func testParakeetColdStartTransitionSequence() {
        var o = Observation(prefetchInFlight: true, modelOnDisk: false)
        XCTAssertEqual(EngineReadinessResolver.resolveParakeet(o), .downloading(progress: nil))
        o.modelOnDisk = true                            // bytes landed
        XCTAssertEqual(EngineReadinessResolver.resolveParakeet(o), .loading)
        o.sessionLoaded = true; o.prefetchInFlight = false
        XCTAssertEqual(EngineReadinessResolver.resolveParakeet(o), .ready)
    }

    /// A warm launch (bytes already down) skips the download entirely — this is
    /// the path the owner hits after an update: straight into `.loading`.
    func testParakeetWarmLaunchGoesStraightToLoading() {
        var o = Observation(prefetchInFlight: true, modelOnDisk: true)
        XCTAssertEqual(EngineReadinessResolver.resolveParakeet(o), .loading)
        o.sessionLoaded = true
        XCTAssertEqual(EngineReadinessResolver.resolveParakeet(o), .ready)
    }

    /// `rebuildFileEngine()` discards the loaded engine on an engine/model
    /// settings change, so readiness must fall back out of `.ready` — the cold →
    /// loading → ready cycle repeats rather than the UI claiming a stale ready.
    func testParakeetGoesColdAfterEngineRebuild() {
        let loaded = Observation(modelOnDisk: true, sessionLoaded: true)
        XCTAssertEqual(EngineReadinessResolver.resolveParakeet(loaded), .ready)
        // rebuildFileEngine → new engine instance (no session), warm re-kicked.
        let rebuilt = Observation(prefetchInFlight: true, modelOnDisk: true, sessionLoaded: false)
        XCTAssertEqual(EngineReadinessResolver.resolveParakeet(rebuilt), .loading)
    }

    /// Guards the ordering hazard behind `ModelReadinessTracker.engineSelectionChanged`.
    ///
    /// Combine delivers a `@Published` change to sinks BEFORE the property's
    /// `didSet` runs — and it's that `didSet` which calls `rebuildFileEngine()`
    /// and builds the replacement engine. So at sink time the tracker still sees
    /// the OLD engine: a session may still be resident and no prefetch is in
    /// flight yet, which resolves `.ready`. That stale `.ready` must be corrected
    /// by the deferred re-attach + recompute — this pins the two observations the
    /// tracker sees, in order, so the second one is the honest answer.
    func testEngineSwitchStaleObservationIsSupersededByRebuiltOne() {
        // Sink-time: old engine still loaded, rebuild hasn't run.
        let atSinkTime = Observation(prefetchInFlight: false, modelOnDisk: true, sessionLoaded: true)
        XCTAssertEqual(EngineReadinessResolver.resolveParakeet(atSinkTime), .ready)
        // After didSet: engine replaced (no session), warm re-kicked.
        let afterRebuild = Observation(prefetchInFlight: true, modelOnDisk: true, sessionLoaded: false)
        XCTAssertEqual(EngineReadinessResolver.resolveParakeet(afterRebuild), .loading)
    }

    // MARK: - Other engines (correct but coarse)

    /// Apple Speech starts synchronously off an on-device recognizer — there is
    /// no model load to wait through, so "always ready" is honest, not coarse.
    func testAppleSpeechAlwaysReady() {
        XCTAssertEqual(resolve(engine: "appleSpeech", workerStatus: "Not started"), .ready)
    }

    func testWhisperKitDownloadingCarriesProgress() {
        let state = EngineReadinessResolver.resolveWhisperKit(
            downloadingModel: "base.en", progress: 0.42, staged: false, workerStatus: ""
        )
        XCTAssertEqual(state, .downloading(progress: 0.42))
    }

    func testWhisperKitLoadingFromWorkerStatus() {
        let state = EngineReadinessResolver.resolveWhisperKit(
            downloadingModel: nil, progress: nil, staged: true,
            workerStatus: "Preparing WhisperKit model…"
        )
        XCTAssertEqual(state, .loading)
    }

    func testWhisperKitReadyFromWorkerStatus() {
        let state = EngineReadinessResolver.resolveWhisperKit(
            downloadingModel: nil, progress: nil, staged: true, workerStatus: "WhisperKit ready"
        )
        XCTAssertEqual(state, .ready)
    }

    /// An unstaged model with no download running is idle — not "loading"
    /// (nothing is happening) and not "ready" (it can't capture yet).
    func testWhisperKitUnstagedIsIdle() {
        let state = EngineReadinessResolver.resolveWhisperKit(
            downloadingModel: nil, progress: nil, staged: false, workerStatus: ""
        )
        XCTAssertEqual(state, .idle)
    }

    /// The worker-status vocabulary is shared with FinalizingCaption so the
    /// overlay's finalize caption and this readiness can never disagree.
    func testWorkerStatusVocabularyMatchesFinalizingCaption() {
        for marker in ["Preparing model…", "Loading model", "Warming up", "Waiting for model"] {
            XCTAssertTrue(FinalizingCaption.isLoading(marker), "expected loading: \(marker)")
            XCTAssertEqual(EngineReadinessResolver.resolveFromWorkerStatus(marker), .loading)
        }
    }

    func testWhisperCppRoutesThroughWorkerStatus() {
        XCTAssertEqual(resolve(engine: "whisper", workerStatus: "Server ready"), .ready)
        XCTAssertEqual(resolve(engine: "whisper", workerStatus: "Preparing model…"), .loading)
    }

    // MARK: - Menu rows

    func testMenuRowNamesTheModelBeingLoaded() {
        XCTAssertEqual(
            EngineReadiness.loading.menuRow(modelLabel: "parakeet-unified-320ms"),
            "Loading parakeet-unified-320ms…"
        )
    }

    func testMenuRowShowsPercentWhenProgressKnown() {
        XCTAssertEqual(
            EngineReadiness.downloading(progress: 0.37).menuRow(modelLabel: "base.en"),
            "Downloading base.en… 37%"
        )
    }

    /// No progress available (FluidAudio) = no fake percentage.
    func testMenuRowOmitsPercentWhenProgressUnknown() {
        XCTAssertEqual(
            EngineReadiness.downloading(progress: nil).menuRow(modelLabel: "parakeet-unified-320ms"),
            "Downloading parakeet-unified-320ms…"
        )
    }

    /// A healthy engine leaves the menu uncluttered — the row exists to explain
    /// a wait, so it must vanish the moment there is no wait.
    func testMenuRowHiddenWhenReadyOrIdle() {
        XCTAssertNil(EngineReadiness.ready.menuRow(modelLabel: "base.en"))
        XCTAssertNil(EngineReadiness.idle.menuRow(modelLabel: "base.en"))
    }

    func testMenuRowSurfacesFailureReason() {
        let row = EngineReadiness.failed("download failed").menuRow(modelLabel: "base.en")
        XCTAssertEqual(row, "Model unavailable — download failed")
    }

    // MARK: - isWorking

    func testIsWorkingOnlyForDownloadingAndLoading() {
        XCTAssertTrue(EngineReadiness.loading.isWorking)
        XCTAssertTrue(EngineReadiness.downloading(progress: nil).isWorking)
        XCTAssertFalse(EngineReadiness.ready.isWorking)
        XCTAssertFalse(EngineReadiness.idle.isWorking)
        XCTAssertFalse(EngineReadiness.failed("x").isWorking)
    }

    // MARK: - Helper

    private func resolve(
        engine: String,
        parakeet: Observation = Observation(),
        whisperKitDownloadingModel: String? = nil,
        whisperKitDownloadProgress: Double? = nil,
        whisperKitModelStaged: Bool = true,
        workerStatus: String = ""
    ) -> EngineReadiness {
        EngineReadinessResolver.resolve(
            engine: engine,
            parakeet: parakeet,
            whisperKitDownloadingModel: whisperKitDownloadingModel,
            whisperKitDownloadProgress: whisperKitDownloadProgress,
            whisperKitModelStaged: whisperKitModelStaged,
            workerStatus: workerStatus
        )
    }
}
