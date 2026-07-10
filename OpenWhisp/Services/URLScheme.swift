import Foundation

/// Pure parsing + validation for the `openwhisp://` URL scheme: it turns one raw
/// URL (from a Raycast/Alfred launcher, a browser, or `open openwhisp://…`) into a
/// typed, chainable list of ``URLScheme/Command``s — with no I/O, no AppKit, and no
/// app dependencies. The fiddly rules — the verb allow-list, per-verb parameter
/// validation, chaining semantics, and hostile-input rejection — live here so they
/// can be unit-tested; the app's `application(_:open:)` executes what this returns.
///
/// **Security is the point of this seam.** The scheme is a control surface any
/// local process can drive by handing a URL to `open`, so it exposes ONLY a fixed
/// allow-list of safe verbs — never arbitrary text to run, a file path to execute,
/// or a shell string. An unknown verb, a malformed URL, or a bad parameter is
/// rejected as a whole (``Parsed/rejected``); we never partially execute a
/// half-understood request. Parameter values are treated as opaque data (a mode
/// key, a refine instruction) and are length-capped, never interpreted as code.
public enum URLScheme {

    /// The one URL scheme OpenWhisp registers (declared in Info.plist's
    /// `CFBundleURLTypes`). Compared case-insensitively per RFC 3986.
    public static let scheme = "openwhisp"

    /// Hard caps so a hostile URL can't hand the app an unbounded string. Display
    /// and routing both treat values as opaque data; these bounds keep a single
    /// launcher invocation from ballooning memory or a log line.
    public static let maxValueLength = 2_000
    /// A chained URL (`?record&switch-mode=email`) can only carry so many commands
    /// before it's clearly not a human-authored launcher action.
    public static let maxChainedCommands = 8

    // MARK: - The verb allow-list

    /// The complete, closed set of verbs the scheme exposes. Anything outside this
    /// list is rejected — the allow-list IS the security boundary. Raw values are
    /// the on-the-wire verb strings (URL host or query key).
    public enum Verb: String, CaseIterable, Sendable, Equatable {
        /// Start (or toggle) a user dictation — the same action as the hotkey.
        case record
        /// Rewrite text with the on-device AI (`instruction` required; `text`
        /// optional, defaults to the last result).
        case refine
        /// Switch the active mode/profile by its key, applying it to the next
        /// dictation (`key` required).
        case switchMode = "switch-mode"
        /// Activate a mode/profile WITHOUT starting a dictation (`key` required).
        case activateMode = "activate-mode"
        /// Paste the last dictation/refine result into the focused app.
        case pasteLast = "paste-last-result"
        /// Open (and focus) the floating Scratchpad panel — a target-free surface
        /// to dictate into (MAK-49). Takes no parameters.
        case scratchpad
    }

    // MARK: - A validated command

    /// One validated, ready-to-execute command. Constructed only by ``parse(_:)``,
    /// so an instance is a proof that the verb was on the allow-list and its
    /// parameters passed validation.
    public enum Command: Equatable, Sendable {
        /// Start/toggle a user dictation.
        case record
        /// Refine `text` (nil → use the last result) per `instruction`.
        case refine(instruction: String, text: String?)
        /// Switch to the mode/profile `key` and apply it to the next dictation.
        case switchMode(key: String)
        /// Activate the mode/profile `key` without recording.
        case activateMode(key: String)
        /// Paste the last result.
        case pasteLast
        /// Open/focus the floating Scratchpad panel.
        case scratchpad

        /// The verb this command came from (for logging / capability gating).
        public var verb: Verb {
            switch self {
            case .record:       return .record
            case .refine:       return .refine
            case .switchMode:   return .switchMode
            case .activateMode: return .activateMode
            case .pasteLast:    return .pasteLast
            case .scratchpad:   return .scratchpad
            }
        }
    }

    // MARK: - Parse outcome

    /// Why a URL was rejected. Never leaks a value back (no oracle to a hostile
    /// caller); the app maps this to a log line, not a user-facing echo.
    public enum Rejection: Equatable, Sendable, Error {
        /// Not an `openwhisp://` URL at all (wrong scheme, unparseable).
        case notOurScheme
        /// The URL named no verb (empty host and no query keys).
        case noCommand
        /// A verb outside the allow-list (`openwhisp://frobnicate`).
        case unknownVerb(String)
        /// A required parameter was missing (`refine` with no `instruction`,
        /// `switch-mode` with no `key`).
        case missingParameter(verb: Verb, parameter: String)
        /// A parameter exceeded ``maxValueLength`` or was otherwise malformed.
        case invalidParameter(verb: Verb, parameter: String)
        /// More than ``maxChainedCommands`` verbs in one URL.
        case tooManyCommands
    }

    /// The result of parsing one URL: either an ordered, non-empty list of
    /// validated commands (chaining preserved), or a single rejection reason. The
    /// caller executes all-or-nothing — a rejection means NOTHING runs.
    public enum Parsed: Equatable, Sendable {
        case commands([Command])
        case rejected(Rejection)
    }

