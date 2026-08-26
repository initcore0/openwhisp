import Foundation

/// The **script plugin** step schema and its plan resolver — the first shipped tier of
/// docs/PLUGINS.md § "Path to hot-swappable".
///
/// ## What a script plugin is
///
/// A manifest dropped into `~/Library/Application Support/OpenWhisp/Plugins/<id>/`
/// that declares `"entry": "script"` plus a linear pipeline of steps the HOST executes
/// over one input string. No third-party code runs in-process: every step is one of a
/// small, fixed set of actions the host already performs for the user elsewhere
/// (the refine LLM, `FileOutputTarget`, `ScriptRunner`, the text inserter). A plugin
/// can only COMPOSE capabilities the user already consented to — which is precisely
/// what makes this tier reviewable by reading a JSON file.
///
/// ## Why the whole decision lives here
///
/// Everything in this file is a pure function of the manifest: which steps exist, in
/// what order, which ones need consent, what an unknown step means, and which errors
/// are fatal. The app layer (`PluginScriptRunner`) does nothing but perform the IO for
/// an already-resolved plan. That split is not stylistic — `plugins/` and the app glob
/// sit OUTSIDE `swift test`, and this repo has shipped a green suite over dead wiring
/// three times. If a rule can be unit-tested, it is in this file.
///
/// Foundation-only, registered in `Package.swift`'s `OpenWhispCore` sources.

// MARK: - Step kinds

/// The action a single step performs. Deliberately SMALL: four verbs, each mapping
/// onto delivery code the app already ships and the user already understands.
///
/// This enum is *closed* in the sense that the host implements exactly these — but a
/// manifest may name something else entirely (a step type from a future OpenWhisp), and
/// that must not be a crash. See `PluginStep.Kind.unsupported`.
public enum PluginStepKind: Equatable, Sendable {

    /// Transform the text with the app's own local LLM, using a prompt the manifest
    /// supplies. Reuses the refine plumbing wholesale — a script plugin gets no LLM
    /// client of its own, no endpoint of its own, and no way to reach a model the user
    /// hasn't already configured.
    case llm

    /// Append or overwrite a file the manifest names. The path is disclosed to the user
    /// BEFORE they enable the plugin, because this is the one step that leaves a
    /// permanent artifact somewhere the user didn't look.
    case writeFile

    /// Run a shell script bundled inside the plugin's OWN directory, transcript on
    /// stdin, replacement text on stdout — the `ScriptRunner` contract exactly.
    ///
    /// This is the only step that executes code, so it carries its own separate consent
    /// (see `PluginConsent`). "Enabled" is not enough.
    case runScript

    /// Insert the result at the user's cursor in the frontmost app, the same path a
    /// dictation takes. The terminal step for a plugin with no window of its own.
    case insertAtCursor

    /// A step type this build does not implement — a manifest written for a NEWER
    /// OpenWhisp. Carried (with its raw name) rather than dropped so the pane can say
    /// honestly *why* the plugin won't run, instead of the plugin silently vanishing or,
    /// worse, running a truncated pipeline that skips the step it didn't understand.
    case unsupported(String)

    /// The wire name, for round-tripping and for the pane's error text.
    public var rawValue: String {
        switch self {
        case .llm: return "llm"
        case .writeFile: return "writeFile"
        case .runScript: return "runScript"
        case .insertAtCursor: return "insertAtCursor"
        case .unsupported(let name): return name
        }
    }

    /// Decode a wire name, mapping anything unrecognized to `.unsupported`.
    ///
    /// NEVER throws. A future step type must degrade to a *listed, refused* plugin
    /// rather than a decode failure that erases the whole manifest from the pane —
    /// docs/PLUGINS.md's forward-compatibility rule, applied to the step list.
    public init(rawValue: String) {
        switch rawValue {
        case "llm": self = .llm
        case "writeFile": self = .writeFile
        case "runScript": self = .runScript
        case "insertAtCursor": self = .insertAtCursor
        default: self = .unsupported(rawValue)
        }
    }

    /// Whether this build can actually perform the step.
    public var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

// MARK: - Step

/// One step in a script plugin's pipeline.
///
/// Steps compose LINEARLY: the output of each is the input of the next, starting from
/// the invocation material (the dictation, the refine selection, or the spoken
/// remainder). A step that produces no text of its own (`writeFile`, `insertAtCursor`)
/// passes its input straight through, so a pipeline can write a file *and* keep going.
///
/// All fields but `type` are optional in JSON, per the schema's standing rule: a
/// manifest already on a user's disk must survive an app update that adds a field.
public struct PluginStep: Equatable, Sendable, Codable {

    /// What this step does.
    public let kind: PluginStepKind

