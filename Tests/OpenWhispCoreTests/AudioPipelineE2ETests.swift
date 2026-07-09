import XCTest
@testable import OpenWhispCore

/// End-to-end pipeline tests (Tier 1 of docs/E2E_AUDIO_TESTING.md): drive fixture
/// audio through the *real* core pipeline — `FileAudioCapture` (real chunking +
/// VAD) → `LiveChunkPipeline` (real out-of-order sequencing) → a scripted
/// transcription engine → `TranscriptCleaner` (real formatting / vocabulary /
/// meta-strip) → a spy `TextOutput` → `TranscriptionHistory`. Everything above the
/// OS audio and the ML model runs its production code.
///
/// A **scripted** engine (canned text per chunk) is used rather than real
/// WhisperKit so these run in plain `swift test` — deterministic and exact,
/// matching the plan's determinism policy ("for logic-focused tests, add a
/// ScriptedTranscriptionEngine that returns canned text — fast and exact"). The
/// real-engine accuracy suite is the Tier-2 / nightly job.
final class AudioPipelineE2ETests: XCTestCase {

    private func fixture(_ name: String) -> URL { FileAudioCaptureTests.fixture(name) }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    // MARK: Streaming transcription baseline

    func testStreamingTranscriptionInsertsInOrder() throws {
        // Scripted engine returns the chunk's ordinal word; the pipeline must
        // reassemble them in order regardless of completion order.
        let engine = ScriptedFileEngine(byOrdinal: ["one", "two", "three", "four"])
        let output = SpyTextOutput()
        let driver = try LiveChunkDriver(
            fixture: fixture("plain_speech.wav"), engine: engine, output: output,
            outputDir: tempDir, chunkDuration: 0.6
        )
        driver.run()

        // plain_speech ~2.5s / 0.6s → 5 chunks; scripted words cycle past 4.
        XCTAssertFalse(output.insertions.isEmpty)
        // Inserted text is a space-joined, ordered reassembly of the chunk texts.
        // The .plain cleaner applies no formatting, so text passes through verbatim.
        let joined = output.insertions.map(\.text).joined(separator: " ")
        XCTAssertEqual(joined, "one two three four one", "got: \(joined)")
    }

    func testOutOfOrderCompletionStillEmitsInOrder() throws {
        // Engine completes chunk 1 before chunk 0; LiveChunkPipeline must hold
        // chunk 1 until chunk 0 is emitted.
        let engine = ScriptedFileEngine(byOrdinal: ["alpha", "bravo", "charlie"],
                                        completionOrder: .reversed)
        let output = SpyTextOutput()
        // maxConcurrent high enough that all 3 chunks dispatch (and the engine
        // buffers all 3) before any completes — then flushReversed() delivers
        // them last-first, which is the out-of-order case under test.
        let driver = try LiveChunkDriver(
            fixture: fixture("plain_speech.wav"), engine: engine, output: output,
            outputDir: tempDir, chunkDuration: 1.0,  // ~3 chunks
            maxConcurrent: 16
        )
        driver.run()

        // Despite reversed completion, LiveChunkPipeline reassembles in chunk order.
        let joined = output.insertions.map(\.text).joined(separator: " ")
        XCTAssertEqual(joined, "alpha bravo charlie")
    }

    // MARK: Smart formatting

    func testSmartFormattingAppliesToTranscript() throws {
        // The scripted transcript carries a spoken-punctuation command and a filler.
        let engine = ScriptedFileEngine(constant: "hello world period um new paragraph done")
        let output = SpyTextOutput()
        var cleaner = TranscriptCleaner.Config.plain
        cleaner.smartFormattingEnabled = true
        cleaner.spokenPunctuationEnabled = true
        cleaner.fillerRemovalEnabled = true
        let driver = try LiveChunkDriver(
            fixture: fixture("plain_speech.wav"), engine: engine, output: output,
            outputDir: tempDir, chunkDuration: 5.0, cleanerConfig: cleaner  // one chunk
        )
        driver.run()

        let text = output.insertions.map(\.text).joined()
        // "period" → ".", "um" filler removed, capitalized.
        XCTAssertTrue(text.contains("Hello world."), "got: \(text)")
        XCTAssertFalse(text.lowercased().contains(" um "), "filler not removed: \(text)")
    }

    // MARK: Vocabulary substitution

    func testVocabularySubstitutionApplies() throws {
        let engine = ScriptedFileEngine(constant: "i use claude code every day")
        let output = SpyTextOutput()
        var cfg = TranscriptCleaner.Config.plain
        cfg.customVocabularyEnabled = true
        cfg.substitutions = [Vocabulary.Substitution(from: "claude code", to: "Claude Code")]
        cfg.smartFormattingEnabled = true
        let driver = try LiveChunkDriver(
            fixture: fixture("plain_speech.wav"), engine: engine, output: output,
            outputDir: tempDir, chunkDuration: 5.0, cleanerConfig: cfg
        )
        driver.run()

        let text = output.insertions.map(\.text).joined()
        XCTAssertTrue(text.contains("Claude Code"), "vocab not applied: \(text)")
    }

