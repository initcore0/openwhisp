import XCTest
@testable import OpenWhispCore

/// Unit tests for the `FileAudioCapture` fixture-replay seam itself (its WAV
/// round-trip, chunk slicing, level emission, and pause-based VAD arithmetic).
/// The broader pipeline-integration tests that *use* it live in
/// `AudioPipelineE2ETests`.
final class FileAudioCaptureTests: XCTestCase {

    // MARK: Fixture location

    /// The checked-in fixtures live at <repo>/Tests/Fixtures/audio. `#file` is
    /// this source file; walk up to the package root.
    static func fixture(_ name: String) -> URL {
        let thisFile = URL(fileURLWithPath: #file)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // OpenWhispCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // <repo>
        return repoRoot
            .appendingPathComponent("Tests/Fixtures/audio")
            .appendingPathComponent(name)
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fac-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: WAV round-trip

    func testWAVWriteThenReadRoundTrips() throws {
        // A ramp so we'd notice byte/endianness corruption, not just zeros.
        let original: [Int16] = (0..<2000).map { Int16(truncatingIfNeeded: $0 * 7 - 5000) }
        let url = tempDir.appendingPathComponent("rt.wav")
        try WAVFile.write(samples: original, to: url)

        let parsed = try WAVFile.read(url)
        XCTAssertEqual(parsed.sampleRate, 16_000)
        XCTAssertEqual(parsed.channels, 1)
        XCTAssertEqual(parsed.bitsPerSample, 16)
        XCTAssertEqual(parsed.samples, original)
    }

    func testWrittenWAVIsValidRIFFForRealEngines() throws {
        // Guards the on-disk header shape a real whisper.cpp/WhisperKit chunk needs.
        let url = tempDir.appendingPathComponent("hdr.wav")
        try WAVFile.write(samples: [1, 2, 3, 4], to: url)
        let d = try Data(contentsOf: url)
        XCTAssertEqual(d.subdata(in: 0..<4), Data("RIFF".utf8))
        XCTAssertEqual(d.subdata(in: 8..<12), Data("WAVE".utf8))
        XCTAssertEqual(d.subdata(in: 12..<16), Data("fmt ".utf8))
        // data chunk size == 4 samples * 2 bytes
        XCTAssertEqual(d.count, 44 + 8)  // 44-byte header + 8 bytes of samples
    }

    func testParseRejectsNonRIFF() {
        XCTAssertThrowsError(try WAVFile.parse(Data("not a wav file at all".utf8))) { err in
            XCTAssertEqual(err as? WAVFile.Error, .notRIFF)
        }
    }

    // MARK: Fixture parsing

    func testParsesFixtureFormat() throws {
        let cap = try FileAudioCapture(fixtureURL: Self.fixture("plain_speech.wav"),
                                       outputDirectory: tempDir)
        // ~2.5 s at 16 kHz; assert it read a nontrivial amount of audio.
        var levels: [Float] = []
        cap.onLevelChanged = { levels.append($0) }
        cap.start()
        XCTAssertGreaterThan(levels.count, 10)  // many ~0.1s buffers
        XCTAssertTrue(levels.contains { $0 > 0.3 })  // speech reads high
    }

    func testRejectsMalformedFixture() throws {
        // A file that looks RIFF/WAVE but has no fmt/data chunks must throw at
        // construction rather than silently replaying zero audio.
        let bad = tempDir.appendingPathComponent("bad.wav")
        try Data("RIFFxxxxWAVEjunk".utf8).write(to: bad)
        XCTAssertThrowsError(try FileAudioCapture(fixtureURL: bad, outputDirectory: tempDir))
    }

    // MARK: Fixed-interval chunk streaming

    func testFixedStreamingSlicesIntoChunks() throws {
        let cap = try FileAudioCapture(fixtureURL: Self.fixture("plain_speech.wav"),
                                       outputDirectory: tempDir)
        var chunks: [URL?] = []
        cap.startStreaming(chunkDuration: 1.0) { chunks.append($0) }
        // ~2.5 s / 1.0 s → 3 chunks (last is partial).
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0 != nil })
        // Each emitted chunk is a real, parseable WAV.
        for url in chunks.compactMap({ $0 }) {
            let parsed = try WAVFile.read(url)
            XCTAssertEqual(parsed.sampleRate, 16_000)
            XCTAssertFalse(parsed.samples.isEmpty)
        }
        XCTAssertEqual(cap.emittedChunkURLs.count, 3)
    }