    /// `llm` only — the prompt template. `{{text}}` is replaced with the step's input;
    /// a template with no token gets the input appended, so a bare instruction
    /// ("Rewrite this as a git commit message") works without ceremony.
    public let prompt: String?

    /// `writeFile` only — where to write, how to wrap the entry, and append vs
    /// overwrite. Reuses `FileOutputConfig` so a script plugin writes files through
    /// exactly the code path the Settings-configured file target already uses; there is
    /// no second file writer to review.
    public let file: FileOutputConfig?

    /// `runScript` only — the script's filename RELATIVE to the plugin's own directory
    /// (e.g. `"format.sh"`). Never an absolute path and never a traversal; see
    /// `PluginScriptPath` for the rule and why it is enforced in core.
    public let script: String?

    public init(
        kind: PluginStepKind,
        prompt: String? = nil,
        file: FileOutputConfig? = nil,
        script: String? = nil
    ) {
        self.kind = kind
        self.prompt = prompt
        self.file = file
        self.script = script
    }

    private enum CodingKeys: String, CodingKey { case type, prompt, file, script }

    /// Forward-compatible decode. An unknown `type` becomes `.unsupported(name)`
    /// instead of throwing — the difference between "this plugin is listed and refuses
    /// to run, here's why" and "this plugin disappeared".
    ///
    /// A MISSING `type` is the one genuinely fatal case: a step that doesn't say what it
    /// does can't be defaulted to anything safe (every default would be a guess at an
    /// action with side effects), so the step list fails to decode and the plugin is
    /// listed as broken rather than partially run.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = PluginStepKind(rawValue: try container.decode(String.self, forKey: .type))
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        file = try? container.decodeIfPresent(FileOutputConfig.self, forKey: .file)
        script = try container.decodeIfPresent(String.self, forKey: .script)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(script, forKey: .script)
    }
}

// MARK: - Script path safety

/// The rule for where a script plugin's executable may live: INSIDE the plugin's own
/// directory, named by a relative path with no traversal.
///
/// The same reasoning as `PluginManifest`'s id validation, and enforced with the same
/// seriousness. The plugins directory is user-writable, and the app holds Accessibility,
/// microphone, and clipboard rights — a manifest that could name `/usr/bin/osascript`,
/// or climb out with `../../`, would turn "drop a JSON file in a folder" into arbitrary
/// local execution against an entitled process. The plugin directory is the boundary,
/// so the path is resolved and re-checked against it rather than merely pattern-matched.
public enum PluginScriptPath {

    /// Why a declared script path was refused.
    public enum Failure: Equatable, Sendable {
        case empty
        /// An absolute path (`/bin/sh`, `~/evil.sh`). The plugin directory is the only
        /// place a script may live.
        case absolute(String)
        /// A path that climbs out of the plugin directory (`../`, or any component that
        /// resolves outside it).
        case escapesPluginDirectory(String)

        public var reason: String {
            switch self {
            case .empty:
                return "This plugin declares a script step with no script file."
            case .absolute(let path):
                return "Scripts must live inside the plugin's own folder — “\(path)” is an absolute path."
            case .escapesPluginDirectory(let path):
                return "Scripts must live inside the plugin's own folder — “\(path)” points outside it."
            }
        }
    }

    /// Validate a declared script path WITHOUT touching the filesystem.
    ///
    /// Two layers, deliberately. The cheap syntactic checks (empty, leading `/` or `~`,
    /// a `..` component) reject the obvious shapes, and then the path is resolved
    /// against a nominal plugin directory and confirmed to still be under it — which
    /// catches the combinations a component-wise check alone misses (`a/../../b`).
    /// Filesystem existence is the APP's problem; this is the rule, and it is pure so
    /// `swift test` owns it.
    public static func validate(_ raw: String?) -> Failure? {
        let path = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return .empty }
        if path.hasPrefix("/") || path.hasPrefix("~") { return .absolute(path) }
        let components = path.components(separatedBy: "/")
        if components.contains("..") { return .escapesPluginDirectory(path) }
        // Resolve against a sentinel root and confirm containment. `standardized`
        // collapses `.`/`..` the way the filesystem would, so a path that only *looks*
        // contained is caught here.
        let root = URL(fileURLWithPath: "/__plugin__", isDirectory: true)
        let resolved = root.appendingPathComponent(path).standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            return .escapesPluginDirectory(path)
        }
        return nil
    }

    /// The absolute URL a validated script resolves to inside `pluginDirectory`, or nil
    /// when the declared path is refused.
    ///
    /// The app calls THIS rather than joining the path itself — the one place a plugin's
    /// script path becomes a URL, so the containment rule cannot be bypassed by a call
    /// site that forgot to validate first.
    public static func resolve(_ raw: String?, in pluginDirectory: URL) -> URL? {
        guard validate(raw) == nil,
              let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let root = pluginDirectory.standardizedFileURL
        let resolved = root.appendingPathComponent(path).standardizedFileURL
        // Re-check containment against the REAL directory: `resolve` must not trust
        // `validate`'s sentinel root to have covered a symlinked or oddly-cased root.
        guard resolved.path.hasPrefix(root.path + "/") else { return nil }
        return resolved
    }
}

