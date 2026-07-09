import Foundation

/// Pure command-building + outcome logic for the **agent-CLI enhancement
/// provider**: pipe the transcript through a locally-installed coding-agent CLI
/// (`claude -p …`, `codex`, `pi`, …) and use its cleaned-up stdout as the refined
/// text. It's the inverse of Agent Bridge — instead of exposing dictation *to*
/// agents, this consumes an agent *as the refine engine*, reusing the auth /
/// subscription the developer already pays for (no separate API key).
///
/// This type is deliberately platform-free (pure Foundation) so the surprising,
/// security-sensitive parts — how the argv is assembled and exactly when we
/// discard the CLI output — are unit-tested and pinned. The actual process spawn
/// + timeout is app-side glue (`AgentCLIRunner`, build.sh) built on the same
/// `ScriptRunner`/`Process` seam.
///
/// ## Injection safety (read this before touching `buildArgv`)
/// The **transcript is NEVER interpolated into a shell string or placed in the
/// argv** — it is fed to the child on **stdin**. The argv is assembled as a
/// discrete `[String]` (executable + fixed args) and handed to `Process` /
/// `posix_spawn` directly, so there is no shell to expand `$(…)`, backticks,
/// `;`, quotes, or glob characters. The user's dictated words therefore cannot
/// become part of the command, no matter what they say. Only the operator-chosen
/// `command` + `args` template ever reach argv, and the `{transcript}` sentinel
/// (see below) is explicitly rejected there so a template can't smuggle the
/// transcript into argv either.
public enum AgentCLIProvider {

    // MARK: - Config

    /// One agent-CLI provider, as data: which executable to run, the fixed
    /// argument template to pass it, and the hard timeout. The transcript is
    /// supplied separately (on stdin) — it is intentionally not part of this
    /// config, so it can never be templated into the command.
    public struct Config: Equatable, Codable {
        /// Executable to run. Either a bare name resolved on `PATH`
        /// (e.g. `"claude"`) or an absolute path (e.g. `"/opt/homebrew/bin/claude"`).
        public let command: String
        /// Fixed argument template passed verbatim before the transcript is piped
        /// in on stdin — e.g. `["-p", "Clean up this dictation: fix punctuation…"]`.
        /// These are operator-configured, never derived from the transcript.
        public let args: [String]
        /// Hard wall-clock budget for the CLI. On overrun we kill it and fail open
        /// to the original transcript.
        public let timeout: TimeInterval

        public init(command: String, args: [String], timeout: TimeInterval = 30.0) {
            self.command = command
            self.args = args
            self.timeout = timeout
        }
    }

    /// A built, ready-to-spawn command: the resolved executable plus the exact
    /// argv (args only — the transcript goes on stdin, so it is never here).
    public struct Command: Equatable {
        /// The executable to launch (bare name or absolute path, as configured).
        public let executable: String
        /// The full argv **excluding** the executable itself — i.e. just the
        /// fixed args. The transcript is fed on stdin, never appended here.
        public let arguments: [String]

