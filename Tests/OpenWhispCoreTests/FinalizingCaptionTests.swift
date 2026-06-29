import XCTest
@testable import OpenWhispCore

/// The overlay caption shown while finalizing (recording stopped, transcribing).
/// Key behaviors: nothing when not finalizing; a cold WhisperKit model load reads
/// as "Loading model…" so the wait doesn't look hung; otherwise the session status.
final class FinalizingCaptionTests: XCTestCase {

    private func resolve(
        isTranscribing: Bool = true,
        statusMessage: String = "Finalizing…",
        workerStatus: String = "WhisperKit ready",
        usesWhisperKit: Bool = true
    ) -> String? {
        FinalizingCaption.resolve(
            isTranscribing: isTranscribing,
            statusMessage: statusMessage,
            workerStatus: workerStatus,
            usesWhisperKit: usesWhisperKit
        )
    }

    func testNilWhenNotTranscribing() {
        XCTAssertNil(resolve(isTranscribing: false))
    }

    func testShowsStatusWhenNotLoading() {
        XCTAssertEqual(resolve(statusMessage: "Finalizing…"), "Finalizing…")
    }

    func testFallsBackToFinalizingWhenStatusEmpty() {
        XCTAssertEqual(resolve(statusMessage: "   "), "Finalizing…")
    }

    /// A cold WhisperKit load: the worker status says "Preparing WhisperKit model…"
    /// — surface that as a clear loading caption rather than the generic status.
    func testSurfacesWhisperKitModelLoad() {
        XCTAssertEqual(
            resolve(statusMessage: "Finalizing…", workerStatus: "Preparing WhisperKit model…"),
            "Loading model…"
        )
    }

    func testRecognizesWaitingForModel() {
        XCTAssertEqual(resolve(workerStatus: "Waiting for model"), "Loading model…")
    }

    /// The model-load surfacing is WhisperKit-specific — whisper.cpp's worker status
    /// (e.g. a warming server) shouldn't be relabeled "Loading model…" here; the
    /// generic status is correct for it. (Only flips when usesWhisperKit.)
    func testLoadingMarkerIgnoredForNonWhisperKit() {
        XCTAssertEqual(
            resolve(statusMessage: "Finalizing…", workerStatus: "Preparing model…", usesWhisperKit: false),
            "Finalizing…"
        )
    }

    func testReadyStatusDoesNotTriggerLoadingCaption() {
        XCTAssertEqual(
            resolve(statusMessage: "Finalizing…", workerStatus: "WhisperKit ready"),
            "Finalizing…"
        )
    }

    func testIsLoadingMarkers() {
        XCTAssertTrue(FinalizingCaption.isLoading("Preparing WhisperKit model…"))
        XCTAssertTrue(FinalizingCaption.isLoading("Loading…"))
        XCTAssertTrue(FinalizingCaption.isLoading("Waiting for model"))
        XCTAssertFalse(FinalizingCaption.isLoading("WhisperKit ready"))
        XCTAssertFalse(FinalizingCaption.isLoading("Not started"))
    }
}