// MARK: - Consent

/// What the user is agreeing to when they enable a script plugin, and which parts need
/// an agreement of their own.
///
/// The host owns every capability, so the pane must be able to state — before the
/// toggle is flipped — exactly what the plugin will do. That statement is built HERE, as
/// a pure function of the manifest, for the same reason `networkDisclosure` is: a
/// privacy-facing string the view could quietly reword is not a disclosure.
public struct PluginConsent: Equatable, Sendable {

    /// Absolute-ish paths (as declared) this plugin writes to.
    public let filePaths: [String]
    /// Script filenames this plugin executes, in step order.
    public let scriptNames: [String]
    /// Whether any step inserts text into the frontmost app.
    public let insertsAtCursor: Bool
    /// Whether any step calls the local LLM.
    public let usesLLM: Bool

    public init(
        filePaths: [String] = [],
        scriptNames: [String] = [],
        insertsAtCursor: Bool = false,
        usesLLM: Bool = false
    ) {
        self.filePaths = filePaths
        self.scriptNames = scriptNames
        self.insertsAtCursor = insertsAtCursor
        self.usesLLM = usesLLM
    }

    /// Whether running this plugin executes a shell script — the one capability that
    /// needs its OWN consent, distinct from the enable toggle.
    ///
    /// Everything else in this list composes host actions over the user's own text.
    /// A script is arbitrary code running with the app's full rights, so "I turned this
    /// plugin on" is not the same statement as "I have read this script and agree it may
    /// run". Conflating the two is how a plugin folder becomes an execution vector.
    public var requiresScriptConsent: Bool { !scriptNames.isEmpty }

    /// Derive the consent facts from a manifest. Steps are inspected in order so the
    /// pane lists paths and scripts the way they will actually run.
    public static func derive(from manifest: PluginManifest) -> PluginConsent {
        var filePaths: [String] = []
        var scriptNames: [String] = []
        var insertsAtCursor = false
        var usesLLM = false

        for step in manifest.steps {
            switch step.kind {
            case .llm:
                usesLLM = true
            case .writeFile:
                if let path = step.file?.path.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty, !filePaths.contains(path) {
                    filePaths.append(path)
                }
            case .runScript:
                if let name = step.script?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty, !scriptNames.contains(name) {
                    scriptNames.append(name)
                }
            case .insertAtCursor:
                insertsAtCursor = true
            case .unsupported:
                continue
            }
        }

        return PluginConsent(
            filePaths: filePaths, scriptNames: scriptNames,
            insertsAtCursor: insertsAtCursor, usesLLM: usesLLM)
    }

    /// The disclosure lines the Plugins pane renders before the enable toggle, in the
    /// order they should appear: the irreversible/most surprising first.
    ///
    /// Pinned by `swift test` so the exact words the user consents to cannot drift with
    /// a view refactor.
    public var disclosures: [String] {
        var lines: [String] = []
        if !scriptNames.isEmpty {
            lines.append(
                "Runs the bundled script \(scriptNames.joined(separator: ", ")) on your Mac.")
        }
        if !filePaths.isEmpty {
            lines.append("Writes to \(filePaths.joined(separator: ", ")).")
        }
        if insertsAtCursor {
            lines.append("Types its result into whatever app you're using.")
        }
        if usesLLM {
            lines.append("Sends the text to your configured OpenWhisp model.")
        }
        return lines
    }

    /// The sentence shown beside the SEPARATE script-consent checkbox. Distinct wording
    /// from the disclosure line above on purpose: one describes, this one asks.
    public var scriptConsentPrompt: String? {
        guard requiresScriptConsent else { return nil }
        return "Allow this plugin to run \(scriptNames.joined(separator: ", ")) on your Mac."
    }
}

// MARK: - Plan resolution

/// Turns a manifest into either an executable plan or an honest refusal.
///
/// This is the single function the app calls before running anything, and the single
/// function the tests drive. There is no second path into execution.
public enum PluginScriptPlan {