        public init(executable: String, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// Why `buildCommand` refused to assemble an argv (all fail closed — the app
    /// then keeps the original transcript, same fail-open contract as a runtime
    /// error).
    public enum BuildError: Error, Equatable {
        /// The configured `command` was empty/whitespace.
        case emptyCommand
        /// An `args` entry contained the `{transcript}` sentinel — refused because
        /// the transcript must go on stdin, never into argv (injection guard).
        case transcriptInArgs
    }

    /// The sentinel we explicitly forbid in `args`. Some tools template the input
    /// into the command line; OpenWhisp deliberately does NOT, and rejects any
    /// attempt to, so the transcript can only ever reach the child via stdin.
    public static let transcriptSentinel = "{transcript}"

    // MARK: - Argv builder (pure, injection-safe)

    /// Build the exact command to spawn from a provider config.
    ///
    /// The transcript is **not** a parameter here — that is the whole safety
    /// story: it is delivered on stdin by the runner, so it can never appear in
    /// argv and can never be interpreted by a shell. This function only validates
    /// and echoes the operator-chosen executable + fixed args.
    ///
    /// - Returns: the `Command` to run on success, or a `BuildError` if the
    ///   config is unusable (empty command, or an arg tried to template the
    ///   transcript into argv).
    public static func buildCommand(config: Config) -> Result<Command, BuildError> {
        let executable = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else { return .failure(.emptyCommand) }
        // Refuse any attempt to route the transcript through argv. We pass it on
        // stdin, full stop; a template containing the sentinel is a misconfig we
        // fail closed on rather than silently ignore.
        if config.args.contains(where: { $0.contains(transcriptSentinel) }) {
            return .failure(.transcriptInArgs)
        }
        return .success(Command(executable: executable, arguments: config.args))
    }

    // MARK: - Outcome resolution (pure, fail-open)

    /// What the provider decided to do with the CLI's result.
    ///
    /// **Fail-open by contract** — on any failure (timeout, non-zero exit, spawn
    /// error, or empty/whitespace output) the original transcript is kept, so a
    /// misbehaving or missing agent CLI can never drop or mangle the user's
    /// dictation.
    public enum Outcome: Equatable {
        /// Use the CLI's stdout as the refined text.
        case useOutput(String)
        /// Keep the original transcript, with a reason for the status line.
        case keepOriginal(reason: String)
    }

    /// Resolve the outcome from the raw result of running the CLI.
    ///
    /// Mirrors `ScriptOutcome.resolve` (same fail-open ordering and trimming) so
    /// the two subprocess-backed refine paths behave identically.
    ///
    /// - Parameters:
    ///   - original: the transcript fed to the CLI on stdin.
    ///   - stdout: the CLI's captured stdout (nil if it never produced any).
    ///   - exitCode: process exit status (nil if it never launched / was killed).
    ///   - timedOut: true if we killed it for exceeding the time budget.
    ///   - launchFailed: true if the process couldn't be started at all
    ///     (e.g. the CLI isn't installed / not on PATH).
    public static func resolve(
        original: String,
        stdout: String?,
        exitCode: Int32?,
        timedOut: Bool,
        launchFailed: Bool
    ) -> Outcome {
        if launchFailed {
            return .keepOriginal(reason: "Agent CLI couldn't run")
        }
        if timedOut {
            return .keepOriginal(reason: "Agent CLI timed out")
        }
        guard let exitCode else {
            return .keepOriginal(reason: "Agent CLI didn't finish")
        }
        guard exitCode == 0 else {
            return .keepOriginal(reason: "Agent CLI exited with code \(exitCode)")
        }
        // Trim only a single trailing newline (the conventional "echo" newline);
        // preserve any other whitespace the CLI intentionally emitted.
        let out = Self.stripOneTrailingNewline(stdout ?? "")
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .keepOriginal(reason: "Agent CLI returned empty output")
        }
        return .useOutput(out)
    }

    /// Resolve to the text to actually use (collapses both cases to a string).
    /// This is what the app-side runner returns to the finalize path.
    public static func resolvedText(
        original: String,
        stdout: String?,
        exitCode: Int32?,
        timedOut: Bool,
        launchFailed: Bool
    ) -> String {
        switch resolve(original: original, stdout: stdout, exitCode: exitCode,
                       timedOut: timedOut, launchFailed: launchFailed) {
        case .useOutput(let text): return text
        case .keepOriginal: return original
        }
    }

    private static func stripOneTrailingNewline(_ s: String) -> String {
        // In Swift, "\r\n" is a SINGLE extended grapheme cluster, so a single
        // dropLast handles both a lone "\n" and a CRLF correctly.
        guard let last = s.last, last == "\n" || last == "\r\n" else { return s }
        return String(s.dropLast())
    }
}

// MARK: - Presets

public extension AgentCLIProvider {
    /// A named, ready-to-use provider preset — the data behind the "which agent
    /// CLI?" picker. Users can start from one of these and tweak the args /
    /// timeout, or hand-roll a `.custom` template.
    struct Preset: Equatable, Identifiable {
        /// Stable id / slug (also the persisted selection key).
        public let id: String
        /// Human-facing name for the picker.
        public let name: String
        /// One-line description of what this preset runs.
        public let detail: String
        /// The default config (command + args + timeout). Editable by the user.
        public let config: Config

        public init(id: String, name: String, detail: String, config: Config) {
            self.id = id
            self.name = name
            self.detail = detail
            self.config = config
        }
    }

    /// The default refine instruction shipped with the CLI presets. Kept as a
    /// single constant so every preset that takes an instruction stays in sync.
    static let defaultRefineInstruction =
        "Clean up this dictated text: fix capitalization, punctuation, and obvious "
        + "transcription errors, and remove filler words. Preserve the meaning and "
        + "wording. Output ONLY the cleaned text with no preamble, commentary, or "
        + "code fences."

    /// Claude Code CLI in one-shot print mode: `claude -p "<instruction>"`, with
    /// the transcript piped on stdin.
    static var claude: Preset {
        Preset(
            id: "claude",
            name: "Claude Code",
            detail: "claude -p — reuse your Claude subscription as the cleanup engine",
            config: Config(
                command: "claude",
                args: ["-p", defaultRefineInstruction],
                timeout: 30.0
            )
        )
    }

    /// OpenAI Codex CLI in one-shot exec mode. `codex exec "<instruction>"` runs a
    /// single non-interactive turn; the transcript is piped on stdin.
    static var codex: Preset {
        Preset(
            id: "codex",
            name: "Codex",
            detail: "codex exec — reuse your Codex/OpenAI CLI as the cleanup engine",
            config: Config(
                command: "codex",
                args: ["exec", defaultRefineInstruction],
                timeout: 30.0
            )
        )
    }