    // MARK: - Parsing

    /// Parse a raw URL into validated commands. Pure and total — every input maps
    /// to a ``Parsed`` (never throws, never partially executes).
    ///
    /// Grammar (two equivalent surfaces, so both `open`-friendly forms work):
    ///
    /// - **Single verb as host:** `openwhisp://record`,
    ///   `openwhisp://refine?instruction=make%20it%20formal`,
    ///   `openwhisp://switch-mode?key=email`.
    /// - **Chained verbs as query keys:** `openwhisp://?record&switch-mode=email`
    ///   — each query item whose key is an allow-listed verb becomes a command, in
    ///   URL order. A verb that takes a parameter carries it either as its own
    ///   value (`switch-mode=email`) or as a following param key
    ///   (`refine&instruction=...`).
    ///
    /// The host form is the common launcher case; the query form is what makes
    /// chaining ("activate my email mode, then start recording") a single URL.
    public static func parse(_ url: URL) -> Parsed {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.scheme else {
            return .rejected(.notOurScheme)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        // Build a lowercase param lookup (last-wins) for host-form verbs that read
        // named params (refine?instruction=…, switch-mode?key=…). Values are the
        // raw (already percent-decoded) query values.
        var params: [String: String] = [:]
        for item in queryItems {
            params[item.name.lowercased()] = item.value ?? ""
        }

        // HOST form: a single verb named as the URL host.
        if let host = url.host, !host.isEmpty {
            switch validate(verbToken: host, params: params, chainedValue: nil) {
            case .success(let command): return .commands([command])
            case .failure(let rejection): return .rejected(rejection)
            }
        }

        // QUERY form: each query item whose KEY is an allow-listed verb is a
        // command, in order. Non-verb keys are parameter carriers consumed by the
        // preceding verb's validation (via `params`), so they're skipped here.
        var commands: [Command] = []
        for item in queryItems {
            guard let verb = Verb(rawValue: item.name.lowercased()) else { continue }
            if commands.count >= maxChainedCommands { return .rejected(.tooManyCommands) }
            // A chained verb may carry its parameter as its own value
            // (`switch-mode=email`) — pass it so validation prefers it over a
            // separate param key.
            let chained = (item.value?.isEmpty == false) ? item.value : nil
            switch validate(verbToken: item.name, params: params, chainedValue: chained) {
            case .success(let command): commands.append(command)
            case .failure(let rejection): return .rejected(rejection)
            }
        }

        guard !commands.isEmpty else { return .rejected(.noCommand) }
        return .commands(commands)
    }

    // MARK: - Per-verb validation

    /// Validate one verb token against the allow-list and its parameter rules.
    /// `chainedValue` is the verb-key's own query value (query form); `params` is
    /// the named-parameter lookup (host form or a following param key).
    private static func validate(
        verbToken: String, params: [String: String], chainedValue: String?
    ) -> Result<Command, Rejection> {
        guard let verb = Verb(rawValue: verbToken.lowercased()) else {
            return .failure(.unknownVerb(verbToken))
        }

        switch verb {
        case .record:
            return .success(.record)

        case .pasteLast:
            return .success(.pasteLast)

        case .scratchpad:
            return .success(.scratchpad)

        case .refine:
            // instruction is required (a refine with no instruction is a no-op we
            // refuse rather than guess). text is optional → last result.
            guard let instruction = requiredValue(chainedValue ?? params["instruction"]) else {
                return .failure(.missingParameter(verb: verb, parameter: "instruction"))
            }
            guard instruction.count <= maxValueLength else {
                return .failure(.invalidParameter(verb: verb, parameter: "instruction"))
            }
            let text = params["text"].flatMap(requiredValue)
            if let text, text.count > maxValueLength {
                return .failure(.invalidParameter(verb: verb, parameter: "text"))
            }
            return .success(.refine(instruction: instruction, text: text))

        case .switchMode, .activateMode:
            // key is required and opaque (a mode/profile identifier). It's never
            // interpreted as a path or command — just matched against known modes.
            guard let key = requiredValue(chainedValue ?? params["key"]) else {
                return .failure(.missingParameter(verb: verb, parameter: "key"))
            }
            guard key.count <= maxValueLength, isSafeKey(key) else {
                return .failure(Rejection.invalidParameter(verb: verb, parameter: "key"))
            }
            let command: Command = (verb == .switchMode) ? .switchMode(key: key) : .activateMode(key: key)
            return .success(command)
        }
    }

    /// A trimmed non-empty value, or nil. Whitespace-only params count as absent.
    private static func requiredValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A mode/profile key must read like an identifier, not a payload: no control
    /// characters, no newlines, no path separators. This keeps a `key` from being
    /// smuggled into anything path- or shell-shaped downstream — defense in depth
    /// even though the executor only ever compares it against known mode names.
    private static func isSafeKey(_ key: String) -> Bool {
        for scalar in key.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            if scalar == "/" || scalar == "\\" { return false }
        }
        return true
    }
}
