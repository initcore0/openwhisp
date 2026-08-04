import Foundation

/// The local post-completion **rules engine** (MAK-43): a generalization of the
/// single-step `ScriptPostProcessor` into a set of user-defined rules that fire on
/// lifecycle hooks and transcript content, each running one or more **actions**.
///
/// This file is the pure, Foundation-only heart — the rule model, the matcher
/// semantics, and the planner that turns "which rules fired" into an ordered list
/// of actions to run. It carries NO side effects: it never touches the filesystem,
/// the network, or a subprocess. The app-side runner (`RuleEngineRunner`, built by
/// build.sh) maps each planned action onto the EXISTING action layer — the
/// `OutputTarget` sinks from MAK-11..14 (`FileOutputTarget` / `WebhookOutputTarget`
/// / `ShortcutOutputTarget`), the hardened `ScriptRunner`, and the text inserter —
/// so this ticket adds no new delivery code, only the matching + planning brain.
///
/// **The load-bearing invariant (fail-open):** rules are a SIDE CHANNEL. Planning
/// or running them can never change, delay, or break the normal transcript insert.
/// The planner is a pure function of its inputs and cannot throw; the runner runs
/// actions after (and independently of) the insert. A malformed rule, a failing
/// action, or a hung shell script degrades to "that one action didn't happen" —
/// never to lost dictation.
///
/// Foundation-only, so it lives in `OpenWhispCore` and the matcher + planner are
/// exhaustively `swift test`-covered.

// MARK: - Lifecycle hooks

/// The pipeline moment a rule keys on. Both hooks fire on the FINAL utterance only
/// (never per live chunk); the difference is which text the rule sees and matches.
enum RuleHook: String, Codable, CaseIterable {
    /// After transcription (and local cleanup), BEFORE any LLM refine. The rule sees
    /// the raw-ish transcript — good for "did I say the trigger phrase" routing that
    /// shouldn't depend on the LLM rewriting it.
    case transcribeComplete
    /// After the LLM refine step (or, when refine is off, the same final text). The
    /// rule sees exactly what will be inserted — good for archiving/notifying with
    /// the polished result.
    case llmComplete
}

// MARK: - Session-mode gate

/// Which session modes a rule may fire in. Dictation sessions are the human ones;
/// agent sessions are driven by the agent bridge / MCP. Agent sessions are treated
/// as sensitive: a rule never fires on one unless it opts in (`.any` or `.agent`),
/// so wiring a webhook/shell action can't silently exfiltrate an agent's transcript.
enum RuleSessionMode: String, Codable, CaseIterable {
    /// Human dictation sessions only (the default, safe choice).
    case dictation
    /// Agent-initiated sessions only.
    case agent
    /// Both. Opting in here is the explicit "yes, run this on agent sessions too".
    case any

    /// Does this mode admit a session with the given agent flag?
    func admits(isAgentSession: Bool) -> Bool {
        switch self {
        case .dictation: return !isAgentSession
        case .agent:     return isAgentSession
        case .any:       return true
        }
    }
}

// MARK: - Text match

/// How a rule's `pattern` is compared against the transcript. Comparison is
/// case-insensitive and whitespace-trimmed at the edges for the literal modes;
/// `regex` is evaluated verbatim (the user owns their pattern).
enum RuleMatchKind: String, Codable, CaseIterable {
    /// The trimmed transcript equals the pattern (case-insensitive).
    case exact
    /// The trimmed transcript starts with the pattern (case-insensitive). This is
    /// the "command prefix" mode — `pattern = "todo"` fires on "todo buy milk".
    case prefix
    /// The transcript contains the pattern anywhere (case-insensitive).
    case contains
    /// The pattern is an ICU regular expression, matched anywhere in the transcript.
    /// Evaluated with a hard guard (see `RuleMatcher`) so a catastrophic-backtracking
    /// pattern can't hang the finalize path.
    case regex
    /// Always matches — a rule that should run on every completion (e.g. "append
    /// everything to my log"). `pattern` is ignored.
    case always
}

/// A text-match predicate: the kind plus the (kind-dependent) pattern string.
struct RuleTextMatch: Codable, Equatable {
    var kind: RuleMatchKind
    /// The comparison string (or regex source). Ignored for `.always`.
    var pattern: String

    init(kind: RuleMatchKind, pattern: String = "") {
        self.kind = kind
        self.pattern = pattern
    }

