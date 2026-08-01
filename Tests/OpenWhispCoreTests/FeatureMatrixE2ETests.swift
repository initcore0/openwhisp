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

    /// Translation moved to the Apple Translation TEXT path for EVERY engine, so
    /// the whisper family's native translate task is retired (dormant): even
    /// with translateToEnglish ON, whisperKit is handed the plain spoken
    /// language and the sentinel is never emitted. (This test previously
    /// asserted the opposite — the sentinel WAS the whisper contract.)
    func testEngineLanguageIsPlainLanguageEvenWhenTranslatingOnWhisper() {
        let setting = LanguageResolver.engineLanguageSetting(
            language: "de", translateToEnglish: true, transcriptionEngine: "whisperKit")
        XCTAssertEqual(setting, "de")
        XCTAssertNotEqual(setting, WhisperTask.translateToEnglishSetting,
                          "engine-native translate is retired — the text path owns translation")
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

    /// The whole cross product in one table. The rule is now uniform: the engine
    /// ALWAYS gets the plain spoken language, whatever the translate flag —
    /// translation happens on the text afterwards. A cell regressing to the
    /// retired sentinel fails loudly.
    func testEngineLanguageMatrixAcrossEnginesAndTranslateFlag() {
        let cases: [(engine: String, translate: Bool, language: String, expected: String)] = [
            ("whisperKit", true,  "de",   "de"),      // text path owns translate
            ("whisperKit", false, "de",   "de"),
            ("whisperKit", true,  "auto", "auto"),    // text path owns translate
            ("appleSpeech", true,  "de",   "de"),
            ("appleSpeech", false, "de",   "de"),
            ("appleSpeech", true,  "auto", "auto"),
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

    /// End-to-end: the two derivations describe the SPLIT the text path creates.
    /// Translating on a whisper engine, the engine is told the spoken language
    /// "ja" (it just transcribes) while the cleaner is told "en", because by the
    /// time formatting runs the text HAS been translated. The cleaning language
    /// must come from `TextTranslationPolicy` — the engine-capability-based
    /// `LanguageResolver.outputLanguageForCleaning` is not the session rule.
    func testResolverDerivationsAgreeWhenTranslating() {
        let engineSetting = LanguageResolver.engineLanguageSetting(
            language: "ja", translateToEnglish: true, transcriptionEngine: "whisperKit")
        let cleanLang = TextTranslationPolicy.outputLanguageForCleaning(
            language: "ja", translateToEnglish: true, transcriptionEngine: "whisperKit",
            textTranslationAvailable: true)
        XCTAssertEqual(engineSetting, "ja", "the engine transcribes in the spoken language")
        XCTAssertEqual(cleanLang, "en", "the cleaner sees already-translated English text")
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
    /// the engine still transcribes "de" (the TEXT path translates afterwards) and
    /// the cleaner formats as English; German → engine sees "de" and the cleaner
    /// skips English caps. One assertion chain covers the whole multilingual seam
    /// on a single fixture.
    func testTranslateVsGermanProfileConsistentEngineToOutput() throws {
        let transcript = "i wrote it down"

        // Translate profile.
        let tEngine = LanguageResolver.engineLanguageSetting(
            language: "de", translateToEnglish: true, transcriptionEngine: "whisperKit")
        let tClean = TextTranslationPolicy.outputLanguageForCleaning(
            language: "de", translateToEnglish: true, transcriptionEngine: "whisperKit",
            textTranslationAvailable: true)
        XCTAssertEqual(tEngine, "de", "the engine transcribes in the spoken language")
        var tCfg = TranscriptCleaner.Config.plain
        tCfg.language = tClean; tCfg.smartFormattingEnabled = true
        let tText = try driveCleaned(fixture: "plain_speech.wav", transcript: transcript, config: tCfg)

        // Plain German profile.
        let gEngine = LanguageResolver.engineLanguageSetting(
            language: "de", translateToEnglish: false, transcriptionEngine: "whisperKit")
        let gClean = TextTranslationPolicy.outputLanguageForCleaning(
            language: "de", translateToEnglish: false, transcriptionEngine: "whisperKit",
            textTranslationAvailable: true)
        XCTAssertEqual(gEngine, "de")
        var gCfg = TranscriptCleaner.Config.plain
        gCfg.language = gClean; gCfg.smartFormattingEnabled = true
        let gText = try driveCleaned(fixture: "plain_speech.wav", transcript: transcript, config: gCfg)

        XCTAssertTrue(tText.hasPrefix("I"), "translate output should be English-capitalized: \(tText)")
        XCTAssertTrue(gText.hasPrefix("i"), "german output should be left as-is: \(gText)")
        XCTAssertNotEqual(tText, gText)
    }

    // MARK: - (3) File-tagging (MAK-48) gated by config, end-to-end

    /// Drive ONE fixture + ONE scripted transcript through the real cleaner twice,
    /// under two configs that differ ONLY in `fileTaggingEnabled`. With it ON, the
    /// spoken filename "open main dot t s" becomes an editor @-mention; with it OFF
    /// (the default — the state in every non-editor app), the identical text is
    /// left byte-for-byte alone. This is the end-to-end proof that the per-app
    /// gate in AppState (which sets `fileTaggingEnabled` only for Cursor/Windsurf)
    /// actually changes what lands in the editor.
    func testFileTaggingConfigChangesOutputForSameFixture() throws {
        let transcript = "open main dot t s and fix it"

        // OFF (default): the transform never runs — text unchanged. This is the
        // non-editor / toggle-off case, i.e. ordinary dictation everywhere else.
        let offCfg = TranscriptCleaner.Config.plain
        XCTAssertFalse(offCfg.fileTaggingEnabled, "fileTagging must default OFF")
        let offText = try driveCleaned(
            fixture: "plain_speech.wav", transcript: transcript, config: offCfg)

        // ON: mirrors what AppState builds when Cursor/Windsurf is frontmost.
        var onCfg = TranscriptCleaner.Config.plain
        onCfg.fileTaggingEnabled = true
        let onText = try driveCleaned(
            fixture: "plain_speech.wav", transcript: transcript, config: onCfg)

        // Same fixture, same words → different output only because of the config.
        XCTAssertNotEqual(offText, onText, "fileTagging config produced identical output")
        // ON rewrote the spoken filename to an @-mention.
        XCTAssertTrue(onText.contains("@main.ts"),
                      "spoken filename not converted when enabled: \(onText)")
        XCTAssertFalse(onText.lowercased().contains("main dot t s"),
                       "spoken form should be gone when enabled: \(onText)")
        // OFF left the spoken form exactly as dictated — no @-mention synthesized.
        XCTAssertFalse(offText.contains("@main.ts"),
                       "no @-mention should appear when disabled: \(offText)")
        XCTAssertTrue(offText.lowercased().contains("main dot t s"),
                      "spoken form should survive verbatim when disabled: \(offText)")
    }

    /// File-tagging composed WITH smart formatting: it runs after formatting, so a
    /// sentence-start capital and the @-mention coexist ("Open @main.ts …") and the
    /// mention itself isn't re-capitalized. Same fixture, formatting on both sides,
    /// tagging the only difference.
    func testFileTaggingComposesWithSmartFormatting() throws {
        let transcript = "open main dot t s and fix it"

        var onCfg = TranscriptCleaner.Config.plain
        onCfg.smartFormattingEnabled = true
        onCfg.fileTaggingEnabled = true
        let text = try driveCleaned(
            fixture: "plain_speech.wav", transcript: transcript, config: onCfg)

        XCTAssertTrue(text.contains("@main.ts"),
                      "mention not produced with formatting on: \(text)")
        // Smart formatting still capitalized the sentence start.
        XCTAssertTrue(text.hasPrefix("Open"), "sentence not capitalized: \(text)")
        // The mention was NOT re-capitalized to "@Main.ts".
        XCTAssertFalse(text.contains("@Main.ts"), "mention over-capitalized: \(text)")
    }

    // MARK: - (4) MAK-20 structural formatting, wired end-to-end
    //
    // The Settings toggles set AppState flags that flow into TranscriptCleaner.Config
    // (normalizeNumbers / normalizeCurrency / spokenListsEnabled / basicMarkdownEnabled)
    // and on into SmartFormatter.Options. These drive fixture audio through the real
    // pipeline with each group ON, proving the wiring actually produces the transform —
    // and that with the groups OFF (the default) the same spoken text passes through.

    /// A config with smart formatting on and all four structural groups enabled —
    /// the state the Settings toggles put the app in.
    private func structuralConfig() -> TranscriptCleaner.Config {
        var cfg = TranscriptCleaner.Config.plain
        cfg.smartFormattingEnabled = true
        cfg.normalizeNumbers = true
        cfg.normalizeCurrency = true
        cfg.spokenListsEnabled = true
        cfg.basicMarkdownEnabled = true
        return cfg
    }

    func testStructuralFormattingNumbersWiredThroughPipeline() throws {
        let out = try driveCleaned(
            fixture: "plain_speech.wav",
            transcript: "the year is twenty twenty six",
            config: structuralConfig())
        XCTAssertTrue(out.contains("2026"), "year-pair not normalized: \(out)")
    }

    func testStructuralFormattingCurrencyWiredThroughPipeline() throws {
        let out = try driveCleaned(
            fixture: "plain_speech.wav",
            transcript: "it costs five dollars",
            config: structuralConfig())
        XCTAssertTrue(out.contains("$5"), "currency not normalized: \(out)")
    }

    func testStructuralFormattingSpokenListWiredThroughPipeline() throws {
        let out = try driveCleaned(
            fixture: "plain_speech.wav",
            transcript: "bullet buy milk",
            config: structuralConfig())
        // The list marker is applied; sentence-capitalization then uppercases the
        // first item word ("- Buy milk"), which is expected downstream behavior.
        XCTAssertTrue(out.hasPrefix("- "), "spoken list marker not applied: \(out)")
        XCTAssertTrue(out.lowercased().contains("- buy milk"), "list body wrong: \(out)")
    }

    func testStructuralFormattingMarkdownWiredThroughPipeline() throws {
        let out = try driveCleaned(
            fixture: "plain_speech.wav",
            transcript: "bold ship it",
            config: structuralConfig())
        // The ** wrap is applied; capitalization then uppercases the wrapped word
        // ("**Ship it**"), which is expected.
        XCTAssertTrue(out.hasPrefix("**") && out.contains("**"), "bold wrap not applied: \(out)")
        XCTAssertTrue(out.lowercased().contains("**ship it**"), "bold body wrong: \(out)")
    }

    func testStructuralFormattingOffByDefaultLeavesSpokenFormsAlone() throws {
        // The default (.plain, groups off) — the same spoken text is NOT transformed,
        // so the toggles are genuinely opt-in and don't touch prose when off.
        var cfg = TranscriptCleaner.Config.plain
        cfg.smartFormattingEnabled = true   // formatting on, but the structural groups OFF
        let out = try driveCleaned(
            fixture: "plain_speech.wav",
            transcript: "it costs five dollars and the year is twenty twenty six",
            config: cfg)
        XCTAssertFalse(out.contains("$5"), "currency should be untouched when off: \(out)")
        XCTAssertFalse(out.contains("2026"), "numbers should be untouched when off: \(out)")
    }

    // MARK: - (MAK-77) Per-app refine presets, driven from fixture audio

    /// Same fixture, same transcript, two per-app profiles: a CASUAL preset
    /// session must construct a DIFFERENT refine input than a VERBATIM one.
    /// With the stub pipeline we assert on the CONSTRUCTED prompt (the exact
    /// composition AppState feeds the refiner via RefineInstructionComposer),
    /// not on LLM output: casual yields the casual system prompt over the real
    /// transcribed text; verbatim never runs the LLM at all.
    func testCasualVsVerbatimPresetChangesConstructedRefineInputForSameFixture() throws {
        let transcript = "um hey can you send me the report when you get a chance"
        let text = try driveCleaned(
            fixture: "plain_speech.wav", transcript: transcript,
            config: .plain)
        XCTAssertFalse(text.isEmpty, "fixture must yield a transcript")

        let globalIntensity = CleanupIntensity.medium
        let dialPrompt = CleanupIntensity.wholeTextCustomInstruction(
            intensity: globalIntensity, mode: "rephrase", translateToEnglish: false)

        func sessionRefineInput(preset: RefinePreset) -> (runsLLM: Bool, instruction: String?) {
            // Exactly AppState.applyProfileForFrontmostApp's decision for a
            // profile-only session (no Mode): resolve the preset outcome, then
            // compose the base instruction through the shared funnel.
            let profile = AppProfile(
                appBundleID: "com.tinyspeck.slackmacgap", displayName: "Slack",
                refinePreset: preset.rawValue)
            let outcome = RefinePresetResolver.resolve(
                profile: profile, frontmostBundleID: profile.appBundleID,
                perAppProfilesEnabled: true, globalIntensity: globalIntensity)
            switch outcome {
            case .verbatim:
                return (false, nil)
            case .prompt(let p):
                return (true, RefineInstructionComposer.baseInstruction(
                    modeOverride: nil, presetOverride: p, dialInstruction: dialPrompt))
            case .inherit:
                return (true, RefineInstructionComposer.baseInstruction(
                    modeOverride: nil, presetOverride: nil, dialInstruction: dialPrompt))
            }
        }

        let casual = sessionRefineInput(preset: .casual)
        let verbatim = sessionRefineInput(preset: .verbatim)

        // Verbatim: the LLM must not run at all — the transcript IS the output.
        XCTAssertFalse(verbatim.runsLLM)
        XCTAssertNil(verbatim.instruction)

        // Casual: the LLM runs with the casual preset prompt over the SAME text.
        XCTAssertTrue(casual.runsLLM)
        let casualInstruction = try XCTUnwrap(casual.instruction)
        XCTAssertTrue(casualInstruction.contains("conversational"),
                      "casual session must carry the casual tone prompt")
        XCTAssertNotEqual(casualInstruction, dialPrompt,
                          "preset must override the global dial prompt")
        // The two sessions' constructed refine inputs differ.
        XCTAssertNotEqual(casual.instruction, verbatim.instruction)
        // And the preset prompt stays conservative — same-language contract intact.
        XCTAssertTrue(casualInstruction.contains("SAME language"))
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


    // MARK: - (N) Rules engine (MAK-43), driven from fixture audio

    /// The post-completion rules engine keys on REAL transcribed output: drive a
    /// fixture through the pipeline, then run the pure `RulePlanner` over the cleaned
    /// transcript exactly as `AppState.fireRules` does at the llm-complete hook. A
    /// prefix-matching rule fires its actions; the transcript reaches the action plan.
    func testRulesEngineFiresOnTranscribedOutput() throws {
        let transcript = try driveCleaned(
            fixture: "plain_speech.wav",
            transcript: "todo buy milk and eggs",
            config: .plain
        )
        XCTAssertFalse(transcript.isEmpty, "fixture should transcribe to non-empty text")

        let rule = Rule(
            name: "archive todos",
            hook: .llmComplete,
            match: RuleTextMatch(kind: .prefix, pattern: "todo"),
            sessionMode: .dictation,
            actions: [.appendFile(config: FileOutputConfig(path: "~/todos.md")), .openURL(template: "x://{{text}}")]
        )
        let ctx = RuleContext(hook: .llmComplete, text: transcript,
                              appBundleID: "com.apple.Notes", isAgentSession: false)
        let plan = RulePlanner.plan(rules: RuleSet(rules: [rule]), context: ctx)
        XCTAssertEqual(plan.count, 2, "both actions of the matching rule should be planned")
        XCTAssertEqual(plan.first?.ruleName, "archive todos")
    }

    /// Fail-open invariant: an empty rule set plans nothing over a real transcript, so
    /// the engine is a pure no-op on the normal insert path.
    func testRulesEngineEmptySetIsNoOpOnRealTranscript() throws {
        let transcript = try driveCleaned(
            fixture: "plain_speech.wav", transcript: "just some words", config: .plain
        )
        let ctx = RuleContext(hook: .llmComplete, text: transcript, appBundleID: nil, isAgentSession: false)
        XCTAssertTrue(RulePlanner.plan(rules: .empty, context: ctx).isEmpty)
    }

    /// A dictation-only rule must NOT fire on an agent-bridge session even when its
    /// text/app match — the agent gate is the security boundary.
    func testRulesEngineAgentGateOverRealTranscript() throws {
        let transcript = try driveCleaned(
            fixture: "plain_speech.wav", transcript: "send this everywhere", config: .plain
        )
        let leaky = Rule(name: "leak", hook: .llmComplete, match: .always,
                         sessionMode: .dictation,
                         actions: [.postWebhook(config: WebhookConfig(url: "https://evil.test/hook"))])
        let ctx = RuleContext(hook: .llmComplete, text: transcript, appBundleID: nil, isAgentSession: true)
        XCTAssertTrue(RulePlanner.plan(rules: RuleSet(rules: [leaky]), context: ctx).isEmpty,
                      "dictation-only rule must not fire on an agent session")
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

    // MARK: - Agent Bridge: agent-context vocabulary (MAK-75)

    /// Reproduces AppState's streaming-prompt assembly for the routed context so
    /// the test keys on the SAME public API the app calls (the wiring-review
    /// lesson): derive terms from the wire context, merge with user vocab, then
    /// gate on the engine's streaming vocabulary capability exactly as
    /// AppState.swift does at the streaming-start site.
    private func streamingPromptForRoutedContext(
        _ context: BridgeWire.DictateContext?,
        engine: String,
        userVocabulary: Vocabulary
    ) -> String {
        let agentTerms = AgentContextVocabulary.derivedTerms(
            cwd: context?.cwd, gitBranch: context?.gitBranch,
            terms: context?.terms ?? [],
            existingTerms: userVocabulary.terms)
        // effectiveWhisperPrompt: user vocab prompt + agent terms (deduped).
        let base = userVocabulary.whisperPrompt
        let extra = AgentContextVocabulary.merged(base: [], with: agentTerms)
            .joined(separator: ", ")
        let effective = base.isEmpty ? extra : (extra.isEmpty ? base : "\(base), \(extra)")
        // The capability gate AppState applies before handing the engine a prompt.
        return EngineCapabilities.honorsStreamingVocabulary(transcriptionEngine: engine)
            ? effective : ""
    }

    func testAgentContextBranchNameBiasesStreamingPromptWhereHonored() {
        // A real dictate frame carrying workspace context, routed through the SAME
        // BridgeRouter path the server uses.
        let frame = bridgeFrame(#"""
        {"jsonrpc":"2.0","id":"cc-1","method":"dictate","params":{"prompt":"which file?","context":{"cwd":"/Users/me/projects/OpenWhisp","gitBranch":"mak-75-agent-context","terms":["RefineFlow"]}}}
        """#)
        guard case let .intent(.dictate(_, params)) = BridgeRouter.route(line: frame, hasHandshaken: true) else {
            return XCTFail("expected .dictate intent")
        }
        // The context survived the wire round-trip through the real router.
        XCTAssertEqual(params.context?.gitBranch, "mak-75-agent-context")

        let userVocab = Vocabulary(terms: ["Anthropic"], substitutions: [])

        // whisper.cpp HONORS streaming vocabulary (.all): the branch, project, and
        // file identifiers reach the engine prompt alongside the user's vocab.
        let honored = streamingPromptForRoutedContext(
            params.context, engine: EngineCapabilities.whisperCpp, userVocabulary: userVocab)
        XCTAssertTrue(honored.contains("Anthropic"), "user vocab preserved: \(honored)")
        XCTAssertTrue(honored.contains("mak-75-agent-context"), "branch biased: \(honored)")
        XCTAssertTrue(honored.contains("OpenWhisp"), "project name biased: \(honored)")
        XCTAssertTrue(honored.contains("RefineFlow"), "file identifier biased: \(honored)")

        // Parakeet does NOT honor streaming vocabulary (.batchOnly): the gate hands
        // it "" — a declared no-op, never a silent partial bias.
        let notHonored = streamingPromptForRoutedContext(
            params.context, engine: EngineCapabilities.parakeet, userVocabulary: userVocab)
        XCTAssertEqual(notHonored, "", "batch-only engine gets no streaming prompt")
    }

    func testAgentContextDropsUserVocabDuplicatesAndSecrets() {
        // Context whose branch carries an API-key-shaped token and whose cwd
        // repeats a user vocab term, routed for real.
        let frame = bridgeFrame(#"""
        {"jsonrpc":"2.0","id":"cc-2","method":"dictate","params":{"context":{"cwd":"/tmp/OpenWhisp","gitBranch":"tmp/sk-Ab12Cd34Ef56Gh78Ij90"}}}
        """#)
        guard case let .intent(.dictate(_, params)) = BridgeRouter.route(line: frame, hasHandshaken: true) else {
            return XCTFail("expected .dictate intent")
        }
        let userVocab = Vocabulary(terms: ["OpenWhisp"], substitutions: [])
        let prompt = streamingPromptForRoutedContext(
            params.context, engine: EngineCapabilities.whisperCpp, userVocabulary: userVocab)
        // "OpenWhisp" appears once (user vocab), not duplicated from the cwd.
        let occurrences = prompt.components(separatedBy: "OpenWhisp").count - 1
        XCTAssertEqual(occurrences, 1, "user vocab term not double-biased: \(prompt)")
        // The secret-shaped token never reaches the prompt (secret guard).
        XCTAssertFalse(prompt.contains("sk-Ab12"), "secret-shaped token biased: \(prompt)")
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

    // MARK: - Self-learning dictionary (MAK-41)

    /// Part A end-to-end: a transcript cleaned through the REAL pipeline that a
    /// substitution rewrites bumps exactly that rule's usageCount (via the same
    /// pure helper AppState calls), and a rule that didn't fire stays put. This is
    /// the integration proof that "used N×" reflects real dictations, not a stub.
    func testVocabularyUsageCountReflectsWhatTheCleanerRewrote() {
        let clod = Vocabulary.Substitution(from: "clod code", to: "Claude Code", usageCount: 0)
        let kube = Vocabulary.Substitution(from: "kube", to: "kubectl", usageCount: 4)
        var vocab = Vocabulary(terms: [], substitutions: [clod, kube])

        // Drive a raw transcript through the real cleaner with vocabulary on.
        let config = TranscriptCleaner.Config(
            language: "en",
            customVocabularyEnabled: true,
            substitutions: vocab.substitutions,
            smartFormattingEnabled: true,
            fillerRemovalEnabled: false,
            spokenPunctuationEnabled: false
        )
        let cleaned = TranscriptCleaner(config: config)
            .clean("i love clod code", isFinalTranscript: true)
        XCTAssertTrue(cleaned.contains("Claude Code"), "the cleaner must actually apply the rule")

        // AppState bumps usage from the pre-enhancement transcript via this helper.
        let fired = VocabularySubstitutor(substitutions: vocab.substitutions)
            .firedSubstitutionIDs(in: "i love clod code")
        vocab = vocab.incrementingUsage(of: fired)

        XCTAssertEqual(vocab.substitutions[0].usageCount, 1, "clod code fired → +1")
        XCTAssertEqual(vocab.substitutions[1].usageCount, 4, "kube never appeared → unchanged")
        // And the editor's sort now orders the freshly-used rule ahead by usage.
        XCTAssertEqual(
            Vocabulary(terms: [], substitutions: [
                Vocabulary.Substitution(from: "a", to: "A", usageCount: 0),
                vocab.substitutions[0]  // usageCount 1
            ]).substitutionsByFrequency().first?.from,
            "clod code")
    }

    /// REGRESSION GUARD for the keying bug (MAJOR 1): usage counting MUST key on the
    /// PRE-clean transcript the vocabulary stage matched against, NOT the
    /// post-`postProcess` output. This test drives the REAL cleaner to produce the
    /// cleaned text, then asserts:
    ///   1. keying on the cleaned OUTPUT (the old, buggy behavior) FAILS to count a
    ///      normal (from != to) rule — because vocab already rewrote `from`→`to`, so
    ///      `from` no longer appears; and
    ///   2. keying on the RAW pre-clean input (the fixed behavior) DOES count it.
    /// If someone reverts recordVocabularyUsage to key on the cleaned text, assertion
    /// (2) breaks and this test fails — which is exactly the guard the reviewer asked
    /// for. `completeFinalText` passes the raw `text`, so this models the shipped path.
    func testUsageCountingKeysOnPreCleanTranscriptNotCleanedOutput() {
        let clodID = UUID()
        let rule = Vocabulary.Substitution(id: clodID, from: "clod code", to: "Claude Code")
        let vocab = Vocabulary(terms: [], substitutions: [rule])

        let config = TranscriptCleaner.Config(
            language: "en", customVocabularyEnabled: true, substitutions: vocab.substitutions,
            smartFormattingEnabled: true, fillerRemovalEnabled: false, spokenPunctuationEnabled: false)

        let rawTranscript = "i love clod code"
        let cleanedOutput = TranscriptCleaner(config: config).clean(rawTranscript, isFinalTranscript: true)
        XCTAssertTrue(cleanedOutput.contains("Claude Code"))
        XCTAssertFalse(cleanedOutput.lowercased().contains("clod code"),
                       "precondition: the rule's `from` is gone from the cleaned output")

        let sub = VocabularySubstitutor(substitutions: vocab.substitutions)

        // (1) BUGGY keying on the cleaned output → the rule can't match its own `to`.
        let firedFromCleaned = sub.firedSubstitutionIDs(in: cleanedOutput)
        XCTAssertFalse(firedFromCleaned.contains(clodID),
                       "keying on post-clean text must NOT count a from != to rule (the bug)")

        // (2) FIXED keying on the raw pre-clean transcript → the rule is counted.
        let firedFromRaw = sub.firedSubstitutionIDs(in: rawTranscript)
        XCTAssertTrue(firedFromRaw.contains(clodID),
                      "keying on the raw pre-clean transcript must count the rule (the fix)")

        let bumped = vocab.incrementingUsage(of: firedFromRaw)
        XCTAssertEqual(bumped.substitutions.first(where: { $0.id == clodID })?.usageCount, 1)
    }

    /// REGRESSION GUARD for the LIVE-CHUNK variant of the keying bug: streaming
    /// sessions clean each CHUNK (vocabulary applied per chunk) and accumulate the
    /// SUBSTITUTED text into the session buffer, so even the "raw" text handed to
    /// completeFinalText no longer contains the `from` phrases. The fix captures
    /// the firing decision inside every postProcess call, via
    /// `TranscriptCleaner.firedSubstitutionIDs(inRawTranscript:)`, unioned across
    /// the session. This pins both halves:
    ///   1. the accumulated post-chunk session text does NOT fire the rule (so
    ///      keying only on completeFinalText's input can't count streaming use);
    ///   2. the per-chunk cleaner capture DOES fire it — including through the
    ///      cleaner's own normalization (whisper's newline/marker noise), which a
    ///      bare VocabularySubstitutor match on the raw chunk would miss.
    func testLiveChunkUsageCountingRequiresPerCleanCapture() {
        let rule = Vocabulary.Substitution(from: "clod code", to: "Claude Code")
        let config = TranscriptCleaner.Config(
            language: "en", customVocabularyEnabled: true, substitutions: [rule],
            smartFormattingEnabled: true, fillerRemovalEnabled: false, spokenPunctuationEnabled: false)
        let cleaner = TranscriptCleaner(config: config)

        // Simulate the live pipeline: chunks cleaned individually, then joined —
        // exactly what insertLiveChunk accumulates into currentSessionText.
        let rawChunks = [" i love\nclod code", "every day"]
        let sessionText = rawChunks.map { cleaner.clean($0, isFinalTranscript: false) }
            .joined(separator: " ")
        XCTAssertTrue(sessionText.contains("Claude Code"))

        // (1) The accumulated session text can no longer fire the rule.
        XCTAssertTrue(
            VocabularySubstitutor(substitutions: [rule])
                .firedSubstitutionIDs(in: sessionText).isEmpty,
            "post-chunk session text must not be the usage-count key (the bug)")

        // (2) Per-clean capture on each raw chunk fires it (union across chunks),
        //     surviving whisper's leading-space/newline noise via the cleaner's
        //     shared normalization.
        var fired: Set<Vocabulary.Substitution.ID> = []
        for chunk in rawChunks {
            fired.formUnion(cleaner.firedSubstitutionIDs(inRawTranscript: chunk))
        }
        XCTAssertEqual(fired, [rule.id], "per-clean capture must count the rule once")
    }

    /// Part C plumbing end-to-end: a captured type-over pair flows EditDiff →
    /// proposeSubstitution → CorrectionProposalState as a user-visible proposal;
    /// accepting adds a real, applied substitution; a second reject-then-recapture
    /// of the same fix is suppressed. Pure — models exactly what the AX watcher
    /// feeds AppState, without any AX.
    func testCorrectionCaptureBecomesProposalThenAcceptedRule() {
        // The watcher observes "kubernetis" inserted, "kubernetes" surviving.
        guard let pair = EditDiff.singleTokenCorrection(
            afterInsert: "we run kubernetis in prod",
            later: "we run kubernetes in prod"
        ) else { return XCTFail("clean single-word edit should be captured") }

        var vocab = Vocabulary(terms: [], substitutions: [])
        let (state, added) = CorrectionProposalState.empty.considering(
            inserted: pair.inserted, surviving: pair.surviving,
            existingSubstitutions: vocab.substitutions, now: at(0))
        XCTAssertEqual(added?.from, "kubernetis")
        XCTAssertEqual(added?.to, "kubernetes")

        // Accept → substitution added and now actually rewrites future transcripts.
        let (afterAccept, accepted) = state.accepting(added!.id)
        vocab.substitutions.append(accepted!)
        XCTAssertTrue(afterAccept.pending.isEmpty)
        XCTAssertEqual(
            VocabularySubstitutor(substitutions: vocab.substitutions)
                .apply(to: "deploy kubernetis now"),
            "deploy kubernetes now")

        // Reject path on a fresh capture suppresses the identical re-proposal.
        let (s1, p1) = CorrectionProposalState.empty.considering(
            inserted: "run helo there", surviving: "run hello there",
            existingSubstitutions: [], now: at(1))
        let afterReject = s1.rejecting(p1!.id)
        let (s2, again) = afterReject.considering(
            inserted: "say helo again", surviving: "say hello again",
            existingSubstitutions: [], now: at(2))
        XCTAssertNil(again, "a declined fix must never be re-proposed")
        XCTAssertTrue(s2.pending.isEmpty)
    }

    // MARK: - Voice editing in live dictation (MAK-19)
    //
    // These drive a session's finalized utterances through the SAME seam the app
    // wiring uses — `VoiceEditRouter` mutating a session-scoped `VoiceEditBuffer` —
    // and assert the pending text is edited BEFORE it would be pasted. This is the
    // integration point `handleAppleSpeechFinal` calls when `voiceEditingEnabled`
    // is on in a preview session; the AppState/SwiftUI glue around it is build-
    // verified, but the routing decision is pinned here.

    /// Mirror of `AppState.handleAppleSpeechFinal`'s voice-edit decision, driven by
    /// the SAME `VoiceEditRouter.isActive` gate + routing the app uses. This is the
    /// integration the reviewer required: it composes the gate WITH routing, not the
    /// router in isolation, so a dead gate (feature never armed) is caught here.
    /// Returns the text that would be handed to postProcess/paste.
    private func finalizeTranscript(
        _ rawTranscript: String,
        outputMode: String,
        voiceEditingEnabled: Bool,
        suppressOutput: Bool
    ) -> String {
        let active = VoiceEditRouter.isActive(
            outputMode: outputMode,
            enabled: voiceEditingEnabled,
            suppressOutput: suppressOutput
        )
        guard active else { return rawTranscript }
        var buffer = VoiceEditBuffer()
        VoiceEditRouter.route(final: rawTranscript, into: &buffer)
        return buffer.text
    }

    /// End-to-end through the gate: in a preview session with the feature on, a
    /// standalone "Scratch that." edits the finalized text. This FAILS if the gate
    /// is dead (`isActive` false) — the exact regression the review found, where the
    /// wiring read `isPreviewSession` (always false on the streaming path) instead
    /// of `outputMode`.
    func testVoiceEditFinalizeAppliesCommandInPreview() {
        let finalized = finalizeTranscript(
            "Hello world. Scratch that. Fresh start.",
            outputMode: "preview",
            voiceEditingEnabled: true,
            suppressOutput: false
        )
        XCTAssertEqual(finalized, "Fresh start.",
                       "preview + enabled must apply the spoken command")
        XCTAssertFalse(finalized.lowercased().contains("scratch"))
    }

    /// The gate is OFF for every non-qualifying session, and then the raw transcript
    /// passes through byte-for-byte (no segmentation, no editing) — the no-regression
    /// contract. Covers: setting off, non-preview modes, and agent (suppressOutput)
    /// sessions. If any of these accidentally armed the feature, "Scratch that."
    /// would edit the text and these would fail.
    func testVoiceEditGateOffLeavesTranscriptUntouched() {
        let raw = "Hello world. Scratch that. Fresh start."
        let offCases: [(String, Bool, Bool)] = [
            ("preview",    false, false),  // setting off
            ("finalOnly",  true,  false),  // not preview
            ("liveChunks", true,  false),  // not preview
            ("preview",    true,  true),   // agent session
        ]
        for (mode, enabled, suppress) in offCases {
            XCTAssertFalse(
                VoiceEditRouter.isActive(outputMode: mode, enabled: enabled, suppressOutput: suppress),
                "gate must be off for mode=\(mode) enabled=\(enabled) suppress=\(suppress)")
            XCTAssertEqual(
                finalizeTranscript(raw, outputMode: mode, voiceEditingEnabled: enabled, suppressOutput: suppress),
                raw,
                "gate off must leave the transcript byte-for-byte unchanged")
        }
        // And the positive: the gate is on precisely for preview + enabled + non-agent.
        XCTAssertTrue(VoiceEditRouter.isActive(outputMode: "preview", enabled: true, suppressOutput: false))
    }

    /// The headline flow: dictate, then a standalone "scratch that" drops exactly
    /// the last utterance — and its literal words never reach the pasted text.
    func testVoiceEditScratchThatDropsLastUtterance() {
        var buffer = VoiceEditBuffer()
        // Utterances arrive finalized, one at a time, as the router segments them.
        XCTAssertFalse(VoiceEditRouter.route("hello world", into: &buffer))
        XCTAssertTrue(VoiceEditRouter.route("scratch that", into: &buffer),
                      "\"scratch that\" must be recognized as a command")
        XCTAssertEqual(buffer.text, "", "scratch that drops the only utterance")

        // A second dictation, then scratch: only the last chunk is dropped.
        _ = VoiceEditRouter.route("keep this", into: &buffer)
        _ = VoiceEditRouter.route("drop this", into: &buffer)
        XCTAssertTrue(VoiceEditRouter.route("scratch that", into: &buffer))
        XCTAssertEqual(buffer.text, "keep this")
        XCTAssertFalse(buffer.text.lowercased().contains("scratch"),
                       "the command words must never appear in the final text")
    }

    /// "delete last word" removes just the trailing word across the flattened text.
    func testVoiceEditDeleteLastWord() {
        var buffer = VoiceEditBuffer()
        _ = VoiceEditRouter.route("the quick brown fox", into: &buffer)
        XCTAssertTrue(VoiceEditRouter.route("delete last word", into: &buffer))
        XCTAssertEqual(buffer.text, "the quick brown")
        XCTAssertFalse(buffer.text.contains("delete"))
    }

    /// "undo" restores whatever the previous destructive edit removed (one level).
    func testVoiceEditUndoRestores() {
        var buffer = VoiceEditBuffer()
        _ = VoiceEditRouter.route("first thought", into: &buffer)
        _ = VoiceEditRouter.route("second thought", into: &buffer)
        XCTAssertTrue(VoiceEditRouter.route("scratch that", into: &buffer))
        XCTAssertEqual(buffer.text, "first thought")
        XCTAssertTrue(VoiceEditRouter.route("undo", into: &buffer))
        XCTAssertEqual(buffer.text, "first thought second thought",
                       "undo restores the scratched utterance verbatim")
    }

    /// A whole cumulative transcript (what the streaming recognizers actually
    /// deliver — one blob per hold, not one utterance at a time) is segmented on
    /// sentence boundaries so a standalone command punctuated as its own sentence
    /// is still recognized. This is the exact call `handleAppleSpeechFinal` makes.
    func testVoiceEditRoutesWholeFinalTranscript() {
        var buffer = VoiceEditBuffer()
        VoiceEditRouter.route(final: "Hello world. Scratch that. Fresh start.",
                              into: &buffer)
        XCTAssertEqual(buffer.text, "Fresh start.",
                       "the standalone command sentence edits; its words are gone")
        XCTAssertFalse(buffer.text.lowercased().contains("scratch"))
    }

    /// The safe-failure boundary: a command buried INSIDE a larger utterance is NOT
    /// recognized (parse requires the whole unit to be the command), so it stays as
    /// literal text rather than silently eating real speech. Documents the limit.
    func testVoiceEditBundledCommandStaysLiteral() {
        var buffer = VoiceEditBuffer()
        // No sentence boundary isolates "scratch that" — the whole thing is one unit.
        VoiceEditRouter.route(final: "finish the report scratch that let me redo it",
                              into: &buffer)
        XCTAssertEqual(buffer.text, "finish the report scratch that let me redo it",
                       "a mid-utterance command is left as text — the safe failure")
    }

    /// Ordinary prose that merely CONTAINS a command's words is never hijacked, and
    /// round-trips unchanged through segmentation + routing.
    func testVoiceEditOrdinaryDictationUnchanged() {
        var buffer = VoiceEditBuffer()
        VoiceEditRouter.route(final: "Please scratch the surface of this idea.",
                              into: &buffer)
        XCTAssertEqual(buffer.text, "Please scratch the surface of this idea.")
    }

    /// "new paragraph" / "new line" insert breaks that survive later edits and the
    /// flattening for the paste-ready string.
    func testVoiceEditBreakCommands() {
        var buffer = VoiceEditBuffer()
        _ = VoiceEditRouter.route("first line", into: &buffer)
        XCTAssertTrue(VoiceEditRouter.route("new paragraph", into: &buffer))
        _ = VoiceEditRouter.route("second block", into: &buffer)
        XCTAssertEqual(buffer.text, "first line\n\nsecond block")
    }

    /// Segmentation contract: real sentence terminators and newlines split units;
    /// empties are dropped; a terminator-free transcript is a single unit. The `.`
    /// split is context-aware (shares VoiceEditBuffer.isSentenceEndingPeriod) and
    /// requires trailing whitespace, so it never splits inside a token.
    func testVoiceEditSegmentation() {
        XCTAssertEqual(VoiceEditRouter.segmentUtterances("one continuous phrase"),
                       ["one continuous phrase"])
        XCTAssertEqual(VoiceEditRouter.segmentUtterances("Alpha. Beta! Gamma?"),
                       ["Alpha.", "Beta!", "Gamma?"])
        XCTAssertEqual(VoiceEditRouter.segmentUtterances("line one\nline two"),
                       ["line one", "line two"])
        // A period NOT followed by whitespace never splits (mid-token dot).
        XCTAssertEqual(VoiceEditRouter.segmentUtterances("visit example.com now"),
                       ["visit example.com now"])
        // A lone capital initial ("A.") is not a sentence end — mirrors the
        // delete-last-sentence rule, so "A. B" stays joined.
        XCTAssertEqual(VoiceEditRouter.segmentUtterances("A. B! C?"),
                       ["A. B!", "C?"])
        XCTAssertEqual(VoiceEditRouter.segmentUtterances("   "), [])
        XCTAssertEqual(VoiceEditRouter.segmentUtterances(""), [])
    }

    /// The regression the adversarial review caught: because the feature defaults
    /// ON, every command-free preview dictation is routed through the buffer, so
    /// `route(final:)` MUST be a byte-for-byte no-op on ordinary prose — no spaced-
    /// out decimals/currency/versions/domains, no split abbreviations, no lone
    /// terminator marks from ellipses / repeated punctuation.
    func testVoiceEditRoundTripsCommandFreeProse() {
        let prose = [
            "The price is 3.50 dollars.",
            "It costs $9.99 total.",
            "Section 3.2.1 is next.",
            "Visit example.com now.",
            "Wait... no.",
            "Yes!!! Absolutely.",
            "I met Mr. Smith today.",
            "Hello world. How are you?",
            "One sentence with no terminator",
            "A number like 42 and a word.",
        ]
        for s in prose {
            var buffer = VoiceEditBuffer()
            VoiceEditRouter.route(final: s, into: &buffer)
            XCTAssertEqual(buffer.text, s,
                           "command-free prose must round-trip byte-for-byte: \(s)")
        }
    }

}
