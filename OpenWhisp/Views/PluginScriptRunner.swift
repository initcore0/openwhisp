import AppKit

/// The app-side executor for a script plugin (docs/PLUGINS.md § "Path to hot-swappable"
/// §1). Takes a plan `PluginScriptPlan.resolve` already validated and performs each
/// step's IO — and nothing else.
///
/// ## It adds no new capability
///
/// Every step maps onto delivery code that already ships, exactly the way
/// `RuleEngineRunner` maps `RuleAction`s:
///
///   - `llm`            → `AppState.summarizeResolved` (the refine/summarize plumbing)
///   - `writeFile`      → `FileOutputTarget` (MAK-12)
///   - `runScript`      → `ScriptRunner` (the hardened stdin→stdout subprocess)
///   - `insertAtCursor` → the app's `TextOutput` inserter
///
/// So a script plugin can only compose things the user already consented to, which is
/// what makes the tier reviewable by reading a JSON file rather than auditing code.
///
/// ## Every decision is upstream
///
/// This file has no branches worth testing: which steps run, in what order, whether a
/// script path is allowed, and whether consent was granted are all settled by
/// `PluginScriptPlan` before a plan exists. That is deliberate — the app layer is
/// outside `swift test`, and this repo has shipped a green suite over dead wiring more
/// than once. If a rule shows up here, it belongs in core instead.
///
/// **Fail-soft, like every other side channel in the app.** A step that fails ends the
/// pipeline with a status message; it never crashes, never blocks dictation, and never
/// inserts a half-finished result.
@MainActor
enum PluginScriptRunner {

    /// How a run ended, for the status line.
    enum Outcome: Equatable {
        /// The pipeline completed. `text` is the final result (already delivered by any
        /// terminal step that wanted it).
        case completed(text: String)
        /// The pipeline stopped. `reason` is user-facing.
        case failed(reason: String)
    }

    /// Resolve a plugin from disk and run it over `material`.
    ///
    /// The manifest is re-read HERE rather than taken from the host's listing, so
    /// editing `manifest.json` and invoking the plugin again picks up the edit with no
    /// reload, relaunch, or rebuild. That is the hot-swap promise, and serving a cached
    /// manifest is the specific bug this project has already shipped once.
    static func run(
        pluginID: String,
        material: String,
        directoryRoot: URL,
        hasScriptConsent: Bool,
        completion: @escaping (Outcome) -> Void
    ) {
        guard let manifest = PluginDiscovery.reloadManifest(id: pluginID, in: directoryRoot) else {
            completion(.failed(reason: "Couldn't read this plugin's manifest.json."))
            return
        }

        switch PluginScriptPlan.resolve(manifest: manifest, hasScriptConsent: hasScriptConsent) {
        case .failure(let failure):
            completion(.failed(reason: failure.reason))
        case .success(let plan):
            let directory = PluginDiscovery.pluginDirectory(id: pluginID, in: directoryRoot)
            perform(
                plan.steps[...], input: material, directory: directory, completion: completion)
        }
    }

    /// Run the remaining steps, threading each one's output into the next.
    ///
    /// Recursive over an `ArraySlice` rather than a loop because two of the four steps
    /// are asynchronous (the LLM call, the file write), and a loop would have to
    /// re-invent the continuation this gives for free. Each step either produces the
    /// next input or ends the run.
    private static func perform(
        _ steps: ArraySlice<PluginStep>,
        input: String,
        directory: URL,
        completion: @escaping (Outcome) -> Void
    ) {
        guard let step = steps.first else {
            completion(.completed(text: input))
            return
        }
        let rest = steps.dropFirst()
        let next = { (output: String) in
            perform(rest, input: output, directory: directory, completion: completion)
        }

        switch step.kind {
        case .llm:
            runLLM(prompt: step.prompt ?? "", input: input, next: next, completion: completion)

        case .runScript:
            runScript(step.script, input: input, directory: directory,
                      next: next, completion: completion)

        case .writeFile:
            writeFile(step.file, text: input, next: next, completion: completion)

        case .insertAtCursor:
            // A step that DELIVERS rather than transforms: the text passes through
            // unchanged so a pipeline can insert and then keep going (e.g. also append
            // to a log).
            insertAtCursor(input)
            next(input)

        case .unsupported(let name):
            // Unreachable: `PluginScriptPlan.resolve` refuses an unsupported step before
            // a plan exists. Handled rather than force-unwrapped so a future refactor
            // that loosens resolution degrades to an honest message, not a crash.
            completion(.failed(reason: PluginScriptPlan.Failure.unsupportedStep(name).reason))
        }
    }

    // MARK: - Steps