    static let always = RuleTextMatch(kind: .always)
}

// MARK: - App-scope match

/// Optional scoping to the frontmost app. `nil`/empty = any app. When set, the
/// rule fires only when the dictation's target-app bundle ID equals `bundleID`.
/// Kept as a plain optional string (not a list) for v1 simplicity.
struct RuleAppScope: Codable, Equatable {
    /// Bundle ID that must match the frontmost app, or nil/empty for "any app".
    var bundleID: String?

    init(bundleID: String? = nil) {
        self.bundleID = bundleID
    }

    static let any = RuleAppScope(bundleID: nil)

    /// Whether this scope admits a dictation whose target app is `appBundleID`.
    func admits(appBundleID: String?) -> Bool {
        guard let want = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !want.isEmpty else { return true }   // no scope → any app
        return appBundleID == want
    }
}

// MARK: - Actions

/// A single action a rule runs when it fires. Each case carries exactly the config
/// the corresponding delivery layer needs — deliberately REUSING the existing sink
/// configs (`FileOutputConfig` / `WebhookConfig` / shortcut name) so the app-side
/// runner can hand them straight to `FileOutputTarget` / `WebhookOutputTarget` /
/// `ShortcutOutputTarget` with no new delivery code.
///
/// `Codable` with an explicit type-tag so a rule set round-trips through JSON and a
/// future action kind can be added without breaking older files (unknown tags fail
/// the decode of that one rule, which the store quarantines — never a crash).
enum RuleAction: Codable, Equatable {
    /// Insert a fixed snippet of text into the focused app (a canned response, a
    /// signature). The transcript is NOT sent anywhere — this is pure local text.
    case insertSnippet(text: String)
    /// Open a URL in the default handler (`https://…`, a deep link, an `obsidian://`
    /// URI). The transcript can be interpolated via the `{{text}}` token, which the
    /// runner percent-encodes — the raw transcript never becomes a URL-injection
    /// vector because the runner encodes it.
    case openURL(template: String)
    /// Run a user-chosen executable with the transcript on **stdin** (never as an
    /// argument), via the hardened `ScriptRunner` (2 s timeout, SIGTERM→SIGKILL, no
    /// shell interpolation). This is the generalized `ScriptPostProcessor`.
    case runShell(scriptPath: String)
    /// Invoke a macOS Shortcut with the transcript on stdin — reuses
    /// `ShortcutOutputTarget`.
    case runShortcut(name: String)
    /// POST the transcript (as the MAK-14 JSON body) to a webhook — reuses
    /// `WebhookOutputTarget` with the given `WebhookConfig`.
    case postWebhook(config: WebhookConfig)
    /// Append the transcript to a local Markdown/text file — reuses
    /// `FileOutputTarget` with the given `FileOutputConfig`.
    case appendFile(config: FileOutputConfig)

    // Explicit Codable so the on-disk shape is a stable, inspectable contract.
    private enum CodingKeys: String, CodingKey { case type, text, template, scriptPath, name, config }
    private enum Tag: String, Codable {
        case insertSnippet, openURL, runShell, runShortcut, postWebhook, appendFile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .type) {
        case .insertSnippet: self = .insertSnippet(text: try c.decode(String.self, forKey: .text))
        case .openURL:       self = .openURL(template: try c.decode(String.self, forKey: .template))
        case .runShell:      self = .runShell(scriptPath: try c.decode(String.self, forKey: .scriptPath))
        case .runShortcut:   self = .runShortcut(name: try c.decode(String.self, forKey: .name))
        case .postWebhook:   self = .postWebhook(config: try c.decode(WebhookConfig.self, forKey: .config))
        case .appendFile:    self = .appendFile(config: try c.decode(FileOutputConfig.self, forKey: .config))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .insertSnippet(let text): try c.encode(Tag.insertSnippet, forKey: .type); try c.encode(text, forKey: .text)
        case .openURL(let t):          try c.encode(Tag.openURL, forKey: .type); try c.encode(t, forKey: .template)
        case .runShell(let p):         try c.encode(Tag.runShell, forKey: .type); try c.encode(p, forKey: .scriptPath)
        case .runShortcut(let n):      try c.encode(Tag.runShortcut, forKey: .type); try c.encode(n, forKey: .name)
        case .postWebhook(let cfg):    try c.encode(Tag.postWebhook, forKey: .type); try c.encode(cfg, forKey: .config)
        case .appendFile(let cfg):     try c.encode(Tag.appendFile, forKey: .type); try c.encode(cfg, forKey: .config)
        }
    }
}