    // MARK: Meta-instruction strip (final transcript only)

    func testMetaInstructionStrippedOnFinalTranscript() throws {
        let engine = ScriptedFileEngine(constant: "the meeting is at noon. translate this to English")
        let output = SpyTextOutput()
        var cfg = TranscriptCleaner.Config.plain
        cfg.smartFormattingEnabled = true
        let driver = try LiveChunkDriver(
            fixture: fixture("plain_speech.wav"), engine: engine, output: output,
            outputDir: tempDir, chunkDuration: 5.0, cleanerConfig: cfg,
            finalTranscript: true
        )
        driver.run()

        let text = output.insertions.map(\.text).joined()
        XCTAssertFalse(text.lowercased().contains("translate this"),
                       "meta-instruction not stripped: \(text)")
        XCTAssertTrue(text.contains("meeting is at noon"), "content lost: \(text)")
    }

    // MARK: Silence path → empty outcome

    func testPureSilenceProducesNoInsertion() throws {
        let engine = ScriptedFileEngine(constant: "should never be reached")
        let output = SpyTextOutput()
        let driver = try LiveChunkDriver(
            fixture: fixture("silence.wav"), engine: engine, output: output,
            outputDir: tempDir, mode: .silence
        )
        driver.run()
        // Pause-based streaming emits zero chunks for pure silence → no transcript.
        XCTAssertTrue(output.insertions.isEmpty)
        XCTAssertEqual(driver.chunkCount, 0)
    }

    // MARK: Silence-based (VAD) two-utterance split feeds two transcripts

    func testTwoUtterancesProduceTwoTranscribedChunks() throws {
        let engine = ScriptedFileEngine(byOrdinal: ["first", "second"])
        let output = SpyTextOutput()
        let driver = try LiveChunkDriver(
            fixture: fixture("two_utterances.wav"), engine: engine, output: output,
            outputDir: tempDir, mode: .silence
        )
        driver.run()
        XCTAssertEqual(driver.chunkCount, 2)
        // .plain cleaner → verbatim; two VAD-split utterances, in order.
        let joined = output.insertions.map(\.text).joined(separator: " ")
        XCTAssertEqual(joined, "first second")
    }

    // MARK: History

    func testCompletedSessionRecordsHistoryEntry() throws {
        let engine = ScriptedFileEngine(constant: "remember this transcript")
        let output = SpyTextOutput()
        let driver = try LiveChunkDriver(
            fixture: fixture("plain_speech.wav"), engine: engine, output: output,
            outputDir: tempDir, chunkDuration: 5.0
        )
        driver.run()

        let entry = try XCTUnwrap(driver.historyEntries.last)
        XCTAssertTrue(entry.text.contains("remember this transcript"))
    }

    // MARK: Engine error → no output, surfaced

    func testEngineErrorProducesNoInsertionAndIsRecorded() throws {
        let engine = ScriptedFileEngine(constant: "unused", failWithMessage: "model exploded")
        let output = SpyTextOutput()
        let driver = try LiveChunkDriver(
            fixture: fixture("plain_speech.wav"), engine: engine, output: output,
            outputDir: tempDir, chunkDuration: 5.0
        )
        driver.run()
        XCTAssertTrue(output.insertions.isEmpty)
        XCTAssertFalse(driver.errors.isEmpty)
    }
}

// MARK: - Test doubles + driver

/// A `FileTranscriptionEngine` that returns canned text for each chunk WAV,
/// deterministically. Completion can be delivered in reverse to exercise the
/// pipeline's out-of-order reassembly.
final class ScriptedFileEngine: FileTranscriptionEngine {
    enum CompletionOrder { case inOrder, reversed }

    var onTranscriptionComplete: ((UUID, String) -> Void)?
    var onTranscriptionError: ((UUID, String) -> Void)?
    var onProgress: ((Int) -> Void)?
    var onWorkerStatus: ((String) -> Void)?

    private let texts: [String]?             // by ordinal (cycled) if set
    private let constant: String?            // same text for every chunk if set
    private let failMessage: String?
    private let completionOrder: CompletionOrder
    private var ordinal = 0

    /// Buffered (requestID, text) so `reversed` can flush them last-first.
    private var buffered: [(UUID, String)] = []

    init(byOrdinal texts: [String], completionOrder: CompletionOrder = .inOrder) {
        self.texts = texts; self.constant = nil; self.failMessage = nil
        self.completionOrder = completionOrder
    }
    init(constant: String, failWithMessage: String? = nil) {
        self.texts = nil; self.constant = constant; self.failMessage = failWithMessage
        self.completionOrder = .inOrder
    }

    func transcribe(requestID: UUID, binaryPath: String, modelPath: String,
                    language: String, wavPath: String, deleteWhenDone: Bool,
                    backend: WhisperBackend, prompt: String) {
        if let failMessage {
            onTranscriptionError?(requestID, failMessage)
            return
        }
        let text: String
        if let constant { text = constant }
        else if let texts, !texts.isEmpty { text = texts[ordinal % texts.count]; ordinal += 1 }
        else { text = "" }

        switch completionOrder {
        case .inOrder:
            onTranscriptionComplete?(requestID, text)
        case .reversed:
            buffered.append((requestID, text))
        }
        if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
    }

