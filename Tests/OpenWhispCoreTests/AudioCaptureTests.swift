import XCTest
@testable import OpenWhispCore

/// A recording `AudioCapture` double. The concrete AudioRecorder needs a live
/// AVAudioEngine/CoreAudio and isn't unit-testable; this captures the driving
/// calls and lets state/level callbacks be fired, which future AppState session
/// tests need. Also pins the protocol-extension convenience defaults.
final class FakeAudioCapture: AudioCapture {
    var autoGainEnabled: Bool = true
    var quietModeEnabled: Bool = false
    var onStateChanged: ((RecorderState) -> Void)?
    var onLevelChanged: ((Float) -> Void)?

    struct SilenceParams: Equatable {
        let silence: TimeInterval
        let minSpeech: TimeInterval
        let maxSpeech: TimeInterval
        let threshold: Float
    }
    private(set) var selectedDevices: [String] = []
    private(set) var startCount = 0
    private(set) var fixedChunkDurations: [Double] = []
    private(set) var silenceParams: [SilenceParams] = []
    private(set) var stopCount = 0

    func selectDevice(_ deviceID: String) { selectedDevices.append(deviceID) }
    func start() { startCount += 1 }
    func startStreaming(chunkDuration: Double, onChunk: @escaping (URL?) -> Void) {
        fixedChunkDurations.append(chunkDuration)
    }
    func startStreamingOnSilence(
        silenceDuration: TimeInterval,
        minimumSpeechDuration: TimeInterval,
        maximumSpeechDuration: TimeInterval,
        speechThreshold: Float,
        onChunk: @escaping (URL?) -> Void
    ) {
        silenceParams.append(.init(
            silence: silenceDuration, minSpeech: minimumSpeechDuration,
            maxSpeech: maximumSpeechDuration, threshold: speechThreshold
        ))
    }
    func stop(completion: ((URL?) -> Void)?) { stopCount += 1; completion?(nil) }
}

final class AudioCaptureTests: XCTestCase {
    func testRecorderStateEquatable() {
        XCTAssertEqual(RecorderState.recording, .recording)
        XCTAssertEqual(RecorderState.error("x"), .error("x"))
        XCTAssertNotEqual(RecorderState.error("x"), .error("y"))
        XCTAssertNotEqual(RecorderState.idle, .stopped)
    }

    /// The convenience `startStreamingOnSilence(onChunk:)` must forward the exact
    /// VAD defaults the concrete recorder uses (0.75 / 0.35 / 12.0 / 0.018) — this
    /// is the seam where a drift would silently change live-chunk behavior.
    func testSilenceConvenienceUsesConcreteDefaults() {
        let capture: AudioCapture = FakeAudioCapture()
        capture.startStreamingOnSilence(onChunk: { _ in })
        let fake = capture as! FakeAudioCapture
        XCTAssertEqual(fake.silenceParams, [.init(
            silence: 0.75, minSpeech: 0.35, maxSpeech: 12.0, threshold: 0.018
        )])
    }

    func testStopConvenienceForwardsNilCompletion() {
        let capture: AudioCapture = FakeAudioCapture()
        capture.stop()                       // extension overload, no completion
        XCTAssertEqual((capture as! FakeAudioCapture).stopCount, 1)
    }

    func testDrivingCallsRecorded() {
        let fake = FakeAudioCapture()
        fake.selectDevice("mic-uid-1")
        fake.start()
        fake.startStreaming(chunkDuration: 3.0, onChunk: { _ in })
        fake.stop(completion: nil)
        XCTAssertEqual(fake.selectedDevices, ["mic-uid-1"])
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(fake.fixedChunkDurations, [3.0])
        XCTAssertEqual(fake.stopCount, 1)
    }

    func testStateAndLevelCallbacksInvokable() {
        let fake = FakeAudioCapture()
        var states: [RecorderState] = []
        var levels: [Float] = []
        fake.onStateChanged = { states.append($0) }
        fake.onLevelChanged = { levels.append($0) }
        fake.onStateChanged?(.recording)
        fake.onLevelChanged?(0.5)
        fake.onStateChanged?(.stopped)
        XCTAssertEqual(states, [.recording, .stopped])
        XCTAssertEqual(levels, [0.5])
    }
}