// MARK: - Rule

/// One rule: a match (hook + text pattern + app scope + session mode) → an ordered
/// list of actions. Rules are evaluated in the order they appear in the `RuleSet`;
/// a disabled rule is skipped entirely.
struct Rule: Codable, Equatable, Identifiable {
    var id: UUID
    /// Human-readable name shown in Settings.
    var name: String
    /// Whether the rule is active. A disabled rule never matches.
    var isEnabled: Bool
    /// Which lifecycle hook the rule fires on.
    var hook: RuleHook
    /// The transcript predicate.
    var match: RuleTextMatch
    /// Optional frontmost-app scope.
    var appScope: RuleAppScope
    /// Which session modes admit this rule (dictation-only by default; agent
    /// sessions require an explicit opt-in — see `RuleSessionMode`).
    var sessionMode: RuleSessionMode
    /// The actions to run, in order, when the rule fires.
    var actions: [RuleAction]

    init(
        id: UUID = UUID(),
        name: String = "New rule",
        isEnabled: Bool = true,
        hook: RuleHook = .llmComplete,
        match: RuleTextMatch = .always,
        appScope: RuleAppScope = .any,
        sessionMode: RuleSessionMode = .dictation,
        actions: [RuleAction] = []
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.hook = hook
        self.match = match
        self.appScope = appScope
        self.sessionMode = sessionMode
        self.actions = actions
    }
}

/// The persisted collection of rules. A plain wrapper (vs. a bare array) so the
/// on-disk JSON has a stable top-level object we can version later.
struct RuleSet: Codable, Equatable {
    var rules: [Rule]

    init(rules: [Rule] = []) {
        self.rules = rules
    }

    static let empty = RuleSet()
}

// MARK: - Match context

/// Everything the matcher/planner needs to decide which rules fire for one finished
/// dictation. Pure value type so planning is a deterministic function of its input.
struct RuleContext: Equatable {
    /// The hook currently firing.
    let hook: RuleHook
    /// The transcript text as it exists at this hook.
    let text: String
    /// Frontmost app bundle ID at dictation start, if known.
    let appBundleID: String?
    /// True for an agent-bridge/MCP session (the sensitive case).
    let isAgentSession: Bool

    init(hook: RuleHook, text: String, appBundleID: String?, isAgentSession: Bool) {
        self.hook = hook
        self.text = text
        self.appBundleID = appBundleID
        self.isAgentSession = isAgentSession
    }

    /// Build the (context, payload) pair one rules-engine firing needs.
    ///
    /// Pure, so the shape of what the engine receives is pinned by `swift test`
    /// rather than only by reading AppState's finalize path — and so AppState carries
    /// the call, not the construction (MAK-32 ratchet).
    ///
    /// `isLiveChunk` is deliberately fixed to `false`: every caller fires this from a
    /// FINAL transcript, never a streaming chunk.
    static func firing(
        hook: RuleHook, text: String, appBundleID: String?,
        isAgentSession: Bool, language: String
    ) -> (context: RuleContext, payload: OutputPayload) {
        (
            RuleContext(
                hook: hook, text: text,
                appBundleID: appBundleID, isAgentSession: isAgentSession),
            OutputPayload(
                text: text, language: language,
                targetAppBundleID: appBundleID, isLiveChunk: false)
        )
    }
}

// MARK: - Matcher

/// Pure text-match evaluation. Literal modes are simple case-insensitive String
/// ops; `regex` is guarded so a pathological pattern can't stall finalization.
enum RuleMatcher {
    /// The longest transcript we bother regex-matching. A regex over a very long
    /// transcript is the classic catastrophic-backtracking trap; past this length we
    /// decline the match (the rule simply doesn't fire) rather than risk a hang. The
    /// literal modes have no such limit — they're linear and safe.
    static let regexInputCap = 20_000

    /// Wall-clock budget for one regex evaluation. The input cap alone is NOT a
    /// backtracking guard — `(a+)+b` blows up exponentially on a few dozen
    /// characters — so the match is driven through `enumerateMatches` with
    /// `.reportProgress`, and past this deadline it is abandoned (the rule simply
    /// doesn't fire). Generous for any sane pattern; fatal only to pathological ones.
    static let regexTimeBudget: TimeInterval = 0.25

