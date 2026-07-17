import XCTest
@testable import OpenWhispCore

/// MAK-59: the pure-core routing/gating for the Apple SpeechAnalyzer engine
/// (macOS 26). The Speech-framework engines themselves are app-only (they touch
/// `SpeechAnalyzer`/`AVAudioEngine`) and are exercised by real-app runs; these
/// pin the decisions AppState leans on — file-vs-stream routing, translate
/// suppression, capability flags, and the OS gate — so a wiring regression is
/// caught by `swift test` rather than in the running app.
final class SpeechAnalyzerEngineTests: XCTestCase {

    private let id = "speechAnalyzer"

    // MARK: - File-vs-stream routing

    func testSpeechAnalyzerStreamsOnlyInLiveMode() {
        // Like WhisperKit: the file/meeting path is the primary, lowest-risk win —
        // it routes to the batch engine unless a live output mode is chosen.
        XCTAssertTrue(StreamingRoutePolicy.usesStreamingSession(engine: id, liveMode: true))
        XCTAssertFalse(StreamingRoutePolicy.usesStreamingSession(engine: id, liveMode: false))
    }

    func testFileEngineChoiceRoutesSpeechAnalyzerToItsOwnBatchEngine() {
        XCTAssertEqual(FileEngineChoice.choice(for: id), .speechAnalyzer)
        // The other engines are unchanged by the addition.
        XCTAssertEqual(FileEngineChoice.choice(for: "whisperKit"), .whisperKit)
        XCTAssertEqual(FileEngineChoice.choice(for: "parakeet"), .parakeet)
        XCTAssertEqual(FileEngineChoice.choice(for: "appleSpeech"), .whisperCpp)
    }

    func testSpeechAnalyzerDoesNotNeedSFSpeechAuthorization() {
        // SpeechAnalyzer provisions models via AssetInventory, not
        // SFSpeechRecognizer.requestAuthorization — only legacy Apple Speech does.
        XCTAssertFalse(StreamingRoutePolicy.needsSpeechAuthorization(engine: id))
        XCTAssertTrue(StreamingRoutePolicy.needsSpeechAuthorization(engine: "appleSpeech"))
    }

    // MARK: - Translate suppression (ASR-only)

    func testSpeechAnalyzerIsASROnly() {
        XCTAssertFalse(LanguageResolver.supportsTranslation(transcriptionEngine: id))
        XCTAssertTrue(LanguageResolver.noTranslateEngines.contains(id))
        // A stray translate toggle must NOT map to the whisper translate sentinel.
        XCTAssertEqual(
            LanguageResolver.engineLanguageSetting(
                language: "ru", translateToEnglish: true, transcriptionEngine: id),
            "ru")
        XCTAssertEqual(
            LanguageResolver.outputLanguageForCleaning(
                language: "ru", translateToEnglish: true, transcriptionEngine: id),
            "ru")
        XCTAssertFalse(
            LanguageResolver.effectiveTranslateToEnglish(
                translateToEnglish: true, transcriptionEngine: id))
    }

    // MARK: - OS availability gate

    func testAvailabilityGateMatchesOS() {
        // The row is offered iff the OS exposes the API. On the test host this is
        // whatever the runtime reports; assert the id-and-OS gate is consistent
        // with the OS flag (never selectable when the OS lacks the API).
        if SpeechAnalyzerAvailability.isSupportedOS {
            XCTAssertTrue(SpeechAnalyzerAvailability.isSelectable(engine: id))
        } else {
            XCTAssertFalse(SpeechAnalyzerAvailability.isSelectable(engine: id))
        }
        // A different engine id is never SpeechAnalyzer-selectable regardless of OS.
        XCTAssertFalse(SpeechAnalyzerAvailability.isSelectable(engine: "whisperKit"))
        XCTAssertEqual(SpeechAnalyzerAvailability.engineID, id)
    }

    // MARK: - No regression on macOS 14/15 engines

    func testAddingSpeechAnalyzerLeavesOtherStreamingRoutingUnchanged() {
        XCTAssertTrue(StreamingRoutePolicy.usesStreamingSession(engine: "appleSpeech", liveMode: false))
        XCTAssertTrue(StreamingRoutePolicy.usesStreamingSession(engine: "parakeet", liveMode: false))
        XCTAssertFalse(StreamingRoutePolicy.usesStreamingSession(engine: "whisper", liveMode: true))
        XCTAssertFalse(StreamingRoutePolicy.usesStreamingSession(engine: "whisperKit", liveMode: false))
    }
}
