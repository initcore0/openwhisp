import XCTest
import Foundation
@testable import OpenWhispCore

/// Feature-matrix integration tests (Phase B of docs/E2E_AUDIO_TESTING.md): each
/// test drives fixture audio through the REAL core pipeline + state machines and
/// asserts one shipped feature composes end-to-end — script post-processor, LLM
/// refine, output/SecureFieldPolicy, agent-bridge dictate routing + rate limiting,
/// and multilingual/profile behavior differences. Reuses the doubles + driver from
/// AudioPipelineE2ETests (FileAudioCapture, ScriptedFileEngine, SpyTextOutput,
/// LiveChunkDriver). See the "adding a test for a new feature" guide in the plan.

// MARK: - File-scoped helpers

private func bridgeFrame(_ json: String) -> Data { Data(json.utf8) }
private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + seconds) }

private func runScriptFeature(
    script: String,
    input: String,
    outputDir: URL
) -> (stdout: String?, exitCode: Int32?, launchFailed: Bool) {
    let scriptURL = outputDir.appendingPathComponent("post-\(UUID().uuidString).sh")
    do {
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    } catch {
        return (nil, nil, true)
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = [scriptURL.path]
    let outPipe = Pipe()
    let inPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardInput = inPipe
    do {
        try proc.run()
    } catch {
        return (nil, nil, true)
    }
    // Feed the transcript on stdin, then read stdout to completion.
    if let data = input.data(using: .utf8) {
        inPipe.fileHandleForWriting.write(data)
    }
    try? inPipe.fileHandleForWriting.close()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let stdout = String(data: outData, encoding: .utf8)
    return (stdout, proc.terminationStatus, false)
}

final class FeatureMatrixE2ETests: XCTestCase {

    private func fixture(_ name: String) -> URL { FileAudioCaptureTests.fixture(name) }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    // MARK: - (1) LanguageResolver — engine language setting matrix

    /// translateToEnglish && engine != appleSpeech → the translate sentinel is what
    /// the engine is told to do; the plain language never reaches the engine.
    func testEngineLanguageIsTranslateSentinelWhenTranslatingOnWhisper() {
        let setting = LanguageResolver.engineLanguageSetting(
            language: "de", translateToEnglish: true, transcriptionEngine: "whisperKit")
        XCTAssertEqual(setting, WhisperTask.translateToEnglishSetting)
        XCTAssertEqual(setting, "translate-en")
        XCTAssertNotEqual(setting, "de", "spoken language must not be handed to the engine when translating")
    }

    /// No translate → the plain spoken language flows straight through to the engine,
    /// whether it's an explicit locale or the "auto" detect sentinel.
    func testEngineLanguageIsPlainLanguageWhenNotTranslating() {
        XCTAssertEqual(
            LanguageResolver.engineLanguageSetting(
                language: "fr", translateToEnglish: false, transcriptionEngine: "whisperKit"),
            "fr")
        XCTAssertEqual(
            LanguageResolver.engineLanguageSetting(
                language: "auto", translateToEnglish: false, transcriptionEngine: "whisperKit"),
            "auto")
    }

    /// Apple Speech has no translate concept: even with translateToEnglish ON, the
    /// engine setting stays the plain locale — the sentinel is suppressed for it.
    func testAppleSpeechNeverGetsTranslateSentinel() {
        let setting = LanguageResolver.engineLanguageSetting(
            language: "de", translateToEnglish: true, transcriptionEngine: "appleSpeech")
        XCTAssertEqual(setting, "de")
        XCTAssertNotEqual(setting, WhisperTask.translateToEnglishSetting)
    }

    /// The whole cross product in one table, so a rule change that breaks any cell
    /// (translate-suppression for appleSpeech, sentinel for the rest) fails loudly.
    func testEngineLanguageMatrixAcrossEnginesAndTranslateFlag() {
        let sentinel = WhisperTask.translateToEnglishSetting
        let cases: [(engine: String, translate: Bool, language: String, expected: String)] = [
            ("whisperKit", true,  "de",   sentinel),
            ("whisperKit", false, "de",   "de"),
            ("whisperKit", true,  "auto", sentinel),
            ("appleSpeech", true,  "de",   "de"),     // suppressed
            ("appleSpeech", false, "de",   "de"),
            ("appleSpeech", true,  "auto", "auto"),   // suppressed
        ]
        for c in cases {
            XCTAssertEqual(
                LanguageResolver.engineLanguageSetting(
                    language: c.language, translateToEnglish: c.translate, transcriptionEngine: c.engine),
                c.expected,
                "engine=\(c.engine) translate=\(c.translate) lang=\(c.language)")
        }
    }

    // MARK: - (1) LanguageResolver — output language for cleaning

    /// The language used to pick formatting rules is 'en' when translating (the
    /// output IS English regardless of what was spoken), else the spoken language.
    func testOutputLanguageForCleaningEnglishOnlyWhenTranslating() {
        XCTAssertEqual(
            LanguageResolver.outputLanguageForCleaning(
                language: "de", translateToEnglish: true, transcriptionEngine: "whisperKit"),
            "en")
        XCTAssertEqual(
            LanguageResolver.outputLanguageForCleaning(
                language: "de", translateToEnglish: false, transcriptionEngine: "whisperKit"),
            "de")
        // appleSpeech suppresses translate on this derivation too → stays spoken lang.
        XCTAssertEqual(
            LanguageResolver.outputLanguageForCleaning(
                language: "de", translateToEnglish: true, transcriptionEngine: "appleSpeech"),
            "de")
    }

    /// End-to-end: the two resolver derivations agree on the same rule. When
    /// translating on a whisper engine, the engine is told "translate-en" AND the
    /// cleaner is told "en" — the output-language derivation must never leak the
    /// spoken locale that the engine derivation is hiding.
    func testResolverDerivationsAgreeWhenTranslating() {
        let engineSetting = LanguageResolver.engineLanguageSetting(
            language: "ja", translateToEnglish: true, transcriptionEngine: "whisperKit")
        let cleanLang = LanguageResolver.outputLanguageForCleaning(
            language: "ja", translateToEnglish: true, transcriptionEngine: "whisperKit")
        XCTAssertEqual(engineSetting, WhisperTask.translateToEnglishSetting)
        XCTAssertEqual(cleanLang, "en")
        XCTAssertNotEqual(cleanLang, "ja")
    }

    // MARK: - (2) Same fixture, different profiles → different behavior

    /// Drive ONE fixture + ONE scripted transcript through the real cleaner twice,
    /// under two profiles that differ only in `spokenPunctuationEnabled`. The
    /// spoken word "period" must become "." only in the profile that enabled it —
    /// proving a settings toggle changes end-to-end output for identical audio.
    func testSpokenPunctuationProfileChangesOutputForSameFixture() throws {
        let transcript = "meet me at noon period bring the report"

        // Profile A: spoken punctuation OFF (but smart formatting on so caps still run).
        var offCfg = TranscriptCleaner.Config.plain
        offCfg.smartFormattingEnabled = true
        offCfg.spokenPunctuationEnabled = false
        let offText = try driveCleaned(
            fixture: "plain_speech.wav", transcript: transcript, config: offCfg)

        // Profile B: spoken punctuation ON.
        var onCfg = TranscriptCleaner.Config.plain
        onCfg.smartFormattingEnabled = true
        onCfg.spokenPunctuationEnabled = true
        let onText = try driveCleaned(
            fixture: "plain_speech.wav", transcript: transcript, config: onCfg)

        // Same fixture, same words → different formatting.
        XCTAssertNotEqual(offText, onText, "profiles produced identical output")
        // ON turned the spoken command into a real period.
        XCTAssertTrue(onText.contains("noon."), "spoken 'period' not applied: \(onText)")
        XCTAssertFalse(onText.lowercased().contains(" period "),
                       "literal 'period' should be gone when enabled: \(onText)")
        // OFF left the literal word in place, no period symbol attached to "noon".
        XCTAssertTrue(offText.lowercased().contains("period"),
                      "literal 'period' should survive when disabled: \(offText)")
        XCTAssertFalse(offText.contains("noon."),
                       "no punctuation should be synthesized when disabled: \(offText)")
    }

    /// Same fixture + transcript cleaned under two LANGUAGE profiles resolved via
    /// LanguageResolver. English-like output (translate-to-English → 'en') runs the
    /// sentence-capitalization / "i"→"I" passes; a non-English spoken language ('de',
    /// no translate) skips them. So the resolver's output language, computed from the
    /// same translate/engine inputs, drives a visible formatting difference.
    func testResolvedOutputLanguageChangesCapitalizationForSameFixture() throws {
        // Lowercase, no terminal punctuation, contains a standalone "i".
        let transcript = "i think this is fine"

        // Profile EN: translate-to-English on whisper → cleaner language resolves 'en'.
        let enLang = LanguageResolver.outputLanguageForCleaning(
            language: "de", translateToEnglish: true, transcriptionEngine: "whisperKit")
        XCTAssertEqual(enLang, "en")
        var enCfg = TranscriptCleaner.Config.plain
        enCfg.language = enLang
        enCfg.smartFormattingEnabled = true
        let enText = try driveCleaned(
            fixture: "plain_speech.wav", transcript: transcript, config: enCfg)

        // Profile DE: German, no translate → cleaner language resolves 'de'.
        let deLang = LanguageResolver.outputLanguageForCleaning(
            language: "de", translateToEnglish: false, transcriptionEngine: "whisperKit")
        XCTAssertEqual(deLang, "de")
        var deCfg = TranscriptCleaner.Config.plain
        deCfg.language = deLang
        deCfg.smartFormattingEnabled = true
        let deText = try driveCleaned(
            fixture: "plain_speech.wav", transcript: transcript, config: deCfg)

        // Same fixture, same words → different formatting because of resolved language.
        XCTAssertNotEqual(enText, deText, "language profiles produced identical output")
        // English-like: standalone "i" is capitalized and the sentence starts uppercase.
        XCTAssertTrue(enText.hasPrefix("I"), "english caps not applied: \(enText)")
        XCTAssertTrue(enText.contains("I think"), "standalone i not capitalized: \(enText)")
        // German: capitalization passes are gated out → text stays as spoken.
        XCTAssertTrue(deText.hasPrefix("i"), "german should not capitalize sentence start: \(deText)")
        XCTAssertFalse(deText.contains("I think"), "german should not capitalize standalone i: \(deText)")
    }

    /// The translate profile and the plain-German profile are BOTH consistent from
    /// engine setting through to cleaned output for the same audio: translate →
    /// engine sees the sentinel and the cleaner formats as English; German → engine
    /// sees "de" and the cleaner skips English caps. One assertion chain covers the
    /// whole multilingual seam on a single fixture.
    func testTranslateVsGermanProfileConsistentEngineToOutput() throws {
        let transcript = "i wrote it down"

        // Translate profile.
        let tEngine = LanguageResolver.engineLanguageSetting(
            language: "de", translateToEnglish: true, transcriptionEngine: "whisperKit")
        let tClean = LanguageResolver.outputLanguageForCleaning(
            language: "de", translateToEnglish: true, transcriptionEngine: "whisperKit")
        XCTAssertEqual(tEngine, WhisperTask.translateToEnglishSetting)
        var tCfg = TranscriptCleaner.Config.plain
        tCfg.language = tClean; tCfg.smartFormattingEnabled = true
        let tText = try driveCleaned(fixture: "plain_speech.wav", transcript: transcript, config: tCfg)

        // Plain German profile.
        let gEngine = LanguageResolver.engineLanguageSetting(
            language: "de", translateToEnglish: false, transcriptionEngine: "whisperKit")
        let gClean = LanguageResolver.outputLanguageForCleaning(
            language: "de", translateToEnglish: false, transcriptionEngine: "whisperKit")
        XCTAssertEqual(gEngine, "de")
        var gCfg = TranscriptCleaner.Config.plain
        gCfg.language = gClean; gCfg.smartFormattingEnabled = true
        let gText = try driveCleaned(fixture: "plain_speech.wav", transcript: transcript, config: gCfg)

        XCTAssertTrue(tText.hasPrefix("I"), "translate output should be English-capitalized: \(tText)")
        XCTAssertTrue(gText.hasPrefix("i"), "german output should be left as-is: \(gText)")
        XCTAssertNotEqual(tText, gText)
    }

    // MARK: - Helper (local to this suite; not one of the shared doubles)

    /// Drive one fixture through the real FileAudioCapture → LiveChunkPipeline →
    /// ScriptedFileEngine → TranscriptCleaner → SpyTextOutput path with a single
    /// chunk carrying `transcript`, and return the joined cleaned output. A large
    /// chunkDuration guarantees one chunk so the scripted constant is emitted once.
    private func driveCleaned(
        fixture name: String, transcript: String, config: TranscriptCleaner.Config
    ) throws -> String {
        let engine = ScriptedFileEngine(constant: transcript)
        let output = SpyTextOutput()
        let driver = try LiveChunkDriver(
            fixture: fixture(name), engine: engine, output: output,
            outputDir: tempDir, chunkDuration: 30.0, cleanerConfig: config
        )
        driver.run()
        return output.insertions.map(\.text).joined()
    }


    // MARK: - LLM refine feature, driven from fixture audio
    //
    // These exercise the two-utterance refine flow end-to-end: real FileAudioCapture
    // replays a VAD-splittable fixture, a ScriptedFileEngine turns each utterance
    // into canned text (step-1 content, then the spoken instruction), and the pure
    // RefineFlow state machine + a LOCAL LLM stub (no network) drive the lifecycle
    // to inserted text. The scripted engine stands in for WhisperKit so this is
    // deterministic in plain `swift test`.

    /// Replay a VAD-splittable fixture through the real capture + a scripted engine
    /// and return the transcribed text of each utterance, in order. Two-utterance
    /// fixtures yield [step1, instruction]. Small local harness (not a shipping
    /// type); ScriptedFileEngine/FileAudioCapture are the real reused doubles.
    private func transcribeUtterances(fixtureName: String,
                                      transcripts: [String],
                                      outputDir: URL) throws -> [String] {
        let engine = ScriptedFileEngine(byOrdinal: transcripts)
        let capture = try FileAudioCapture(fixtureURL: FileAudioCaptureTests.fixture(fixtureName),
                                           outputDirectory: outputDir)
        var collected: [String] = []
        engine.onTranscriptionComplete = { _, text in collected.append(text) }
        capture.startStreamingOnSilence { url in
            guard let url else { return }
            engine.transcribe(requestID: UUID(), binaryPath: "", modelPath: "",
                              language: "en", wavPath: url.path, deleteWhenDone: false,
                              backend: .cli, prompt: "")
        }
        capture.stop()
        return collected
    }

    /// A local, deterministic "LLM": applies a trivial transform to the payload so
    /// tests can assert the refined text is what flowed back through RefineFlow.
    /// No network, no model — pure string work.
    private func stubLLM(payload: String) -> String {
        // Pretend the model rewrote the TEXT per the INSTRUCTION by upcasing it.
        // The exact transform is irrelevant; what matters is that RefineFlow carries
        // this value through .llmSucceeded → .insert unchanged.
        if let range = payload.range(of: "TEXT:\n") {
            return String(payload[range.upperBound...]).uppercased()
        }
        return payload.uppercased()
    }

    func testRefineFromAudioEngagesRunsLLMAndInsertsRefinedText() throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        // Two-utterance fixture → [step-1 content, spoken instruction].
        let utterances = try transcribeUtterances(
            fixtureName: "two_utterances.wav",
            transcripts: ["hello team i am out sick today", "make it formal"],
            outputDir: outputDir
        )
        XCTAssertEqual(utterances.count, 2, "VAD should split into step-1 + instruction; got \(utterances)")
        let step1 = utterances[0]
        let instruction = utterances[1]

        var flow = RefineFlow()

        // Engage with the just-finalized step-1 content (not from a selection).
        let engageEffects = flow.handle(.engage(step1: step1, fromSelection: false))
        XCTAssertEqual(engageEffects, [.startInstructionCapture])
        XCTAssertTrue(flow.isActive)
        XCTAssertFalse(flow.isApplying)

        // The instruction utterance finalizes → machine must ask to run the LLM with
        // exactly this step-1 + instruction.
        let instrEffects = flow.handle(.instructionFinalized(instruction))
        XCTAssertEqual(instrEffects, [.runLLM(step1: step1, instruction: instruction)])
        XCTAssertTrue(flow.isApplying, "flow should report the LLM as in flight")

        // Build the payload the real app would send, run it through the local stub,
        // then feed the result back as .llmSucceeded.
        let payload = InstructionChain.userPayload(instruction: instruction, text: step1)
        let refined = stubLLM(payload: payload)
        let successEffects = flow.handle(.llmSucceeded(refined))

        // Refined text is inserted (not replacing a selection, since step-1 was a
        // dictation), followed by a status.
        XCTAssertEqual(successEffects, [
            .insert(text: refined, replacingSelection: false),
            .status("Instruction applied")
        ])
        XCTAssertEqual(refined, "HELLO TEAM I AM OUT SICK TODAY",
                       "stub LLM output must flow through unchanged; got \(refined)")
        XCTAssertFalse(flow.isActive, "flow returns to inactive after applying")
    }

    func testRefineFromSelectionReplacesSelectionOnSuccess() throws {
        // Refine over a text SELECTION: on success the insert must replace the
        // selection. Step-1 is a selection, so no audio is needed for it; the
        // instruction still comes from a dictated utterance.
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let selection = "the quarterly numbers look good"
        let utterances = try transcribeUtterances(
            fixtureName: "plain_speech.wav",
            transcripts: ["translate to french"],
            outputDir: outputDir
        )
        let instruction = try XCTUnwrap(utterances.first)

        var flow = RefineFlow()
        _ = flow.handle(.engage(step1: selection, fromSelection: true))
        let runEffects = flow.handle(.instructionFinalized(instruction))
        XCTAssertEqual(runEffects, [.runLLM(step1: selection, instruction: instruction)])

        let refined = stubLLM(payload: InstructionChain.userPayload(instruction: instruction, text: selection))
        let effects = flow.handle(.llmSucceeded(refined))
        // replacingSelection must be TRUE for a selection source.
        XCTAssertEqual(effects, [
            .insert(text: refined, replacingSelection: true),
            .status("Instruction applied")
        ])
    }

    func testRefineLLMFailureInsertsOriginalStep1() throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let utterances = try transcribeUtterances(
            fixtureName: "two_utterances.wav",
            transcripts: ["draft the release note", "make it punchy"],
            outputDir: outputDir
        )
        XCTAssertEqual(utterances.count, 2)
        let step1 = utterances[0]
        let instruction = utterances[1]

        var flow = RefineFlow()
        _ = flow.handle(.engage(step1: step1, fromSelection: false))
        _ = flow.handle(.instructionFinalized(instruction))

        // Local "LLM" errored — the original step-1 must be inserted so the user's
        // dictation is never lost, plus a failure status.
        let effects = flow.handle(.llmFailed("model exploded"))
        XCTAssertEqual(effects.count, 2)
        XCTAssertEqual(effects.first, .insert(text: step1, replacingSelection: false))
        if case let .status(msg) = effects[1] {
            XCTAssertTrue(msg.contains("model exploded"), "failure reason should surface: \(msg)")
            XCTAssertTrue(msg.lowercased().contains("inserted text"))
        } else {
            XCTFail("expected a status effect, got \(effects[1])")
        }
        XCTAssertFalse(flow.isActive)
    }

    func testRefineNoInstructionHeardInsertsOriginalForDictation() throws {
        // Step-1 dictated but the instruction utterance came back empty (e.g. the
        // user released without speaking). For a DICTATION source the content is
        // inserted unchanged; the LLM is never invoked.
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let utterances = try transcribeUtterances(
            fixtureName: "plain_speech.wav",
            transcripts: ["remember to buy milk"],
            outputDir: outputDir
        )
        let step1 = try XCTUnwrap(utterances.first)

        var flow = RefineFlow()
        _ = flow.handle(.engage(step1: step1, fromSelection: false))
        // Empty instruction → no LLM, insert step-1, status.
        let effects = flow.handle(.instructionFinalized("   "))
        XCTAssertEqual(effects, [
            .insert(text: step1, replacingSelection: false),
            .status("No instruction heard; inserted text")
        ])
        // Crucially, NO runLLM was emitted.
        XCTAssertFalse(effects.contains { if case .runLLM = $0 { return true }; return false })
        XCTAssertFalse(flow.isActive)
    }

    func testRefineNoInstructionOnSelectionLeavesTextUntouched() throws {
        // Same empty-instruction case but the source is a SELECTION: we must NOT
        // paste over the user's own text — just finish quietly.
        var flow = RefineFlow()
        _ = flow.handle(.engage(step1: "user's existing paragraph", fromSelection: true))
        let effects = flow.handle(.instructionFinalized(""))
        XCTAssertEqual(effects, [.finishQuietly(status: "No instruction heard")])
        // No insert at all — the selection is preserved.
        XCTAssertFalse(effects.contains { if case .insert = $0 { return true }; return false })
        XCTAssertFalse(flow.isActive)
    }

    func testRefinePendingStep1ResolvesFromAudioThenRunsLLM() throws {
        // The rapid case: engage BEFORE step-1 finished transcribing (step1 == nil),
        // then the step-1 dictation finalizes from audio, then the instruction.
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let utterances = try transcribeUtterances(
            fixtureName: "two_utterances.wav",
            transcripts: ["schedule the standup for nine", "abbreviate it"],
            outputDir: outputDir
        )
        XCTAssertEqual(utterances.count, 2)
        let step1 = utterances[0]
        let instruction = utterances[1]

        var flow = RefineFlow()
        // Engage with an as-yet-unknown step-1.
        XCTAssertEqual(flow.handle(.engage(step1: nil, fromSelection: false)),
                       [.startInstructionCapture])
        // Step-1 arrives from audio — no effect, just resolves internally.
        XCTAssertEqual(flow.handle(.step1Finalized(step1)), [])
        // Instruction arrives → now the LLM runs with the resolved step-1.
        XCTAssertEqual(flow.handle(.instructionFinalized(instruction)),
                       [.runLLM(step1: step1, instruction: instruction)])
    }

    func testRefineEmptyPendingStep1FinishesQuietly() throws {
        // Engaged with a pending step-1 that resolves to nothing (silence / empty
        // dictation) — the flow must abandon cleanly rather than wedge.
        var flow = RefineFlow()
        _ = flow.handle(.engage(step1: nil, fromSelection: false))
        let effects = flow.handle(.step1Finalized("   \n  "))
        XCTAssertEqual(effects, [.finishQuietly(status: "Nothing to refine")])
        XCTAssertFalse(flow.isActive)
    }

    func testInstructionChainUserPayloadLabelsAndGating() {
        // The payload the refine flow hands the LLM: INSTRUCTION labeled first, then
        // TEXT, both trimmed and in one message (so tiny models don't answer the
        // TEXT). This is the exact string stubLLM/real LLM receive.
        let payload = InstructionChain.userPayload(
            instruction: "  turn it into a bullet list  ",
            text: "  buy milk buy eggs  "
        )
        XCTAssertTrue(payload.contains("INSTRUCTION: turn it into a bullet list"))
        XCTAssertTrue(payload.contains("TEXT:\nbuy milk buy eggs"))
        // INSTRUCTION precedes TEXT.
        let iRange = try? XCTUnwrap(payload.range(of: "INSTRUCTION:"))
        let tRange = try? XCTUnwrap(payload.range(of: "TEXT:"))
        XCTAssertNotNil(iRange); XCTAssertNotNil(tRange)
        XCTAssertTrue(iRange!.lowerBound < tRange!.lowerBound)

        // Gating: refine needs whole-text output modes AND a configured LLM AND the
        // feature enabled.
        XCTAssertTrue(InstructionChain.isAvailable(outputMode: "preview", llmConfigured: true, enabled: true))
        XCTAssertTrue(InstructionChain.isAvailable(outputMode: "finalOnly", llmConfigured: true, enabled: true))
        XCTAssertFalse(InstructionChain.isAvailable(outputMode: "liveChunks", llmConfigured: true, enabled: true),
                       "type-live has nothing to hold back and refine")
        XCTAssertFalse(InstructionChain.isAvailable(outputMode: "preview", llmConfigured: false, enabled: true),
                       "refine requires an LLM")
        XCTAssertFalse(InstructionChain.isAvailable(outputMode: "preview", llmConfigured: true, enabled: false),
                       "refine must be enabled")
    }


    // MARK: - Output path: transcript reaches the TextOutput

    func testTranscriptIsInsertedIntoTextOutput() throws {
    // Drive a real fixture through the full pipeline and assert the transcript
    // actually reached the TextOutput (the "output path"): insertions non-empty
    // and the joined inserted text contains the scripted words.
    let outputDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDir) }

    let engine = ScriptedFileEngine(byOrdinal: ["hello", "there", "world"])
    let output = SpyTextOutput()
    let driver = try LiveChunkDriver(
        fixture: FileAudioCaptureTests.fixture("plain_speech.wav"),
        engine: engine, output: output,
        outputDir: outputDir, chunkDuration: 0.6
    )
    driver.run()

    // The transcript made it to the sink.
    XCTAssertFalse(output.insertions.isEmpty, "nothing was inserted")
    let joined = output.insertions.map(\.text).joined(separator: " ")
    for word in ["hello", "there", "world"] {
        XCTAssertTrue(joined.contains(word), "missing '\(word)' in inserted text: \(joined)")
    }
    // The driver inserts non-destructively (never stomps the clipboard).
    XCTAssertTrue(output.insertions.allSatisfy { !$0.restoreClipboard })
    XCTAssertTrue(output.clipboardWrites.isEmpty)
    }

    func testSingleChunkTranscriptIsInsertedVerbatim() throws {
    // One big chunk with the .plain cleaner → the exact scripted text is what
    // lands in the TextOutput (proves the output path carries content faithfully).
    let outputDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDir) }

    let engine = ScriptedFileEngine(constant: "the quick brown fox")
    let output = SpyTextOutput()
    let driver = try LiveChunkDriver(
        fixture: FileAudioCaptureTests.fixture("plain_speech.wav"),
        engine: engine, output: output,
        outputDir: outputDir, chunkDuration: 5.0  // one chunk
    )
    driver.run()

    XCTAssertFalse(output.insertions.isEmpty)
    let joined = output.insertions.map(\.text).joined()
    XCTAssertTrue(joined.contains("the quick brown fox"), "got: \(joined)")
    }

    // MARK: - SecureFieldPolicy: blocks ONLY the secure subrole

    func testSecureFieldPolicyBlocksOnlyAXSecureTextField() {
    // The one subrole that gates output: a password field.
    XCTAssertTrue(SecureFieldPolicy.isSecure(subrole: "AXSecureTextField"),
                  "password field must be detected as secure")

    // Everything a normal field could report must fail-open (not secure), so
    // dictation is never suppressed for ordinary text entry.
    let nonSecure: [String?] = [nil, "", "AXTextField", "AXTextArea"]
    for subrole in nonSecure {
        XCTAssertFalse(SecureFieldPolicy.isSecure(subrole: subrole),
                       "unexpectedly treated \(subrole.map { "\"\($0)\"" } ?? "nil") as secure")
    }

    // Same conclusion through the combined role/subrole entry point:
    // a normal field is not secure; a password field is.
    XCTAssertFalse(SecureFieldPolicy.isSecure(role: "AXTextField", subrole: "AXTextField"))
    XCTAssertTrue(SecureFieldPolicy.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
    }

    func testSecureFieldGateSuppressesOutputForPasswordFieldOnly() throws {
    // Show the gate: model AppState's rule — "if the focused field is secure,
    // don't emit" — by running the driver only when the policy allows output.
    // A password field (secure subrole) blocks insertion; a normal field does not.
    func runWithFocusedSubrole(_ focusedSubrole: String?) throws -> SpyTextOutput {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let engine = ScriptedFileEngine(constant: "secret passphrase")
        let output = SpyTextOutput()
        // The gate: consult the real policy on the focused field's subrole.
        let focusedFieldIsSecure = SecureFieldPolicy.isSecure(subrole: focusedSubrole)
        guard !focusedFieldIsSecure else { return output }  // suppressed → never runs

        let driver = try LiveChunkDriver(
            fixture: FileAudioCaptureTests.fixture("plain_speech.wav"),
            engine: engine, output: output,
            outputDir: outputDir, chunkDuration: 5.0
        )
        driver.run()
        return output
    }

    // Password field → policy is secure → output suppressed.
    let intoPassword = try runWithFocusedSubrole("AXSecureTextField")
    XCTAssertTrue(intoPassword.insertions.isEmpty,
                  "transcript leaked into a secure (password) field")

    // Normal field → policy fail-open → output flows.
    let intoNormal = try runWithFocusedSubrole("AXTextField")
    XCTAssertFalse(intoNormal.insertions.isEmpty,
                   "transcript was blocked from a normal (non-secure) field")
    XCTAssertTrue(intoNormal.insertions.map(\.text).joined().contains("secret passphrase"))

    // No focus info (nil subrole) → fail-open, output flows.
    let intoUnknown = try runWithFocusedSubrole(nil)
    XCTAssertFalse(intoUnknown.insertions.isEmpty,
                   "fail-open: unknown field should not block dictation")
    }


    // MARK: - Agent Bridge: dictate routing (the seam a CLI `openwhisp dictate` drives)

    /// Build a well-formed JSON-RPC frame as `Data` from a JSON string, mirroring
    /// what a CLI writes onto the NDJSON control socket.

    func testDictateFrameAfterHandshakeYieldsDictateIntentWithPromptAndTimeout() {
    // A well-formed dictate frame, post-handshake, is routed to a typed
    // .dictate intent carrying the id, prompt, and requested timeout.
    let frame = bridgeFrame(
        #"{"jsonrpc":"2.0","id":"cli-1","method":"dictate","params":{"prompt":"Which branch should I use?","timeoutSeconds":45,"language":"en"}}"#
    )
    let routed = BridgeRouter.route(line: frame, hasHandshaken: true)
    guard case let .intent(.dictate(id, params)) = routed else {
        return XCTFail("expected .intent(.dictate), got \(routed)")
    }
    XCTAssertEqual(id, .string("cli-1"))
    XCTAssertEqual(params.prompt, "Which branch should I use?")
    XCTAssertEqual(params.timeoutSeconds, 45)
    XCTAssertEqual(params.language, "en")
    // The requested timeout is in range, so it flows through unclamped.
    XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(params.timeoutSeconds), 45)
    }

    func testDictateFrameWithNoParamsUsesServerDefaultTimeout() {
    // Absent params → an empty DictateParams; resolvedTimeoutSeconds applies the
    // documented default of 60.
    let frame = bridgeFrame(#"{"jsonrpc":"2.0","id":3,"method":"dictate"}"#)
    let routed = BridgeRouter.route(line: frame, hasHandshaken: true)
    guard case let .intent(.dictate(id, params)) = routed else {
        return XCTFail("expected .intent(.dictate), got \(routed)")
    }
    XCTAssertEqual(id, .number(3))
    XCTAssertNil(params.prompt)
    XCTAssertNil(params.timeoutSeconds)
    XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(params.timeoutSeconds), 60)
    }

    func testDictateTimeoutClampingThroughTheRoutedFrame() {
    // A huge requested timeout clamps to the 300s ceiling; 0 and negatives clamp
    // to the 1s floor — the clamp a CLI can't get around by asking for more.
    let huge = bridgeFrame(#"{"jsonrpc":"2.0","id":1,"method":"dictate","params":{"timeoutSeconds":100000}}"#)
    guard case let .intent(.dictate(_, hugeParams)) = BridgeRouter.route(line: huge, hasHandshaken: true) else {
        return XCTFail("expected dictate intent for huge timeout")
    }
    XCTAssertEqual(hugeParams.timeoutSeconds, 100000)
    XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(hugeParams.timeoutSeconds), 300)

    let zero = bridgeFrame(#"{"jsonrpc":"2.0","id":2,"method":"dictate","params":{"timeoutSeconds":0}}"#)
    guard case let .intent(.dictate(_, zeroParams)) = BridgeRouter.route(line: zero, hasHandshaken: true) else {
        return XCTFail("expected dictate intent for zero timeout")
    }
    XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(zeroParams.timeoutSeconds), 1)

    let negative = bridgeFrame(#"{"jsonrpc":"2.0","id":3,"method":"dictate","params":{"timeoutSeconds":-30}}"#)
    guard case let .intent(.dictate(_, negParams)) = BridgeRouter.route(line: negative, hasHandshaken: true) else {
        return XCTFail("expected dictate intent for negative timeout")
    }
    XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(negParams.timeoutSeconds), 1)

    // And directly at the boundaries, so the clamp is pinned exactly.
    XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(nil), 60)
    XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(1), 1)
    XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(300), 300)
    XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(301), 300)
    }

    func testDictateBeforeHandshakeClosesTheConnection() {
    // The very first frame on a fresh connection MUST be bridge.hello. A dictate
    // sent before the handshake is a protocol violation → close (no error oracle).
    let frame = bridgeFrame(#"{"jsonrpc":"2.0","id":1,"method":"dictate","params":{"prompt":"hi"}}"#)
    let routed = BridgeRouter.route(line: frame, hasHandshaken: false)
    guard case let .close(reason) = routed else {
        return XCTFail("expected .close, got \(routed)")
    }
    XCTAssertTrue(reason.contains("bridge.hello"))
    }

    func testFirstNonHelloFrameClosesEvenIfKnownMethod() {
    // status is a valid post-handshake method, but as the first frame it still
    // violates handshake ordering → close.
    let frame = bridgeFrame(#"{"jsonrpc":"2.0","id":"s","method":"status"}"#)
    guard case .close = BridgeRouter.route(line: frame, hasHandshaken: false) else {
        return XCTFail("expected close for pre-handshake status")
    }
    }

    func testUnknownMethodAfterHandshakeYieldsError() {
    // A well-formed frame naming a method the router doesn't know, post-handshake,
    // is a recoverable call → .error (connection stays open), not a close.
    let frame = bridgeFrame(#"{"jsonrpc":"2.0","id":9,"method":"dictate.teleport"}"#)
    let routed = BridgeRouter.route(line: frame, hasHandshaken: true)
    guard case let .error(id, err) = routed else {
        return XCTFail("expected .error, got \(routed)")
    }
    XCTAssertEqual(id, .number(9))
    XCTAssertEqual(err.code, BridgeWire.ErrorObject.methodNotFound)
    XCTAssertEqual(err.data?.reason, .unknownMethod)
    }

    func testDictateStopAndCancelRouteWithoutParams() {
    // The CLI's stop/cancel verbs carry no params and route to their own intents.
    guard case .intent(.dictateStop) = BridgeRouter.route(
        line: bridgeFrame(#"{"jsonrpc":"2.0","id":1,"method":"dictate.stop"}"#), hasHandshaken: true
    ) else { return XCTFail("expected .dictateStop") }

    guard case .intent(.dictateCancel) = BridgeRouter.route(
        line: bridgeFrame(#"{"jsonrpc":"2.0","id":2,"method":"dictate.cancel"}"#), hasHandshaken: true
    ) else { return XCTFail("expected .dictateCancel") }
    }

    // MARK: - Agent Bridge: per-client dictate rate limiting

    /// Convert an injected `now` (as a TimeInterval offset) into the `Date` the real
    /// limiter API takes, so the tests read as "at t=N seconds".

    func testRateLimiterCooldownThrottlesBackToBackDictateStarts() {
    // A CLI that fires a second dictate inside the cooldown is throttled, and the
    // retryAfter is exactly the remaining cooldown — what the CLI would surface as
    // "try again in Ns".
    var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 0, maxListeningSecondsPerHour: 0)
    XCTAssertEqual(limiter.check(clientName: "claude-code", now: at(0)), .allow)
    limiter.recordStart(clientName: "claude-code", now: at(0))

    guard case let .throttled(retryAfter) = limiter.check(clientName: "claude-code", now: at(4)) else {
        return XCTFail("expected .throttled inside cooldown")
    }
    XCTAssertEqual(retryAfter, 6, accuracy: 0.001) // 10 - 4

    // Past the cooldown, the next start is allowed again.
    XCTAssertEqual(limiter.check(clientName: "claude-code", now: at(10)), .allow)
    }

    func testRateLimiterSessionsPerHourCapThrottlesAfterQuota() {
    // After maxSessionsPerHour accepted starts in the window, the next start is
    // throttled until the oldest start ages out of the window.
    var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 3, maxListeningSecondsPerHour: 0, windowSeconds: 3600)
    limiter.recordStart(clientName: "cli", now: at(0))
    limiter.recordStart(clientName: "cli", now: at(60))
    limiter.recordStart(clientName: "cli", now: at(120))
    XCTAssertEqual(limiter.sessionCount(clientName: "cli", now: at(200)), 3)

    guard case let .throttled(retryAfter) = limiter.check(clientName: "cli", now: at(200)) else {
        return XCTFail("expected .throttled after quota")
    }
    XCTAssertEqual(retryAfter, 3400, accuracy: 0.001) // oldest (t=0) ages out at t=3600

    // Once the oldest start has aged past the window, a slot frees and it's allowed.
    XCTAssertEqual(limiter.check(clientName: "cli", now: at(3601)), .allow)
    }

    func testRateLimiterRecordStartEndAndSessionCountAcrossWindow() {
    // recordStart bumps the count; recordEnd charges duration (verified via the
    // listening budget); the window prunes stale starts out of sessionCount.
    var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 10, maxListeningSecondsPerHour: 0, windowSeconds: 3600)
    XCTAssertEqual(limiter.sessionCount(clientName: "cli", now: at(0)), 0)

    limiter.recordStart(clientName: "cli", now: at(0))
    limiter.recordEnd(clientName: "cli", now: at(30))          // a 30s session
    limiter.recordStart(clientName: "cli", now: at(1800))
    XCTAssertEqual(limiter.sessionCount(clientName: "cli", now: at(1800)), 2)

    // Past the window, the first (t=0) start no longer counts.
    XCTAssertEqual(limiter.sessionCount(clientName: "cli", now: at(3700)), 1)
    }

    func testRateLimiterListeningBudgetThrottlesContinuousDictation() {
    // The listening-time budget is the throttle that bounds continuous listening:
    // two max-length (300s) sessions exhaust a 600s/hour budget, so the next start
    // is throttled until a session ages out and frees mic time.
    var limiter = AgentRateLimiter(
        cooldownSeconds: 0, maxSessionsPerHour: 0,
        maxListeningSecondsPerHour: 600, windowSeconds: 3600
    )
    limiter.recordStart(clientName: "cli", now: at(0))
    limiter.recordEnd(clientName: "cli", now: at(300))
    limiter.recordStart(clientName: "cli", now: at(400))
    limiter.recordEnd(clientName: "cli", now: at(700))

    guard case let .throttled(retryAfter) = limiter.check(clientName: "cli", now: at(800)) else {
        return XCTFail("expected .throttled when listening budget exhausted")
    }
    XCTAssertEqual(retryAfter, 2800, accuracy: 0.001) // first session ages out at t=3600
    // After the first session ages out, budget is back below the cap.
    XCTAssertEqual(limiter.check(clientName: "cli", now: at(3601)), .allow)
    }

    func testRateLimiterForgetClearsBudgetAndIsPerClient() {
    // forget wipes a client's history (used on consent revocation) so a re-approved
    // client starts clean; and one client's throttle never affects another.
    var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 1, maxListeningSecondsPerHour: 0)
    limiter.recordStart(clientName: "cli-a", now: at(0))

    // cli-a is throttled by both cooldown and the 1-session cap.
    guard case .throttled = limiter.check(clientName: "cli-a", now: at(1)) else {
        return XCTFail("expected cli-a throttled")
    }
    // A different client is unaffected.
    XCTAssertEqual(limiter.check(clientName: "cli-b", now: at(1)), .allow)

    // Forgetting cli-a resets it to a clean budget.
    limiter.forget(clientName: "cli-a")
    XCTAssertEqual(limiter.sessionCount(clientName: "cli-a", now: at(1)), 0)
    XCTAssertEqual(limiter.check(clientName: "cli-a", now: at(1)), .allow)
    }

    func testRateLimiterRecordEndWithoutStartIsNoOp() {
    // A stray recordEnd (e.g. after forget) must neither crash nor fabricate a
    // session.
    var limiter = AgentRateLimiter(cooldownSeconds: 5, maxSessionsPerHour: 30)
    limiter.recordEnd(clientName: "cli", now: at(0))
    XCTAssertEqual(limiter.sessionCount(clientName: "cli", now: at(0)), 0)
    XCTAssertEqual(limiter.check(clientName: "cli", now: at(0)), .allow)
    }


    // MARK: - Script post-processor feature (integration through pipeline + pure resolve)

    /// A tiny helper that runs a real shell script via Foundation `Process` over a
    /// given input string and returns (stdout, exitCode, launchFailed) exactly the
    /// way the app's ScriptRunner glue feeds ScriptPostProcessor. Kept local to the
    /// script tests — not one of the shared E2E helpers.

    /// Full feature path: fixture audio → real pipeline transcript → a real
    /// `tr a-z A-Z` shell script over Process → ScriptPostProcessor resolves to the
    /// uppercased text. Proves the post-processor composes on top of a live transcript.
    func testScriptPostProcessorUppercasesLiveTranscript() throws {
    let engine = ScriptedFileEngine(constant: "process this transcript please")
    let output = SpyTextOutput()
    let driver = try LiveChunkDriver(
        fixture: fixture("plain_speech.wav"), engine: engine, output: output,
        outputDir: tempDir, chunkDuration: 5.0  // one chunk
    )
    driver.run()

    // The transcript the pipeline actually produced (verbatim under .plain).
    let transcript = output.insertions.map(\.text).joined()
    XCTAssertFalse(transcript.isEmpty, "pipeline produced no transcript")
    XCTAssertTrue(transcript.contains("process this transcript"), "got: \(transcript)")

    // Run the user's real script over it.
    let result = runScriptFeature(
        script: "tr 'a-z' 'A-Z'", input: transcript, outputDir: tempDir)
    XCTAssertFalse(result.launchFailed)
    XCTAssertEqual(result.exitCode, 0)

    // The post-processor decision uses the uppercased script output.
    let final = ScriptOutcome.resolvedText(
        original: transcript, stdout: result.stdout,
        exitCode: result.exitCode, timedOut: false, launchFailed: result.launchFailed)
    XCTAssertEqual(final, transcript.uppercased(),
                   "script output should replace the transcript: \(final)")
    XCTAssertTrue(final.contains("PROCESS THIS TRANSCRIPT"), "got: \(final)")
    // And it's actually a transformation, not a pass-through.
    XCTAssertNotEqual(final, transcript)
    }

    /// A `sed` script that rewrites a word: proves arbitrary transforms flow through
    /// and the resolver strips only the single conventional trailing newline `sed`
    /// emits (so we get exactly the rewritten line, no dangling blank).
    func testScriptPostProcessorRewritesWordInLiveTranscript() throws {
    let engine = ScriptedFileEngine(constant: "ship the widget today")
    let output = SpyTextOutput()
    let driver = try LiveChunkDriver(
        fixture: fixture("plain_speech.wav"), engine: engine, output: output,
        outputDir: tempDir, chunkDuration: 5.0
    )
    driver.run()
    let transcript = output.insertions.map(\.text).joined()
    XCTAssertTrue(transcript.contains("widget"), "got: \(transcript)")

    let result = runScriptFeature(
        script: "sed 's/widget/gadget/'", input: transcript, outputDir: tempDir)
    XCTAssertEqual(result.exitCode, 0)

    let final = ScriptOutcome.resolvedText(
        original: transcript, stdout: result.stdout,
        exitCode: result.exitCode, timedOut: false, launchFailed: result.launchFailed)
    XCTAssertTrue(final.contains("gadget"), "rewrite not applied: \(final)")
    XCTAssertFalse(final.contains("widget"), "original word survived: \(final)")
    // Single trailing newline from sed is stripped — no dangling blank line.
    XCTAssertFalse(final.hasSuffix("\n"), "trailing newline not stripped: \(String(reflecting: final))")
    }

    /// A real script that exits non-zero: fail-open contract keeps the original
    /// transcript, ignoring whatever the script wrote to stdout.
    func testScriptNonZeroExitKeepsLiveTranscript() throws {
    let engine = ScriptedFileEngine(constant: "keep me verbatim")
    let output = SpyTextOutput()
    let driver = try LiveChunkDriver(
        fixture: fixture("plain_speech.wav"), engine: engine, output: output,
        outputDir: tempDir, chunkDuration: 5.0
    )
    driver.run()
    let transcript = output.insertions.map(\.text).joined()
    XCTAssertTrue(transcript.contains("keep me verbatim"), "got: \(transcript)")

    // Script emits garbage on stdout but exits 7.
    let result = runScriptFeature(
        script: "echo CORRUPTED; exit 7", input: transcript, outputDir: tempDir)
    XCTAssertFalse(result.launchFailed)
    XCTAssertEqual(result.exitCode, 7)

    let outcome = ScriptOutcome.resolve(
        original: transcript, stdout: result.stdout,
        exitCode: result.exitCode, timedOut: false, launchFailed: result.launchFailed)
    XCTAssertEqual(outcome, .keepOriginal(reason: "Script exited with code 7"))

    let final = ScriptOutcome.resolvedText(
        original: transcript, stdout: result.stdout,
        exitCode: result.exitCode, timedOut: false, launchFailed: result.launchFailed)
    XCTAssertEqual(final, transcript, "non-zero exit must keep the original transcript")
    XCTAssertFalse(final.contains("CORRUPTED"))
    }

    /// A real script that produces only whitespace on stdout with a clean exit:
    /// resolver treats empty/whitespace output as fail-open and keeps the transcript.
    func testScriptEmptyOutputKeepsLiveTranscript() throws {
    let engine = ScriptedFileEngine(constant: "do not lose this")
    let output = SpyTextOutput()
    let driver = try LiveChunkDriver(
        fixture: fixture("plain_speech.wav"), engine: engine, output: output,
        outputDir: tempDir, chunkDuration: 5.0
    )
    driver.run()
    let transcript = output.insertions.map(\.text).joined()
    XCTAssertTrue(transcript.contains("do not lose this"), "got: \(transcript)")

    // Clean exit but emits only whitespace — must not clobber the transcript.
    let result = runScriptFeature(
        script: "printf '   \\n  '", input: transcript, outputDir: tempDir)
    XCTAssertEqual(result.exitCode, 0)

    let outcome = ScriptOutcome.resolve(
        original: transcript, stdout: result.stdout,
        exitCode: result.exitCode, timedOut: false, launchFailed: result.launchFailed)
    XCTAssertEqual(outcome, .keepOriginal(reason: "Script returned empty output"))
    let final = ScriptOutcome.resolvedText(
        original: transcript, stdout: result.stdout,
        exitCode: result.exitCode, timedOut: false, launchFailed: result.launchFailed)
    XCTAssertEqual(final, transcript)
    }

    /// A script path that does not exist → Process.run() throws → launchFailed.
    /// The resolver keeps the original transcript.
    func testScriptLaunchFailureKeepsLiveTranscript() throws {
    let engine = ScriptedFileEngine(constant: "survive a missing script")
    let output = SpyTextOutput()
    let driver = try LiveChunkDriver(
        fixture: fixture("plain_speech.wav"), engine: engine, output: output,
        outputDir: tempDir, chunkDuration: 5.0
    )
    driver.run()
    let transcript = output.insertions.map(\.text).joined()
    XCTAssertTrue(transcript.contains("survive a missing script"), "got: \(transcript)")

    // Point Process at a binary that isn't there → launch fails.
    let proc = Process()
    proc.executableURL = tempDir.appendingPathComponent("nope-\(UUID().uuidString)")
    proc.arguments = []
    var launchFailed = false
    do { try proc.run(); proc.waitUntilExit() } catch { launchFailed = true }
    XCTAssertTrue(launchFailed, "expected Process.run to throw for a missing executable")

    let outcome = ScriptOutcome.resolve(
        original: transcript, stdout: nil, exitCode: nil,
        timedOut: false, launchFailed: launchFailed)
    XCTAssertEqual(outcome, .keepOriginal(reason: "Script couldn't run"))
    let final = ScriptOutcome.resolvedText(
        original: transcript, stdout: nil, exitCode: nil,
        timedOut: false, launchFailed: launchFailed)
    XCTAssertEqual(final, transcript)
    }

    /// Timeout branch: a real long-running script the glue would kill. We simulate
    /// the kill by terminating the process and passing timedOut:true (exitCode nil),
    /// exactly as ScriptRunner's timeout path reports it. Resolver keeps the original.
    func testScriptTimeoutKeepsLiveTranscript() throws {
    let engine = ScriptedFileEngine(constant: "outlast the slow script")
    let output = SpyTextOutput()
    let driver = try LiveChunkDriver(
        fixture: fixture("plain_speech.wav"), engine: engine, output: output,
        outputDir: tempDir, chunkDuration: 5.0
    )
    driver.run()
    let transcript = output.insertions.map(\.text).joined()
    XCTAssertTrue(transcript.contains("outlast the slow script"), "got: \(transcript)")

    // Launch a script that would sleep well past any budget, then kill it —
    // this is what the app's timeout enforcement does before reporting timedOut.
    let scriptURL = tempDir.appendingPathComponent("slow-\(UUID().uuidString).sh")
    try "sleep 30\n".write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: scriptURL.path)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = [scriptURL.path]
    proc.standardOutput = Pipe()
    try proc.run()
    XCTAssertTrue(proc.isRunning, "slow script should still be running")
    proc.terminate()               // the timeout enforcer kills it
    proc.waitUntilExit()

    // Glue reports timedOut with no usable exit code.
    let outcome = ScriptOutcome.resolve(
        original: transcript, stdout: nil, exitCode: nil,
        timedOut: true, launchFailed: false)
    XCTAssertEqual(outcome, .keepOriginal(reason: "Script timed out"))
    let final = ScriptOutcome.resolvedText(
        original: transcript, stdout: nil, exitCode: nil,
        timedOut: true, launchFailed: false)
    XCTAssertEqual(final, transcript)
    }

    /// Pure-resolver matrix, independent of the pipeline: pins every branch of the
    /// fail-open contract and the single-trailing-newline trimming, in one place.
    func testScriptPostProcessorResolveOutcomeMatrix() {
    let original = "the transcript"

    // Success: stdout used, one trailing newline stripped.
    XCTAssertEqual(
        ScriptOutcome.resolve(original: original, stdout: "TRANSFORMED\n",
                              exitCode: 0, timedOut: false, launchFailed: false),
        .useOutput("TRANSFORMED"))
    // Internal newline preserved; only the last one trimmed.
    XCTAssertEqual(
        ScriptOutcome.resolvedText(original: original, stdout: "a\nb\n",
                                   exitCode: 0, timedOut: false, launchFailed: false),
        "a\nb")
    // Two trailing newlines → only one stripped.
    XCTAssertEqual(
        ScriptOutcome.resolvedText(original: original, stdout: "x\n\n",
                                   exitCode: 0, timedOut: false, launchFailed: false),
        "x\n")

    // Fail-open branches all collapse to the original text.
    for (stdout, exit, timedOut, launchFailed, reason): (String?, Int32?, Bool, Bool, String) in [
        (nil, nil, false, true,  "Script couldn't run"),
        ("partial", nil, true,  false, "Script timed out"),
        ("x", nil, false, false, "Script didn't finish"),
        ("junk", 3, false, false, "Script exited with code 3"),
        ("", 0, false, false, "Script returned empty output"),
        ("   \n  ", 0, false, false, "Script returned empty output"),
        (nil, 0, false, false, "Script returned empty output"),
    ] {
        XCTAssertEqual(
            ScriptOutcome.resolve(original: original, stdout: stdout, exitCode: exit,
                                  timedOut: timedOut, launchFailed: launchFailed),
            .keepOriginal(reason: reason),
            "reason mismatch for exit=\(String(describing: exit)) timedOut=\(timedOut) launchFailed=\(launchFailed)")
        XCTAssertEqual(
            ScriptOutcome.resolvedText(original: original, stdout: stdout, exitCode: exit,
                                       timedOut: timedOut, launchFailed: launchFailed),
            original,
            "resolvedText should fall back to original for reason: \(reason)")
    }
    }

}
