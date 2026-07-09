import XCTest
@testable import OpenWhispCore

/// Fakes for the two transcription seams — the kind of doubles the protocol
/// extraction makes possible. The concrete WhisperEngine/AppleSpeechEngine need a
/// real binary / Speech framework and aren't unit-testable; these record the
/// driving calls and let callbacks be fired on demand, which is what future
/// AppState-orchestration tests need.
final class FakeFileTranscriptionEngine: FileTranscriptionEngine {
    var onTranscriptionComplete: ((UUID, String) -> Void)?
    var onTranscriptionError: ((UUID, String) -> Void)?
    var onProgress: ((Int) -> Void)?
    var onWorkerStatus: ((String) -> Void)?

    struct Request: Equatable {
        let id: UUID
        let language: String
        let wavPath: String
        let deleteWhenDone: Bool
        let backend: WhisperBackend
        let prompt: String
    }
    private(set) var requests: [Request] = []
    private(set) var warmed: [(binary: String, model: String)] = []
    private(set) var stopServerCount = 0

    func transcribe(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool,
        backend: WhisperBackend,
        prompt: String
    ) {
        requests.append(.init(
            id: requestID, language: language, wavPath: wavPath,
            deleteWhenDone: deleteWhenDone, backend: backend, prompt: prompt
        ))
    }
    func warmServer(binaryPath: String, modelPath: String) {
        warmed.append((binaryPath, modelPath))
    }
    func stopServer() { stopServerCount += 1 }
}

final class FakeStreamingTranscriptionEngine: StreamingTranscriptionEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?

    private(set) var startedLanguages: [String] = []
    private(set) var stops: [Bool] = []
    private(set) var selectedDevices: [String] = []

    func selectDevice(_ deviceID: String) { selectedDevices.append(deviceID) }
    func start(language: String) throws { startedLanguages.append(language) }
    func stop(cancel: Bool) { stops.append(cancel) }
}

final class TranscriptionEngineTests: XCTestCase {
    // MARK: File engine

    func testProtocolDefaultDeleteWhenDoneIsTrue() {
        let engine: FileTranscriptionEngine = FakeFileTranscriptionEngine()
        let id = UUID()
        // Call the convenience overload (no deleteWhenDone), as AppState does.
        engine.transcribe(
            requestID: id, binaryPath: "/bin/w", modelPath: "/m",
            language: "en", wavPath: "/tmp/a.wav", backend: .cli, prompt: ""
        )
        let fake = engine as! FakeFileTranscriptionEngine
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.requests.first?.deleteWhenDone, true,
                       "the convenience overload must default deleteWhenDone to true")
        XCTAssertEqual(fake.requests.first?.backend, .cli)
    }

    func testFileEngineRecordsAllDrivingCalls() {
        let fake = FakeFileTranscriptionEngine()
        let id = UUID()
        fake.transcribe(
            requestID: id, binaryPath: "/b", modelPath: "/m",
            language: "ru", wavPath: "/w.wav", deleteWhenDone: false,
            backend: .serverAPI, prompt: "vocab"
        )
        fake.warmServer(binaryPath: "/b", modelPath: "/m")
        fake.stopServer()

        XCTAssertEqual(fake.requests, [.init(
            id: id, language: "ru", wavPath: "/w.wav",
            deleteWhenDone: false, backend: .serverAPI, prompt: "vocab"
        )])
        XCTAssertEqual(fake.warmed.count, 1)
        XCTAssertEqual(fake.stopServerCount, 1)
    }

    func testFileEngineCallbacksAreInvokable() {
        let fake = FakeFileTranscriptionEngine()
        var completed: (UUID, String)?
        fake.onTranscriptionComplete = { completed = ($0, $1) }
        let id = UUID()
        fake.onTranscriptionComplete?(id, "hello world")
        XCTAssertEqual(completed?.0, id)
        XCTAssertEqual(completed?.1, "hello world")
    }

    // MARK: Streaming engine

    func testStreamingEngineRecordsLifecycle() throws {
        let fake = FakeStreamingTranscriptionEngine()
        fake.selectDevice("mic-uid-1")
        try fake.start(language: "auto")
        fake.stop(cancel: false)
        fake.stop(cancel: true)
        XCTAssertEqual(fake.selectedDevices, ["mic-uid-1"])
        XCTAssertEqual(fake.startedLanguages, ["auto"])
        XCTAssertEqual(fake.stops, [false, true])
    }

    func testStreamingEngineCallbacksAreInvokable() {
        let fake = FakeStreamingTranscriptionEngine()
        var partials: [String] = []
        var finals: [String] = []
        var levels: [(display: Float, vad: Float)] = []
        fake.onPartial = { partials.append($0) }
        fake.onFinal = { finals.append($0) }
        fake.onLevelChanged = { levels.append((display: $0, vad: $1)) }

        fake.onPartial?("he")
        fake.onPartial?("hello")
        fake.onLevelChanged?(0.4, 0.2)
        fake.onFinal?("hello there")

        XCTAssertEqual(partials, ["he", "hello"])
        XCTAssertEqual(finals, ["hello there"])
        XCTAssertEqual(levels.count, 1)
        XCTAssertEqual(levels.first?.display, 0.4)
        XCTAssertEqual(levels.first?.vad, 0.2)
    }
}