    /// Flush buffered completions in reverse arrival order (for `reversed`).
    func flushReversed() {
        for (id, text) in buffered.reversed() { onTranscriptionComplete?(id, text) }
        buffered.removeAll()
    }

    func warmServer(binaryPath: String, modelPath: String) {}
    func stopServer() {}
}

/// Wires the real core pipeline the way AppState's live-chunk mode does, so a test
/// can drive fixture audio all the way to inserted text + history. Kept in the
/// test target (it's test orchestration, not shipping code) but uses only real
/// core types.
final class LiveChunkDriver {
    enum Mode { case fixed(Double), silence }

    private let capture: FileAudioCapture
    private let engine: ScriptedFileEngine
    private let output: SpyTextOutput
    private let cleaner: TranscriptCleaner
    private let finalTranscript: Bool
    private let mode: Mode

    private var pipeline: LiveChunkPipeline
    /// chunkID → its file URL, and chunkID → the requestID we dispatched for it.
    private var urlByChunk: [LiveChunkPipeline.ChunkID: URL] = [:]
    private var chunkByRequest: [UUID: LiveChunkPipeline.ChunkID] = [:]

    private(set) var chunkCount = 0
    private(set) var errors: [String] = []
    private(set) var historyEntries: [TranscriptionEntry] = []
    private var collected: [String] = []

    init(fixture: URL, engine: ScriptedFileEngine, output: SpyTextOutput,
         outputDir: URL, chunkDuration: Double = 1.0,
         mode: Mode = .fixed(1.0),
         cleanerConfig: TranscriptCleaner.Config = .plain,
         finalTranscript: Bool = false,
         maxConcurrent: Int = 2) throws {
        self.pipeline = LiveChunkPipeline(maxConcurrent: maxConcurrent)
        self.capture = try FileAudioCapture(fixtureURL: fixture, outputDirectory: outputDir)
        self.engine = engine
        self.output = output
        self.cleaner = TranscriptCleaner(config: cleanerConfig)
        self.finalTranscript = finalTranscript
        // If a concrete chunkDuration was passed, honor it as fixed mode; a caller
        // wanting VAD passes `mode: .silence` explicitly.
        switch mode {
        case .fixed: self.mode = .fixed(chunkDuration)
        case .silence: self.mode = .silence
        }

        engine.onTranscriptionComplete = { [weak self] id, text in
            self?.handleComplete(id: id, text: text)
        }
        engine.onTranscriptionError = { [weak self] _, msg in
            self?.errors.append(msg)
        }
    }

    func run() {
        let onChunk: (URL?) -> Void = { [weak self] url in
            guard let self, let url else { return }
            self.chunkCount += 1
            let id = self.pipeline.enqueue()
            self.urlByChunk[id] = url
            self.dispatch()
        }

        switch mode {
        case .fixed(let d): capture.startStreaming(chunkDuration: d, onChunk: onChunk)
        case .silence:      capture.startStreamingOnSilence(onChunk: onChunk)
        }

        // For reversed completion order, the engine buffered results; flush now
        // that all chunks are enqueued, then dispatch/flush again.
        engine.flushReversed()
        dispatch()

        finish()
    }

    private func dispatch() {
        for id in pipeline.dispatchable() {
            guard let url = urlByChunk[id] else { continue }
            let reqID = UUID()
            chunkByRequest[reqID] = id
            engine.transcribe(
                requestID: reqID, binaryPath: "", modelPath: "", language: "en",
                wavPath: url.path, deleteWhenDone: false, backend: .cli, prompt: ""
            )
        }
    }

    private func handleComplete(id requestID: UUID, text: String) {
        guard let chunkID = chunkByRequest[requestID] else { return }
        let cleaned = cleaner.clean(text, isFinalTranscript: finalTranscript)
        pipeline.complete(chunkID, text: cleaned)
        // Free concurrency, then emit the contiguous ready prefix.
        dispatch()
        for ready in pipeline.takeOrderedReady() where !ready.isEmpty {
            collected.append(ready)
            pipeline.queueForInsertion([ready])
            drainInsertions()
        }
    }

    private func drainInsertions() {
        while let next = pipeline.nextInsertion() {
            output.insert(next, mode: .auto, restoreClipboard: false) { [weak self] _ in
                self?.pipeline.finishInsertion()
            }
        }
    }

    private func finish() {
        capture.stop()
        guard !collected.isEmpty else { return }
        let full = collected.joined(separator: " ")
        historyEntries.append(TranscriptionEntry(
            text: full, date: Date(timeIntervalSince1970: 0),
            appBundleID: "com.test", appName: "Test"
        ))
    }
}

extension TranscriptCleaner.Config {
    /// A pass-through config: no vocab, no formatting. Tests opt features in.
    static var plain: TranscriptCleaner.Config {
        .init(language: "en", customVocabularyEnabled: false, substitutions: [],
              smartFormattingEnabled: false, fillerRemovalEnabled: false,
              spokenPunctuationEnabled: false)
    }
}
