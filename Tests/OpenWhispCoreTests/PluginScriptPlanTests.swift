import XCTest
@testable import OpenWhispCore

/// The script-plugin tier (docs/PLUGINS.md § "Path to hot-swappable" §1): manifest
/// decoding of the new fields, step-plan resolution, the script-path containment rule,
/// consent gating, and the forward-compatibility guarantees.
///
/// These cover the whole DECISION layer. The app-side `PluginScriptRunner` performs IO
/// for a plan resolved here and makes no decisions of its own — which is the only way a
/// feature whose surfaces live outside `swift test` can be honestly covered.
final class PluginScriptPlanTests: XCTestCase {

    // MARK: - Helpers

    private func decode(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private func scriptManifest(
        id: String = "demo",
        steps: [PluginStep]
    ) -> PluginManifest {
        PluginManifest(
            id: id, name: "Demo", version: "1.0.0", summary: "s",
            symbol: "puzzlepiece.extension", entry: .script, steps: steps)
    }

    private func plan(
        _ manifest: PluginManifest, consent: Bool = true
    ) -> Result<PluginScriptPlan.Plan, PluginScriptPlan.Failure> {
        PluginScriptPlan.resolve(manifest: manifest, hasScriptConsent: consent)
    }

    private func failure(
        _ manifest: PluginManifest, consent: Bool = true
    ) -> PluginScriptPlan.Failure? {
        guard case let .failure(f) = plan(manifest, consent: consent) else { return nil }
        return f
    }

    // MARK: - Manifest decoding

    /// The headline: a script plugin's manifest decodes with its steps intact.
    func testScriptManifestDecodesWithItsSteps() throws {
        let manifest = try decode("""
        {
          "id": "commit-message",
          "name": "Commit Message",
          "symbol": "text.badge.checkmark",
          "entry": "script",
          "steps": [
            {"type": "llm", "prompt": "Rewrite as a commit message:\\n{{text}}"},
            {"type": "insertAtCursor"}
          ]
        }
        """)

        XCTAssertEqual(manifest.entry, .script)
        XCTAssertEqual(manifest.steps.count, 2)
        XCTAssertEqual(manifest.steps[0].kind, .llm)
        XCTAssertEqual(manifest.steps[1].kind, .insertAtCursor)
        XCTAssertTrue(manifest.isValid)
    }

    /// Every step field round-trips, so a manifest the host re-encodes is the manifest
    /// the author wrote.
    func testStepsRoundTripThroughJSON() throws {
        let original = scriptManifest(steps: [
            PluginStep(kind: .llm, prompt: "Do the thing with {{text}}"),
            PluginStep(kind: .writeFile, file: FileOutputConfig(
                path: "~/notes/log.md", template: "## {{datetime}}", mode: .append)),
            PluginStep(kind: .runScript, script: "format.sh"),
            PluginStep(kind: .insertAtCursor),
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.steps[1].file?.path, "~/notes/log.md")
        XCTAssertEqual(decoded.steps[2].script, "format.sh")
    }

    // MARK: - Forward compatibility

    /// A manifest predating script plugins entirely still decodes, and gets no steps —
    /// the standing rule for every field added to this schema.
    func testManifestPredatingStepsStillDecodes() throws {
        let manifest = try decode("""
        {"id": "legacy", "name": "Legacy", "symbol": "questionmark.circle"}
        """)

        XCTAssertEqual(manifest.entry, .builtIn)
        XCTAssertEqual(manifest.steps, [])
        XCTAssertTrue(manifest.isValid)
    }

    /// The bug this schema addition would otherwise have shipped: `decodeIfPresent`
    /// THROWS on an unrecognized enum value rather than returning nil, so an unknown
    /// `entry` used to fail the whole decode and the plugin DISAPPEARED from the pane.
    ///
    /// A manifest from a future OpenWhisp must be listed and refused with a reason, not
    /// erased — there is no migration path for a file the app does not own.
    func testUnknownEntryKindDecodesToUnsupportedRatherThanFailing() throws {
        let manifest = try decode("""
        {
          "id": "from-the-future",
          "name": "From The Future",
          "symbol": "sparkles",
          "entry": "webAssembly"
        }
        """)

        XCTAssertEqual(manifest.entry, .unsupported)
        // Listed…
        XCTAssertTrue(manifest.isValid)
        // …but honestly refused.
        XCTAssertFalse(manifest.entry.isRunnable)
        XCTAssertNotNil(manifest.entry.unavailableReason)
    }

    /// An unknown STEP type is likewise not a decode failure. The plugin is listed, and
    /// refuses to run — running a pipeline with the step it didn't understand silently
    /// skipped would be strictly worse than refusing.
    func testUnknownStepTypeIsCarriedAndRefusedRatherThanDropped() throws {
        let manifest = try decode("""
        {
          "id": "future-steps",
          "name": "Future Steps",
          "symbol": "sparkles",
          "entry": "script",
          "steps": [
            {"type": "llm", "prompt": "hi {{text}}"},
            {"type": "renderVideo"}
          ]
        }
        """)

        // The step survived decoding rather than being silently dropped…
        XCTAssertEqual(manifest.steps.count, 2)
        XCTAssertEqual(manifest.steps[1].kind, .unsupported("renderVideo"))
        XCTAssertFalse(manifest.steps[1].kind.isSupported)
        // …and the pipeline refuses, naming the step so the user can act on it.
        XCTAssertEqual(failure(manifest), .unsupportedStep("renderVideo"))
        XCTAssertTrue(failure(manifest)!.reason.contains("renderVideo"))
    }

    /// A step with no `type` cannot be defaulted to any action — every default would be
    /// a guess at something with side effects — so the step list decodes to empty and
    /// the plugin is refused rather than partially run.
    func testStepWithNoTypeYieldsNoStepsRatherThanACrash() throws {
        let manifest = try decode("""
        {
          "id": "malformed", "name": "Malformed", "symbol": "star",
          "entry": "script",
          "steps": [{"prompt": "no type here"}]
        }
        """)

        XCTAssertEqual(manifest.steps, [])
        XCTAssertEqual(failure(manifest), .noSteps)
    }

    /// `steps` that isn't even an array must not throw the plugin out of the list.
    func testMalformedStepsValueDegradesToNoSteps() throws {
        let manifest = try decode("""
        {"id": "weird", "name": "Weird", "symbol": "star",
         "entry": "script", "steps": "not-an-array"}
        """)

        XCTAssertEqual(manifest.steps, [])
        XCTAssertTrue(manifest.isValid)
    }

    // MARK: - Runnability and trust ordering

    /// The point of the whole tier: a script plugin found on DISK is runnable, which is
    /// what "install a plugin without rebuilding the app" means.
    func testExternalScriptPluginIsRunnable() {
        let merged = PluginDiscovery.merge(
            builtIn: [], external: [scriptManifest(id: "dropped-in", steps: [
                PluginStep(kind: .insertAtCursor)
            ])])

        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isRunnable)
        XCTAssertNil(merged[0].unavailableReason)
    }

    /// …and the boundary that makes it safe: an on-disk folder claiming `builtIn` is
    /// still refused. A manifest cannot promote itself into compiled code.
    func testExternalPluginClaimingBuiltInIsStillRefused() {
        let manifest = PluginManifest(
            id: "sneaky", name: "Sneaky", version: "1.0.0", summary: "s",
            symbol: "star", entry: .builtIn)
        let merged = PluginDiscovery.merge(builtIn: [], external: [manifest])

        XCTAssertFalse(merged[0].isRunnable)
        XCTAssertNotNil(merged[0].unavailableReason)
    }

    /// The trust ordering must survive script plugins becoming runnable — otherwise a
    /// writable directory could substitute a script pipeline for a reviewed plugin.
    func testBuiltInStillWinsAnIDCollisionWithAnExternalScriptPlugin() {
        let merged = PluginDiscovery.merge(
            builtIn: [PluginManifest(
                id: "meme-generator", name: "Real", version: "1.0.0", summary: "s",
                symbol: "star", entry: .builtIn)],
            external: [scriptManifest(id: "meme-generator", steps: [
                PluginStep(kind: .runScript, script: "pwn.sh")
            ])])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].manifest.name, "Real")
        XCTAssertEqual(merged[0].source, .builtIn)
        XCTAssertEqual(merged[0].manifest.entry, .builtIn)
    }

    // MARK: - Plan resolution

    func testAWellFormedPipelineResolves() throws {
        let manifest = scriptManifest(steps: [
            PluginStep(kind: .llm, prompt: "Summarize {{text}}"),
            PluginStep(kind: .writeFile, file: FileOutputConfig(path: "~/log.md")),
            PluginStep(kind: .insertAtCursor),
        ])

        guard case let .success(resolved) = plan(manifest) else {
            return XCTFail("expected a resolved plan")
        }
        XCTAssertEqual(resolved.pluginID, "demo")
        XCTAssertEqual(resolved.steps.count, 3)
        XCTAssertTrue(resolved.deliversAtCursor)
    }

    /// A pipeline that only writes a file has already delivered its output; the runner
    /// asks the plan rather than inferring, so it can't also paste.
    func testAPipelineWithoutACursorStepDoesNotDeliverAtCursor() {
        let manifest = scriptManifest(steps: [
            PluginStep(kind: .writeFile, file: FileOutputConfig(path: "~/log.md"))
        ])
        guard case let .success(resolved) = plan(manifest) else {
            return XCTFail("expected a resolved plan")
        }
        XCTAssertFalse(resolved.deliversAtCursor)
    }

    func testANonScriptManifestIsNotAPlan() {
        let builtIn = PluginManifest(
            id: "meme-generator", name: "Meme", version: "1.0.0", summary: "s",
            symbol: "star", entry: .builtIn)
        XCTAssertEqual(failure(builtIn), .notAScriptPlugin)
    }

    /// Declaring `entry: script` with no steps must not silently "succeed" — a plugin
    /// that did nothing would be indistinguishable from one that worked.
    func testAScriptPluginWithNoStepsIsRefused() {
        XCTAssertEqual(failure(scriptManifest(steps: [])), .noSteps)
    }

    func testAnLLMStepWithNoPromptIsRefused() {
        XCTAssertEqual(
            failure(scriptManifest(steps: [PluginStep(kind: .llm)])),
            .missingPrompt(stepIndex: 0))
        // Whitespace is not a prompt.
        XCTAssertEqual(
            failure(scriptManifest(steps: [PluginStep(kind: .llm, prompt: "   \n ")])),
            .missingPrompt(stepIndex: 0))
    }

    func testAWriteFileStepWithNoPathIsRefused() {
        XCTAssertEqual(
            failure(scriptManifest(steps: [
                PluginStep(kind: .insertAtCursor),
                PluginStep(kind: .writeFile, file: FileOutputConfig(path: "  ")),
            ])),
            .missingFilePath(stepIndex: 1))
        XCTAssertEqual(
            failure(scriptManifest(steps: [PluginStep(kind: .writeFile)])),
            .missingFilePath(stepIndex: 0))
    }

    /// A manifest cannot ask the host to chain an unbounded number of subprocesses,
    /// model calls, and file writes from one dictation — nor recurse the runner's walk
    /// arbitrarily deep on a value from a file the app does not own.
    func testAnAbsurdlyLongPipelineIsRefused() {
        let overLimit = PluginScriptPlan.stepLimit + 1
        let manifest = scriptManifest(
            steps: Array(repeating: PluginStep(kind: .insertAtCursor), count: overLimit))

        XCTAssertEqual(
            failure(manifest), .tooManySteps(count: overLimit, limit: PluginScriptPlan.stepLimit))

        // Exactly at the limit still runs — the cap is a bound, not a discouragement.
        let atLimit = scriptManifest(
            steps: Array(repeating: PluginStep(kind: .insertAtCursor),
                         count: PluginScriptPlan.stepLimit))
        guard case .success = plan(atLimit) else {
            return XCTFail("a pipeline exactly at the limit must resolve")
        }
    }

    /// A failing script step must be DISTINGUISHABLE from one that echoed its input.
    ///
    /// `ScriptRunner.run` is fail-open by contract — right for the dictation finalize
    /// path, where the user's words must survive a broken script, and wrong for a
    /// plugin step, where the user asked for a transform. Passing the untransformed
    /// text on would paste the wrong thing and report success.
    func testAFailingScriptIsAnErrorNotAPassThrough() {
        XCTAssertEqual(
            ScriptOutcome.resolve(
                original: "in", stdout: nil, exitCode: nil, timedOut: false, launchFailed: true),
            .keepOriginal(reason: "Script couldn't run"))
        XCTAssertEqual(
            ScriptOutcome.resolve(
                original: "in", stdout: "", exitCode: 0, timedOut: false, launchFailed: false),
            .keepOriginal(reason: "Script returned empty output"))
        XCTAssertEqual(
            ScriptOutcome.resolve(
                original: "in", stdout: "out\n", exitCode: 0, timedOut: false, launchFailed: false),
            .useOutput("out"))

        // And the failure carries a user-facing sentence rather than a bare code.
        let reason = PluginScriptPlan.Failure.scriptStepFailed(reason: "Script timed out").reason
        XCTAssertTrue(reason.contains("timed out"), reason)
    }

    /// The fail-open wrapper still behaves as the finalize path expects — the refactor
    /// that added `outcome` must not have changed `run`'s contract.
    func testScriptRunnerRunStillFailsOpen() {
        XCTAssertEqual(
            ScriptOutcome.resolvedText(
                original: "keep me", stdout: nil, exitCode: nil,
                timedOut: true, launchFailed: false),
            "keep me")
    }

    // MARK: - Script path containment

    /// The security rule of the tier. The plugins folder is user-writable and this app
    /// holds Accessibility, mic, and clipboard rights, so a manifest that could name an
    /// arbitrary executable would turn "drop a JSON file in a folder" into local code
    /// execution against an entitled process.
    func testAScriptMustLiveInsideItsOwnPluginDirectory() {
        for hostile in ["/bin/sh", "/usr/bin/osascript", "~/evil.sh", "~/../evil.sh"] {
            XCTAssertEqual(
                PluginScriptPath.validate(hostile), .absolute(hostile),
                "expected \(hostile) to be refused as absolute")
        }
        for traversal in ["../evil.sh", "../../bin/sh", "nested/../../escape.sh", "a/../../b"] {
            XCTAssertEqual(
                PluginScriptPath.validate(traversal), .escapesPluginDirectory(traversal),
                "expected \(traversal) to be refused as escaping")
        }
        XCTAssertEqual(PluginScriptPath.validate(""), .empty)
        XCTAssertEqual(PluginScriptPath.validate(nil), .empty)
        XCTAssertEqual(PluginScriptPath.validate("   "), .empty)
    }

    func testAScriptInsideThePluginDirectoryIsAccepted() {
        XCTAssertNil(PluginScriptPath.validate("format.sh"))
        XCTAssertNil(PluginScriptPath.validate("bin/format.sh"))
        XCTAssertNil(PluginScriptPath.validate("./format.sh"))
    }

    /// A refused path never becomes a URL, and an accepted one resolves inside the
    /// plugin's directory — the ONE place a declared script path is joined onto a URL.
    func testResolveRefusesAnythingOutsideThePluginDirectory() {
        let dir = URL(fileURLWithPath: "/plugins/demo", isDirectory: true)

        XCTAssertEqual(
            PluginScriptPath.resolve("format.sh", in: dir)?.path,
            "/plugins/demo/format.sh")
        XCTAssertEqual(
            PluginScriptPath.resolve("bin/run.sh", in: dir)?.path,
            "/plugins/demo/bin/run.sh")

        XCTAssertNil(PluginScriptPath.resolve("../other/evil.sh", in: dir))
        XCTAssertNil(PluginScriptPath.resolve("/bin/sh", in: dir))
        XCTAssertNil(PluginScriptPath.resolve("~/evil.sh", in: dir))
        XCTAssertNil(PluginScriptPath.resolve(nil, in: dir))
    }

    /// The escape a purely lexical check misses: a plugin author controls the contents
    /// of their own folder, symlinks included. `standardizedFileURL` collapses `..`
    /// textually but does NOT follow links, so `esc -> /bin` plus a declared `esc/sh`
    /// looks contained as a string while landing outside the folder entirely.
    ///
    /// Verified to fail before the real-path check was added: the probe resolved to
    /// `<plugin>/esc/evil.sh` whose realpath was `<root>/outside/evil.sh`.
    func testASymlinkInsideThePluginFolderCannotEscapeIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginSymlinkTests-\(UUID().uuidString)")
        let plugin = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(
            to: outside.appendingPathComponent("evil.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: plugin.appendingPathComponent("esc"), withDestinationURL: outside)

        XCTAssertNil(
            PluginScriptPath.resolve("esc/evil.sh", in: plugin),
            "a symlinked path out of the plugin folder must be refused")

        // …and a genuine file beside it still resolves, so the check isn't just
        // refusing everything.
        try "#!/bin/sh\n".write(
            to: plugin.appendingPathComponent("ok.sh"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(PluginScriptPath.resolve("ok.sh", in: plugin))
    }

    /// A sibling folder whose name merely STARTS with the plugin's must not read as a
    /// child — the containment check compares whole path components.
    func testASiblingWithASharedNamePrefixIsNotContained() {
        let plugin = URL(fileURLWithPath: "/plugins/demo", isDirectory: true)
        // Reachable only via traversal, which is refused earlier — assert the refusal
        // holds rather than assuming the prefix check is the only thing standing there.
        XCTAssertNil(PluginScriptPath.resolve("../demo-evil/run.sh", in: plugin))
    }

    /// A hostile script path fails PLAN resolution, not just the path validator — the
    /// runner never sees a plan carrying one.
    func testAPipelineWithAHostileScriptPathDoesNotResolve() {
        XCTAssertEqual(
            failure(scriptManifest(steps: [
                PluginStep(kind: .runScript, script: "../../../usr/bin/osascript")
            ])),
            .invalidScriptPath(.escapesPluginDirectory("../../../usr/bin/osascript")))

        XCTAssertEqual(
            failure(scriptManifest(steps: [PluginStep(kind: .runScript, script: "/bin/sh")])),
            .invalidScriptPath(.absolute("/bin/sh")))
    }

    // MARK: - Consent

    /// Running a shell script needs its OWN consent. "I turned this plugin on" is not
    /// the same statement as "I have read this script and agree it may run".
    func testAScriptStepRequiresItsOwnConsent() {
        let manifest = scriptManifest(steps: [PluginStep(kind: .runScript, script: "run.sh")])

        XCTAssertEqual(failure(manifest, consent: false), .scriptConsentRequired)
        guard case .success = plan(manifest, consent: true) else {
            return XCTFail("expected the plan to resolve once consent is granted")
        }
    }

    /// A pipeline with no script step must NOT demand the script consent — a consent
    /// prompt for a capability the plugin never uses trains users to click through.
    func testAPipelineWithoutAScriptNeedsNoScriptConsent() {
        let manifest = scriptManifest(steps: [
            PluginStep(kind: .llm, prompt: "x {{text}}"),
            PluginStep(kind: .insertAtCursor),
        ])
        guard case .success = plan(manifest, consent: false) else {
            return XCTFail("expected a plan with no script step to resolve without consent")
        }
    }

    /// Consent is checked LAST, so a plugin with a genuinely broken pipeline reports the
    /// real problem instead of nagging for a permission that wouldn't help.
    func testABrokenPipelineReportsItsRealProblemNotTheConsentPrompt() {
        let manifest = scriptManifest(steps: [
            PluginStep(kind: .llm),  // no prompt
            PluginStep(kind: .runScript, script: "run.sh"),
        ])
        XCTAssertEqual(failure(manifest, consent: false), .missingPrompt(stepIndex: 0))
    }

    /// The pane renders these verbatim before the user enables anything, so the exact
    /// words are pinned here rather than left to drift with a view refactor.
    func testConsentDisclosesEveryCapabilityInOrder() {
        let consent = PluginConsent.derive(from: scriptManifest(steps: [
            PluginStep(kind: .llm, prompt: "p"),
            PluginStep(kind: .writeFile, file: FileOutputConfig(path: "~/notes/log.md")),
            PluginStep(kind: .runScript, script: "format.sh"),
            PluginStep(kind: .insertAtCursor),
        ]))

        XCTAssertEqual(consent.scriptNames, ["format.sh"])
        XCTAssertEqual(consent.filePaths, ["~/notes/log.md"])
        XCTAssertTrue(consent.insertsAtCursor)
        XCTAssertTrue(consent.usesLLM)
        XCTAssertTrue(consent.requiresScriptConsent)

        // Most surprising / least reversible first.
        XCTAssertEqual(consent.disclosures, [
            "Runs the bundled script format.sh on your Mac.",
            "Writes to ~/notes/log.md.",
            "Types its result into whatever app you're using.",
            "Sends the text to your configured OpenWhisp model.",
        ])
        XCTAssertEqual(
            consent.scriptConsentPrompt,
            "Allow this plugin to run format.sh on your Mac.")
    }

    func testAPluginThatDoesNothingSurprisingDisclosesNothing() {
        let consent = PluginConsent.derive(from: scriptManifest(steps: [
            PluginStep(kind: .llm, prompt: "p")
        ]))
        XCTAssertFalse(consent.requiresScriptConsent)
        XCTAssertNil(consent.scriptConsentPrompt)
        XCTAssertEqual(consent.disclosures, ["Sends the text to your configured OpenWhisp model."])
    }

    /// An unsupported step contributes no consent facts: the plugin can't run at all, so
    /// claiming it will write a file would be a disclosure about something that will
    /// never happen.
    func testAnUnsupportedStepContributesNoConsentFacts() {
        let consent = PluginConsent.derive(from: scriptManifest(steps: [
            PluginStep(kind: .unsupported("renderVideo"))
        ]))
        XCTAssertEqual(consent.disclosures, [])
        XCTAssertFalse(consent.requiresScriptConsent)
    }

    /// Duplicate paths/scripts are listed once — the disclosure is a set of facts, not a
    /// transcript of the pipeline.
    func testDuplicateConsentFactsAreListedOnce() {
        let consent = PluginConsent.derive(from: scriptManifest(steps: [
            PluginStep(kind: .writeFile, file: FileOutputConfig(path: "~/a.md")),
            PluginStep(kind: .writeFile, file: FileOutputConfig(path: "~/a.md")),
            PluginStep(kind: .runScript, script: "x.sh"),
            PluginStep(kind: .runScript, script: "x.sh"),
        ]))
        XCTAssertEqual(consent.filePaths, ["~/a.md"])
        XCTAssertEqual(consent.scriptNames, ["x.sh"])
    }

    // MARK: - Script consent store

    /// Dictionary-backed store so tests never touch the real UserDefaults domain.
    private final class FakeStore: PluginEnablement.Store {
        var values: [String: [String]] = [:]
        func stringArray(forKey key: String) -> [String]? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value as? [String] }
    }

    /// Permission to execute code is default-DENY, and stored separately from the
    /// enable toggle so turning a plugin on never implies it.
    func testScriptConsentIsDeniedByDefaultAndStoredSeparately() {
        XCTAssertFalse(PluginScriptConsent().hasConsent("anything"))
        XCTAssertNotEqual(PluginScriptConsent.defaultsKey, PluginEnablement.defaultsKey)
    }

    func testScriptConsentRoundTripsThroughItsStore() {
        let store = FakeStore()
        var consent = PluginScriptConsent.load(from: store, availableIDs: ["a", "b"])
        consent.setConsent(true, for: "a")
        consent.save(to: store)

        let reloaded = PluginScriptConsent.load(from: store, availableIDs: ["a", "b"])
        XCTAssertTrue(reloaded.hasConsent("a"))
        XCTAssertFalse(reloaded.hasConsent("b"))
        XCTAssertEqual(store.values[PluginScriptConsent.defaultsKey], ["a"])
    }

    /// The safety half of hot-swap: a folder can be deleted and a DIFFERENT plugin
    /// dropped in under the same id. Without pruning, the new one would inherit
    /// permission to run a script the user never saw.
    func testScriptConsentIsPrunedSoAReplacedPluginMustReconsent() {
        let store = FakeStore()
        PluginScriptConsent(granted: ["gone", "still-here"]).save(to: store)

        let loaded = PluginScriptConsent.load(from: store, availableIDs: ["still-here"])
        XCTAssertFalse(loaded.hasConsent("gone"))
        XCTAssertTrue(loaded.hasConsent("still-here"))
    }

    func testRevokingScriptConsentRemovesItFromTheStore() {
        let store = FakeStore()
        var consent = PluginScriptConsent(granted: ["a", "b"])
        consent.setConsent(false, for: "a")
        consent.save(to: store)
        XCTAssertEqual(store.values[PluginScriptConsent.defaultsKey], ["b"])
    }

    /// Revocation takes effect on the NEXT invocation, because the runner re-resolves
    /// the plan (consent included) every time rather than capturing it at enable-time.
    func testRevokedConsentBlocksTheNextRun() {
        let manifest = scriptManifest(steps: [PluginStep(kind: .runScript, script: "run.sh")])
        guard case .success = plan(manifest, consent: true) else {
            return XCTFail("expected the granted case to resolve")
        }
        XCTAssertEqual(failure(manifest, consent: false), .scriptConsentRequired)
    }

    // MARK: - Prompt expansion

    func testPromptTemplateSubstitutesTheStepInput() {
        XCTAssertEqual(
            PluginScriptPlan.expandPrompt("Rewrite: {{text}}\nBe terse.", text: "hello"),
            "Rewrite: hello\nBe terse.")
    }

    /// A template with no token still works — a user who writes a bare instruction and
    /// never reads the docs gets what they expect rather than a prompt with no input.
    func testAPromptWithNoTokenGetsTheInputAppended() {
        XCTAssertEqual(
            PluginScriptPlan.expandPrompt("Make this a commit message", text: "fixed the bug"),
            "Make this a commit message\n\nfixed the bug")
    }

    func testEveryOccurrenceOfTheTokenIsSubstituted() {
        XCTAssertEqual(
            PluginScriptPlan.expandPrompt("{{text}} / {{text}}", text: "x"),
            "x / x")
    }

    // MARK: - Reload (hot-swap)

    /// The runner resolves from the manifest on disk at INVOCATION time, so editing
    /// `manifest.json` and running the plugin again picks up the edit — no reload, no
    /// relaunch, no rebuild. This repo has already shipped the opposite bug once.
    func testReloadManifestReadsTheCurrentFileNotACachedOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginReloadTests-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("hot-swap")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(prompt: String) throws {
            try """
            {"id":"hot-swap","name":"Hot Swap","symbol":"bolt","entry":"script",
             "steps":[{"type":"llm","prompt":"\(prompt)"}]}
            """.write(to: dir.appendingPathComponent("manifest.json"),
                      atomically: true, encoding: .utf8)
        }

        try write(prompt: "first {{text}}")
        XCTAssertEqual(
            PluginDiscovery.reloadManifest(id: "hot-swap", in: root)?.steps.first?.prompt,
            "first {{text}}")

        // Edit the file in place — the way a user iterating on a plugin would.
        try write(prompt: "second {{text}}")
        XCTAssertEqual(
            PluginDiscovery.reloadManifest(id: "hot-swap", in: root)?.steps.first?.prompt,
            "second {{text}}")
    }

    /// A reload applies the SAME rules the listing applied: a folder cannot be run under
    /// looser validation than it was listed under.
    func testReloadRefusesAMismatchedOrHostileID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginReloadTests-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("honest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"id":"someone-else","name":"Liar","symbol":"star","entry":"script",
         "steps":[{"type":"insertAtCursor"}]}
        """.write(to: dir.appendingPathComponent("manifest.json"),
                  atomically: true, encoding: .utf8)

        // The directory name is the authority on identity.
        XCTAssertNil(PluginDiscovery.reloadManifest(id: "honest", in: root))
        // And a traversal-shaped id never reaches a file API at all.
        XCTAssertNil(PluginDiscovery.reloadManifest(id: "..", in: root))
        XCTAssertNil(PluginDiscovery.reloadManifest(id: "../honest", in: root))
        XCTAssertNil(PluginDiscovery.reloadManifest(id: "missing", in: root))
    }

    func testPluginDirectoryIsTheIDUnderTheRoot() {
        let root = URL(fileURLWithPath: "/plugins", isDirectory: true)
        XCTAssertEqual(
            PluginDiscovery.pluginDirectory(id: "demo", in: root).path,
            "/plugins/demo")
    }

    func testSafePathComponentMatchesTheIDRule() {
        XCTAssertTrue(PluginManifest.isSafePathComponent("commit-message"))
        XCTAssertTrue(PluginManifest.isSafePathComponent("app.openwhisp.demo"))
        for bad in ["", "..", ".", "../evil", "foo/bar", "Foo", "a\\b", "foo bar"] {
            XCTAssertFalse(
                PluginManifest.isSafePathComponent(bad),
                "expected \(bad) to be refused as a path component")
        }
    }

    // MARK: - The whole drop-in path

    /// The end-to-end property the tier exists for, driven through the SAME functions
    /// the app calls: copy a folder into the plugins directory, and it is discovered,
    /// enableable, active, routable by voice, and resolvable into a runnable plan —
    /// with no rebuild and no relaunch.
    ///
    /// Written as one test on purpose. Each half passing in isolation is exactly how
    /// this repo has previously shipped a green suite over a broken chain: the pieces
    /// were fine and nothing connected them.
    func testAFolderDroppedInIsDiscoveredEnabledRoutedAndRunnable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDropInTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. The user copies the example plugin into the plugins folder.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repoRoot.appendingPathComponent("Tests/Fixtures/Plugins/commit-message"),
            to: root.appendingPathComponent("commit-message"))

        // 2. Discovery finds it — the provider re-reads disk, so no relaunch.
        let discovered = PluginDiscovery.merge(providers: [
            .init(source: .builtIn) { [] },
            .init(source: .external) { PluginDiscovery.loadExternalManifests(in: root) },
        ])
        XCTAssertEqual(discovered.map(\.id), ["commit-message"])
        XCTAssertTrue(discovered[0].isRunnable, "a dropped-in script plugin must be runnable")

        // 3. Enabling it makes it active — the list the menu bar and the voice router
        //    both consume.
        var enablement = PluginEnablement()
        XCTAssertEqual(enablement.activePlugins(from: discovered).count, 0, "default-off")
        enablement.setEnabled(true, for: "commit-message")
        let active = enablement.activePlugins(from: discovered)
        XCTAssertEqual(active.map(\.id), ["commit-message"])

        // 4. A spoken instruction routes to it.
        let match = PluginVoiceCommandRouter.match(
            instruction: "write a commit message fixed the parser crash",
            enabledPlugins: active.map(\.manifest))
        XCTAssertEqual(match?.pluginID, "commit-message")
        XCTAssertEqual(match?.remainder, "fixed the parser crash")

        // 5. The runner re-reads the manifest from disk and resolves a plan. It runs a
        //    script, so it is refused until the user grants that separate consent…
        let reloaded = try XCTUnwrap(
            PluginDiscovery.reloadManifest(id: "commit-message", in: root))
        XCTAssertEqual(
            PluginScriptPlan.resolve(manifest: reloaded, hasScriptConsent: false),
            .failure(.scriptConsentRequired))

        // …and runs once granted.
        guard case let .success(resolved) = PluginScriptPlan.resolve(
            manifest: reloaded, hasScriptConsent: true)
        else { return XCTFail("expected the dropped-in plugin to resolve") }
        XCTAssertEqual(resolved.steps.map(\.kind), [.llm, .runScript, .insertAtCursor])
        XCTAssertTrue(resolved.deliversAtCursor)

        // 6. Its script really resolves inside its own copied folder.
        let dir = PluginDiscovery.pluginDirectory(id: "commit-message", in: root)
        let scriptURL = try XCTUnwrap(
            PluginScriptPath.resolve(resolved.steps[1].script, in: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
    }

    // MARK: - The shipped example plugin

    /// The checked-in example must actually resolve. It is the fixture a starter pack
    /// builds on and the thing a user copies, so a broken one teaches a broken schema.
    func testTheCheckedInExamplePluginResolves() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenWhispCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = repoRoot.appendingPathComponent(
            "Tests/Fixtures/Plugins/commit-message/manifest.json")

        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: try Data(contentsOf: url))

        XCTAssertEqual(manifest.id, "commit-message")
        XCTAssertEqual(manifest.entry, .script)
        XCTAssertTrue(manifest.isValid)
        // It declares voice triggers, so the router can reach it like any other plugin.
        XCTAssertFalse(manifest.normalizedVoiceTriggers.isEmpty)

        guard case let .success(resolved) = plan(manifest) else {
            return XCTFail("the shipped example plugin must resolve: \(String(describing: failure(manifest)))")
        }
        XCTAssertTrue(resolved.deliversAtCursor)
    }

    /// The example's script sits inside its own folder and exists on disk — the fixture
    /// proves the containment rule against a real directory, not just a string.
    func testTheCheckedInExampleScriptResolvesInsideItsOwnFolder() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repoRoot.appendingPathComponent("Tests/Fixtures/Plugins/commit-message")

        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: try Data(contentsOf: dir.appendingPathComponent("manifest.json")))

        let scriptSteps = manifest.steps.filter { $0.kind == .runScript }
        XCTAssertFalse(scriptSteps.isEmpty, "the example should exercise the script step")

        for step in scriptSteps {
            guard let resolved = PluginScriptPath.resolve(step.script, in: dir) else {
                return XCTFail("example script \(step.script ?? "nil") did not resolve")
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: resolved.path),
                "example script missing on disk at \(resolved.path)")
            XCTAssertTrue(resolved.path.hasPrefix(dir.standardizedFileURL.path + "/"))
        }
    }
}