    /// Does `pattern` (interpreted per `kind`) match `text`?
    static func matches(_ text: String, _ match: RuleTextMatch) -> Bool {
        let hay = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = match.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        switch match.kind {
        case .always:
            return true
        case .exact:
            guard !needle.isEmpty else { return false }
            return hay.compare(needle, options: .caseInsensitive) == .orderedSame
        case .prefix:
            guard !needle.isEmpty else { return false }
            return hay.range(of: needle, options: [.caseInsensitive, .anchored]) != nil
        case .contains:
            guard !needle.isEmpty else { return false }
            return hay.range(of: needle, options: .caseInsensitive) != nil
        case .regex:
            return regexMatches(text, pattern: match.pattern)
        }
    }

    /// Guarded regex match. An empty pattern never matches; an over-long input is
    /// declined (see `regexInputCap`); an invalid pattern never matches (the user's
    /// typo can't crash or throw into the finalize path); and a catastrophically
    /// backtracking pattern is abandoned after `regexTimeBudget` via ICU's match
    /// progress callback (`.reportProgress` + `stop`), degrading to "no match".
    static func regexMatches(_ text: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        guard text.utf16.count <= regexInputCap else { return false }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let deadline = Date().addingTimeInterval(regexTimeBudget)
        var found = false
        re.enumerateMatches(in: text, options: [.reportProgress], range: range) { result, _, stop in
            if result != nil {
                found = true
                stop.pointee = true
            } else if Date() > deadline {
                stop.pointee = true
            }
        }
        return found
    }
}

// MARK: - Planner

/// A concrete action to run, paired with the rule it came from (for logging). The
/// runner consumes these in order.
struct PlannedAction: Equatable {
    /// The id of the rule that produced this action.
    let ruleID: UUID
    /// The rule's name (for status/telemetry).
    let ruleName: String
    /// The action to perform.
    let action: RuleAction
}

/// Turns a `RuleSet` + a `RuleContext` into the ordered list of actions to run.
///
/// This is the whole decision surface of the engine, and it is a PURE function: no
/// I/O, no throwing. It enforces, in order, every gate a rule must clear —
///   1. the rule is enabled,
///   2. its hook equals the firing hook,
///   3. the session mode admits this session (the agent gate),
///   4. the app scope admits the frontmost app,
///   5. the text predicate matches —
/// and emits the surviving rules' actions in rule-then-action order. Because it
/// can't throw and never touches the transcript that gets inserted, running its
/// output can never break the normal insert.
enum RulePlanner {
    static func plan(rules: RuleSet, context: RuleContext) -> [PlannedAction] {
        var out: [PlannedAction] = []
        for rule in rules.rules {
            guard rule.isEnabled else { continue }
            guard rule.hook == context.hook else { continue }
            guard rule.sessionMode.admits(isAgentSession: context.isAgentSession) else { continue }
            guard rule.appScope.admits(appBundleID: context.appBundleID) else { continue }
            guard RuleMatcher.matches(context.text, rule.match) else { continue }
            for action in rule.actions {
                out.append(PlannedAction(ruleID: rule.id, ruleName: rule.name, action: action))
            }
        }
        return out
    }
}

// MARK: - URL action interpolation (pure)

/// Pure builder for the `openURL` action's target, kept in core so the
/// transcript-interpolation + encoding rule is unit-tested. The app-side runner
/// calls this and hands the result to `NSWorkspace.open`.
enum RuleURLBuilder {
    /// Build the URL for an `openURL` action: substitute a percent-encoded transcript
    /// for the `{{text}}` token, then parse. Returns nil for an empty template or an
    /// unparseable result so the action is skipped rather than crashing. The
    /// transcript is encoded with a query-VALUE-safe set (escaping `& = + ? # /`) so
    /// an interpolated transcript can't inject extra query params or path segments.
    static func build(template: String, text: String) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .ruleURLQueryValue) ?? ""
        let substituted = trimmed.replacingOccurrences(of: "{{text}}", with: encoded)
        return URL(string: substituted)
    }
}

extension CharacterSet {
    /// URL-query VALUE encoding: like `.urlQueryAllowed` but also escapes the
    /// sub-delimiters that carry structural meaning in a query/path.
    static let ruleURLQueryValue: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#/")
        return set
    }()
}