    /// Why a script plugin cannot run. Every case is a user-facing sentence, because
    /// every one of them shows up in the pane rather than in a log the user never reads.
    public enum Failure: Error, Equatable, Sendable {
        /// The manifest isn't a script plugin at all.
        case notAScriptPlugin
        /// `"entry": "script"` with no steps. Nothing to do, and silently succeeding
        /// would look identical to a plugin that worked.
        case noSteps
        /// A step this build doesn't implement — a manifest from a newer OpenWhisp. The
        /// plugin is LISTED; it just refuses to run a pipeline it can't perform in full.
        case unsupportedStep(String)
        /// A step declared an unusable script path.
        case invalidScriptPath(PluginScriptPath.Failure)
        /// An `llm` step with no prompt.
        case missingPrompt(stepIndex: Int)
        /// A `writeFile` step with no path.
        case missingFilePath(stepIndex: Int)
        /// The plugin runs a script and the user hasn't granted that separate consent.
        case scriptConsentRequired

        public var reason: String {
            switch self {
            case .notAScriptPlugin:
                return "This plugin isn't a script plugin."
            case .noSteps:
                return "This plugin declares no steps, so there's nothing to run."
            case .unsupportedStep(let name):
                return "This plugin needs a newer version of OpenWhisp — it uses a “\(name)” step this version doesn't support."
            case .invalidScriptPath(let failure):
                return failure.reason
            case .missingPrompt(let index):
                return "Step \(index + 1) asks the model to rewrite the text but supplies no prompt."
            case .missingFilePath(let index):
                return "Step \(index + 1) writes a file but names no path."
            case .scriptConsentRequired:
                return "This plugin runs a script — allow it in Settings → Plugins first."
            }
        }
    }

    /// A validated, ready-to-execute pipeline.
    public struct Plan: Equatable, Sendable {
        public let pluginID: String
        /// The steps to run, in order. Guaranteed non-empty and fully supported.
        public let steps: [PluginStep]
        /// What the user was told this plugin does.
        public let consent: PluginConsent

        public init(pluginID: String, steps: [PluginStep], consent: PluginConsent) {
            self.pluginID = pluginID
            self.steps = steps
            self.consent = consent
        }

        /// Whether the pipeline ends by putting text into the user's app. A plugin whose
        /// last step is a file write has already delivered its output and must NOT also
        /// paste — the runner asks this rather than inferring it.
        public var deliversAtCursor: Bool {
            steps.contains { $0.kind == .insertAtCursor }
        }
    }

    /// Resolve a manifest into a plan, or say why not.
    ///
    /// - Parameters:
    ///   - manifest: the manifest as read from disk THIS invocation. The runner passes a
    ///     freshly-read manifest rather than one cached at enable-time, so editing
    ///     `manifest.json` and re-running picks up the edit — the stale-cache bug this
    ///     repo has already shipped once.
    ///   - hasScriptConsent: whether the user granted the separate script permission.
    ///     Checked LAST so a plugin with an otherwise-broken pipeline reports the real
    ///     problem instead of nagging for a consent that wouldn't help.
    public static func resolve(
        manifest: PluginManifest,
        hasScriptConsent: Bool
    ) -> Result<Plan, Failure> {
        guard manifest.entry == .script else { return .failure(.notAScriptPlugin) }
        guard !manifest.steps.isEmpty else { return .failure(.noSteps) }

        for (index, step) in manifest.steps.enumerated() {
            switch step.kind {
            case .unsupported(let name):
                return .failure(.unsupportedStep(name))
            case .llm:
                let prompt = step.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if prompt.isEmpty { return .failure(.missingPrompt(stepIndex: index)) }
            case .writeFile:
                let path = step.file?.path.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if path.isEmpty { return .failure(.missingFilePath(stepIndex: index)) }
            case .runScript:
                if let failure = PluginScriptPath.validate(step.script) {
                    return .failure(.invalidScriptPath(failure))
                }
            case .insertAtCursor:
                continue
            }
        }

        let consent = PluginConsent.derive(from: manifest)
        if consent.requiresScriptConsent, !hasScriptConsent {
            return .failure(.scriptConsentRequired)
        }

        return .success(Plan(pluginID: manifest.id, steps: manifest.steps, consent: consent))
    }

    /// Expand an `llm` step's prompt template against the step's input.
    ///
    /// `{{text}}` is the token, matching the `{{…}}` convention `FileOutputConfig` and
    /// `RuleAction.openURL` already use. A template WITHOUT the token gets the input
    /// appended after a blank line, so `"Rewrite this as a commit message"` behaves the
    /// way a user who never read the docs would expect.
    public static func expandPrompt(_ template: String, text: String) -> String {
        guard template.contains("{{text}}") else {
            return template.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + text
        }
        return template.replacingOccurrences(of: "{{text}}", with: text)
    }
}