    func testFixedStreamingChunkDurationsSumToWhole() throws {
        let cap = try FileAudioCapture(fixtureURL: Self.fixture("plain_speech.wav"),
                                       outputDirectory: tempDir)
        var totalFrames = 0
        cap.startStreaming(chunkDuration: 0.5) { url in
            if let url, let p = try? WAVFile.read(url) { totalFrames += p.samples.count }
        }
        // Reassembled chunks == the whole fixture (no samples dropped/duplicated).
        let whole = try WAVFile.read(Self.fixture("plain_speech.wav"))
        XCTAssertEqual(totalFrames, whole.samples.count)
    }

    // MARK: Pause-based (silence) streaming — the VAD path

    func testSilenceStreamingEmitsSingleChunkForContinuousSpeech() throws {
        let cap = try FileAudioCapture(fixtureURL: Self.fixture("plain_speech.wav"),
                                       outputDirectory: tempDir)
        var chunks: [URL?] = []
        cap.startStreamingOnSilence { chunks.append($0) }  // recorder defaults
        // Continuous speech with no long internal gap → exactly one utterance.
        XCTAssertEqual(chunks.count, 1)
    }

    func testSilenceStreamingSplitsTwoUtterances() throws {
        let cap = try FileAudioCapture(fixtureURL: Self.fixture("two_utterances.wav"),
                                       outputDirectory: tempDir)
        var chunks: [URL?] = []
        // The gap is 1.0 s; default silenceDuration is 0.75 s, so it splits.
        cap.startStreamingOnSilence { chunks.append($0) }
        XCTAssertEqual(chunks.count, 2, "1s gap should split into two utterances")
    }

    func testSilenceStreamingDropsLeadingAndPureSilence() throws {
        let cap = try FileAudioCapture(fixtureURL: Self.fixture("silence.wav"),
                                       outputDirectory: tempDir)
        var chunks: [URL?] = []
        cap.startStreamingOnSilence { chunks.append($0) }
        XCTAssertEqual(chunks.count, 0, "pure silence emits no chunk")
    }

    func testSilenceStreamingFinalizesAfterSpeechThenSilence() throws {
        let cap = try FileAudioCapture(fixtureURL: Self.fixture("speech_then_silence.wav"),
                                       outputDirectory: tempDir)
        var chunks: [URL?] = []
        cap.startStreamingOnSilence { chunks.append($0) }
        // One utterance, finalized by the trailing 2 s of silence.
        XCTAssertEqual(chunks.count, 1)
    }

    // MARK: RMS

    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(FileAudioCapture.rms(of: [Int16](repeating: 0, count: 1600)), 0)
    }

    func testRMSOfFullScaleToneIsNearOne() {
        // Alternating +/- max reads RMS ~1.0 (|sample|/32768 ≈ 1 every frame).
        let tone: [Int16] = (0..<1600).map { $0 % 2 == 0 ? Int16.max : Int16.min + 1 }
        XCTAssertEqual(FileAudioCapture.rms(of: tone), 1.0, accuracy: 0.001)
    }

    // MARK: State callbacks

    func testStateTransitionsRecordingThenStopped() throws {
        let cap = try FileAudioCapture(fixtureURL: Self.fixture("plain_speech.wav"),
                                       outputDirectory: tempDir)
        var states: [RecorderState] = []
        cap.onStateChanged = { states.append($0) }
        cap.start()
        cap.stop()
        XCTAssertEqual(states, [.recording, .stopped])
    }

    func testStartReturnsWholeFixtureOnStop() throws {
        let cap = try FileAudioCapture(fixtureURL: Self.fixture("plain_speech.wav"),
                                       outputDirectory: tempDir)
        cap.start()
        var returned: URL? = nil
        cap.stop { returned = $0 }
        let url = try XCTUnwrap(returned)
        let parsed = try WAVFile.read(url)
        let whole = try WAVFile.read(Self.fixture("plain_speech.wav"))
        XCTAssertEqual(parsed.samples.count, whole.samples.count)
    }

    func testConformsToAudioCaptureProtocol() throws {
        // The whole point: it's substitutable for the real recorder.
        let cap: AudioCapture = try FileAudioCapture(
            fixtureURL: Self.fixture("plain_speech.wav"), outputDirectory: tempDir)
        cap.selectDevice("fixture")
        cap.start()
        cap.stop()
        XCTAssertTrue(cap === cap)  // exists and is an AudioCapture; no crash.
    }
}