    /// The `llm` step. Reuses `AppState.summarizeResolved` — the same entry point the
    /// Scratchpad and the meme plugin call — so a script plugin reaches exactly the
    /// model the user configured and cannot introduce an endpoint of its own.
    private static func runLLM(
        prompt: String,
        input: String,
        next: @escaping (String) -> Void,
        completion: @escaping (Outcome) -> Void
    ) {
        let resolved = ScratchpadWindowController.resolvedAIModel()
        guard ScratchpadAIModel.isUsable(resolved) else {
            completion(.failed(reason: ScratchpadAIModel.unusableProviderMessage))
            return
        }

        // The whole expanded template is the INSTRUCTION and the text rides along as the
        // payload, matching how `InstructionChain` frames every other refine: the
        // manifest's prompt is an instruction about the text, not a replacement for the
        // host's system directive (which still carries the prompt-injection guard).
        let instruction = PluginScriptPlan.expandPrompt(prompt, text: input)

        AppState.shared.warmLlamaServerIfPossible(provider: resolved.provider) { _ in
            AppState.shared.summarizeResolved(
                text: input, instruction: instruction, resolved: resolved
            ) { result in
                switch result {
                case .success(let output):
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    // An empty model reply ends the run rather than passing "" down the
                    // pipeline, where a later step would happily write an empty file or
                    // paste nothing over the user's selection.
                    guard !trimmed.isEmpty else {
                        completion(.failed(reason: "The model returned nothing."))
                        return
                    }
                    next(trimmed)
                case .failure(let error):
                    completion(.failed(reason: error.localizedDescription))
                }
            }
        }
    }

    /// The `runScript` step. The path is re-resolved against the plugin's own directory
    /// HERE — `PluginScriptPath.resolve` is the only thing that turns a declared script
    /// name into a URL, so a call site cannot bypass the containment rule by joining the
    /// path itself.
    private static func runScript(
        _ declared: String?,
        input: String,
        directory: URL,
        next: @escaping (String) -> Void,
        completion: @escaping (Outcome) -> Void
    ) {
        guard let url = PluginScriptPath.resolve(declared, in: directory) else {
            completion(.failed(
                reason: PluginScriptPath.validate(declared)?.reason
                    ?? "This plugin's script path isn't usable."))
            return
        }
        // A directory is "executable" (traversable) to `isExecutableFile`, so check for
        // one first — otherwise it reaches `ScriptRunner`, fails to launch, and the
        // failure wears a misleading message.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            completion(.failed(reason: "The plugin's script \(url.lastPathComponent) is missing."))
            return
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            completion(.failed(
                reason: "The plugin's script isn't executable — run: chmod +x \(url.path)"))
            return
        }

        // Off the main thread: `ScriptRunner` is synchronous with a bounded timeout, and
        // a plugin script must never freeze the UI while it runs.
        DispatchQueue.global(qos: .userInitiated).async {
            // `ScriptRunner.run` collapses every failure into "the original text" —
            // right for the dictation finalize path, where the user's words must
            // survive a broken script, and WRONG here. The user asked for a transform;
            // silently passing the untransformed text on would paste the wrong thing
            // and report success. So drive the same subprocess through the pure
            // `ScriptOutcome` resolver and keep the distinction.
            let outcome = ScriptRunner.outcome(for: input, scriptPath: url.path)
            DispatchQueue.main.async {
                switch outcome {
                case .useOutput(let output):
                    next(output)
                case .keepOriginal(let reason):
                    completion(.failed(
                        reason: PluginScriptPlan.Failure.scriptStepFailed(reason: reason).reason))
                }
            }
        }
    }

    /// The `writeFile` step. Hands the text to `FileOutputTarget`, so a plugin's file
    /// write is byte-identical to the one Settings → Files already performs — same
    /// heading tokens, same append separator, same directory creation.
    private static func writeFile(
        _ config: FileOutputConfig?,
        text: String,
        next: @escaping (String) -> Void,
        completion: @escaping (Outcome) -> Void
    ) {
        guard let config else {
            completion(.failed(reason: "This plugin's file step names no path."))
            return
        }
        FileOutputTarget(config: config).deliver(
            OutputPayload(
                text: text, language: "auto", targetAppBundleID: nil, isLiveChunk: false)
        ) { delivery in
            // Hop to main explicitly rather than asserting the sink's queue. The write
            // path does call back on `.main`, but `deliver`'s live-chunk early return
            // completes SYNCHRONOUSLY on the caller's queue — so an assertion here
            // would be a crash contingent on an argument, which is not the kind of
            // guarantee to build on. `async` on main from main is a cheap hop.
            DispatchQueue.main.async {
                switch delivery {
                case .delivered:
                    // The text passes through unchanged: writing a file is a side
                    // effect, not a transformation.
                    next(text)
                case .failedFallback(let reason):
                    completion(.failed(reason: "Couldn't write the file — \(reason)"))
                }
            }
        }
    }

    /// The `insertAtCursor` step: the plugin's output goes where a dictation would.
    ///
    /// This is the minimal output path a script plugin needs, since it has no window of
    /// its own. It is NOT a declarative UI system — docs/PLUGINS.md scopes this tier to
    /// "text and actions, weak for custom UI" on purpose.
    ///
    /// Goes through `TextInserter` (the app's own `TextOutput`) rather than adding a
    /// method to `AppState`: the MAK-32 ratchet is at zero headroom, and this needs
    /// none of AppState's session state — a plugin insert is a one-shot delivery, not a
    /// live chunk with clipboard-carry semantics.
    private static func insertAtCursor(_ text: String) {
        guard !text.isEmpty else { return }
        // A password field is the one place text must never land, and the check is
        // fail-open exactly as it is on the dictation path.
        guard !SecureFieldDetector.focusedFieldIsSecure() else { return }
        inserter.insert(
            text, mode: .paste,
            restoreClipboard: AppState.shared.restoreClipboard,
            completion: nil)
    }

    /// One inserter for the app's lifetime — it keeps the pasteboard-restore bookkeeping
    /// that makes a paste safe, and a fresh instance per step would discard it.
    private static let inserter = TextInserter()
}