    /// A generic starting point for any other CLI that reads stdin and writes the
    /// transformed text to stdout. Command + args are placeholders the user edits.
    static var custom: Preset {
        Preset(
            id: "custom",
            name: "Custom CLI",
            detail: "Any command that reads stdin and writes the cleaned text to stdout",
            config: Config(
                command: "",
                args: [],
                timeout: 30.0
            )
        )
    }

    /// All built-in presets, in picker order.
    static var presets: [Preset] { [claude, codex, custom] }

    /// Look up a preset by its stable id.
    static func preset(id: String) -> Preset? {
        presets.first { $0.id == id }
    }

    /// The persisted selection key for the *custom* preset — the one whose
    /// command/args come from the user's own fields rather than a built-in template.
    static let customPresetID = "custom"

    /// Resolve the effective, ready-to-run `Config` for the agent-CLI provider from
    /// the user's persisted choices.
    ///
    /// This is the single, testable place where "which preset + which custom fields"
    /// becomes "the exact command to run":
    ///   - a built-in preset id (`claude` / `codex`) yields that preset's shipped
    ///     `command` + `args`, but always with the user's chosen `timeout`;
    ///   - the `custom` preset (or any unknown id) yields the user's own
    ///     `customCommand` + `customArgs`.
    ///
    /// The transcript is never involved here — it travels on stdin (see the type
    /// header). Timeouts are clamped to a sane floor so a fat-fingered 0 can't make
    /// the runner kill the CLI instantly.
    static func resolveConfig(
        presetID: String,
        customCommand: String,
        customArgs: [String],
        timeout: TimeInterval
    ) -> Config {
        let clampedTimeout = max(1.0, timeout)
        if presetID == customPresetID {
            return Config(command: customCommand, args: customArgs, timeout: clampedTimeout)
        }
        guard let preset = preset(id: presetID), presetID != customPresetID else {
            // Unknown id → fall back to the custom fields, never to a surprise CLI.
            return Config(command: customCommand, args: customArgs, timeout: clampedTimeout)
        }
        // Keep the preset's shipped command + args (never derived from the user's
        // custom fields), but honor the user's timeout.
        return Config(command: preset.config.command, args: preset.config.args, timeout: clampedTimeout)
    }

    /// Parse the settings-UI "arguments" text box (one argument per line) into the
    /// discrete `[String]` argv template. Blank lines are dropped; each surviving
    /// line is one argument, verbatim (no shell splitting — so an instruction with
    /// spaces stays a single argument). This keeps the injection-safety contract:
    /// the user types the fixed args, never the transcript.
    static func parseCustomArgs(_ text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Inverse of `parseCustomArgs` — render an argv template back into the
    /// one-arg-per-line text the settings field edits.
    static func formatCustomArgs(_ args: [String]) -> String {
        args.joined(separator: "\n")
    }
}

// MARK: - Enhancement-provider selection (pure)

/// The AI-cleanup / whole-text-refine backend the user selected. This is the pure,
/// testable decision behind "which refiner runs": OpenWhisp historically had only
/// the OpenAI-compatible family (cloud / bundled llama / local server); MAK-44 adds
/// the agent-CLI provider as a peer. Only the agent-CLI case changes *which*
/// `AsyncTextRefiner` the app builds — every other id keeps the existing
/// OpenAI-service path unchanged (no regression).
public enum EnhancementProvider: Equatable {
    /// The persisted `llmProvider` value selecting the agent-CLI backend.
    public static let agentCLIID = "agentCLI"

    /// True iff the persisted provider id selects the agent-CLI refiner. Every other
    /// id (`bundled` / `openai` / `local` / anything unknown) stays on the existing
    /// OpenAI-service refiner, so the default is preserved.
    public static func usesAgentCLI(_ providerID: String) -> Bool {
        providerID == agentCLIID
    }

    /// The command the app would spawn for the agent-CLI provider, given the user's
    /// persisted selection — or a `BuildError` if the config is unusable (empty
    /// command, transcript-in-argv). Pure: this is the seam a test drives to prove
    /// "provider=agentCLI + preset=claude ⇒ the claude argv".
    public static func agentCLICommand(
        presetID: String,
        customCommand: String,
        customArgs: [String],
        timeout: TimeInterval
    ) -> Result<AgentCLIProvider.Command, AgentCLIProvider.BuildError> {
        let config = AgentCLIProvider.resolveConfig(
            presetID: presetID,
            customCommand: customCommand,
            customArgs: customArgs,
            timeout: timeout
        )
        return AgentCLIProvider.buildCommand(config: config)
    }
}
