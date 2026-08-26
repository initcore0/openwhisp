import Foundation

/// The declarative description of an OpenWhisp plugin.
///
/// Plugins are OPTIONAL surfaces layered on top of the app: each one contributes a
/// tab/window of its own plus its own configuration, and none of them are part of
/// the base dictation pipeline. A manifest is the contract between a plugin and the
/// host — enough for the host to LIST a plugin (name, icon, version, what it needs)
/// without knowing anything about what the plugin does.
///
/// Two provenances, both surfaced identically in the UI:
///
/// - **Built-in** — an in-repo plugin under `plugins/<id>/`, compiled INTO the app
///   and declared in the compile-time `PluginRegistry`. Its manifest ships as a
///   literal so it can never go missing at runtime. This is what the in-repo plugins use.
/// - **External** — a manifest discovered on disk at
///   `~/Library/Application Support/OpenWhisp/Plugins/<id>/manifest.json`. The
///   host DISCOVERS and LISTS these but cannot execute them: there is no loader.
///   True out-of-process/dylib loading is future work (see `PluginEntryKind`).
///
/// Foundation-only, so the manifest schema, its validation, and the discovery
/// merge/precedence rules are all pinned by `swift test`.
public struct PluginManifest: Codable, Equatable, Sendable, Identifiable {

    /// Reverse-DNS-ish stable identifier, e.g. `meme-generator`. Also the on-disk
    /// directory name and the key the enabled-set is stored under, so it must stay
    /// stable across versions — renaming an id silently disables the plugin.
    public let id: String

    /// Human-readable name shown in the Plugins pane and the menu-bar submenu.
    public let name: String

    /// Semver-ish display string. The host does not currently gate on it; it exists
    /// so the pane can show what's installed and so a future loader has something to
    /// compare against a compatibility floor.
    public let version: String

    /// One-line description of what the plugin does, shown under the name.
    public let summary: String

    /// SF Symbol name for every surface that renders this plugin (pane row, menu
    /// item, window). Menu rows in this app always carry a symbol — never an emoji
    /// inlined into the title.
    public let symbol: String

    /// How the host is expected to run this plugin.
    public let entry: PluginEntryKind

    /// Whether the plugin talks to the network, and to whom. The app is local-first,
    /// so a plugin that reaches out MUST say so: the Plugins pane renders this
    /// verbatim as a disclosure next to the enable toggle. Empty = fully local.
    ///
    /// This is an HONEST LABEL, not a sandbox — nothing enforces it today.
    /// A real third-party plugin system would need the enforcement to live outside
    /// the plugin's own manifest (see the PR's security notes).
    public let networkHosts: [String]

    /// The single character this plugin would like as its ⌘-shortcut in the menu bar
    ///, e.g. `"m"` → ⌘M opens the Meme Generator's window.
    ///
    /// OPTIONAL, and a REQUEST rather than a grant. The host is the only thing that
    /// knows the app's own menu shortcuts, so it — not the plugin — decides whether
    /// the request is honoured (`PluginKeyEquivalent.assignable`). A plugin that asks
    /// for ⌘Q does not get to shadow Quit.
    ///
    /// It lives on the MANIFEST rather than being hardcoded next to the one plugin
    /// that wants it, because the manifest is already the place a plugin declares how
    /// the host should present it (name, symbol, disclosure). That is the MAK-100
    /// "manifests carry host metadata" direction, and it means a second plugin needs
    /// no change in `AppMain` at all.
    ///
    /// Decoded with a default so every manifest written before this field existed —
    /// including any already sitting in the user's plugins folder — still decodes.
    public let keyEquivalent: String?

    /// Spoken PREFIX phrases that route a refine instruction to this plugin,
    /// e.g. `["create a meme", "make a meme", "сделай мем"]`.
    ///
    /// This is the MAK-100 trigger layer: the refine pipeline asks
    /// `PluginVoiceCommandRouter` which plugin (if any) claims an instruction, and the
    /// answer comes from THESE strings rather than from a hardcoded list next to the
    /// one plugin that wants them. A second plugin gains voice commands by shipping a
    /// manifest — no host change.
    ///
    /// Deliberately PREFIX-only and exact-phrase: an instruction is routed away from
    /// the user's normal refine, so a loose match (substring/fuzzy) would hijack
    /// dictations the user meant to keep. See `PluginVoiceCommandRouter` for the
    /// matching rules and `normalizedVoiceTriggers` for what survives validation.
    ///
    /// Decoded with a default, like every field added after v1 — a manifest written
    /// before this existed still decodes rather than dropping the plugin from the list.
    public let voiceTriggers: [String]

    /// Hints about WHICH APPS this plugin's voice triggers are most relevant in, as
    /// bundle identifiers (e.g. `["com.apple.Safari"]`). Empty = relevant everywhere.
    ///
    /// RESERVED AND ADVISORY (MAK-100). Nothing routes on it today: the voice router
    /// matches on trigger phrases alone, and this field is carried, validated, and
    /// normalized so a manifest written for a future host still decodes here — and so
    /// the ranking work, when it lands, has real data rather than a schema migration.
    ///
    /// It is a HINT, never a priority. MAK-100's ~15-tool cap makes exposed trigger
    /// surface a scarce, host-arbitrated resource, so the ranking and the cap must be
    /// enforced host-side. A manifest that could self-assign priority would be the
    /// `networkHosts` mistake again: a plugin cannot be trusted to declare its own
    /// limits.
    public let appAffinity: [String]

    /// Whether this plugin wants the current pasteboard contents handed to it when it
    /// is invoked (MAK-100).
    ///
    /// DECLARED, DEFAULT FALSE. The host reads the pasteboard and passes the string
    /// only to invocations whose manifest says `true`; a plugin that does not declare
    /// it receives `nil` and cannot ask again. See `PluginInvocationContext`.
    ///
    /// Why declaration matters: an undeclared clipboard read is a bigger privacy fact
    /// than a network host, and `networkHosts` was already the only disclosure the
    /// manifest carried. The user's clipboard routinely holds passwords, tokens, and
    /// other people's messages — so this drives a visible disclosure in the Plugins
    /// pane, next to the enable toggle, the same way network access does.
    ///
    /// This is an honest LABEL plus a real GATE, and the distinction is worth keeping
    /// straight: the host genuinely withholds the pasteboard from a plugin that didn't
    /// declare it (that part is enforced), but an in-process plugin could still reach
    /// `NSPasteboard` itself. Enforcement only becomes real at a process boundary —
    /// see docs/PLUGINS.md §"Security and trust".
    public let clipboardAccess: Bool

    /// Where this plugin's output should go (MAK-100). Defaults to `.ownWindow`.
    ///
    /// `.ownWindow` is the ONLY implemented route. The other cases are reserved and
    /// validated so the schema does not have to change when the host learns to route
    /// plugin output through the existing `OutputTarget` protocol — a manifest can
    /// declare one today and the host will refuse it honestly rather than silently
    /// doing something else. See `PluginDestination`.
    public let destination: PluginDestination

    /// The linear pipeline a SCRIPT plugin runs over its input text — the first shipped
    /// tier of docs/PLUGINS.md § "Path to hot-swappable".
    ///
    /// Meaningful only when `entry == .script`; a built-in plugin's behavior is its
    /// compiled code, not a step list. Each step is one host-executed action (call the
    /// LLM, write a file, run a bundled script, insert at the cursor) and the output of
    /// one is the input of the next. The plugin never runs code in this process: it
    /// composes capabilities the HOST owns, which is what makes a script plugin
    /// reviewable by reading its JSON.
    ///
    /// Defaulted like every field added after v1, so a manifest predating it decodes.
    /// The rules for what a step list MEANS — validity, ordering, consent, and what an
    /// unrecognized step type does — live in `PluginScriptPlan`, not here.
    public let steps: [PluginStep]

    public init(
        id: String,
        name: String,
        version: String,
        summary: String,
        symbol: String,
        entry: PluginEntryKind,
        networkHosts: [String] = [],
        keyEquivalent: String? = nil,
        voiceTriggers: [String] = [],
        appAffinity: [String] = [],
        clipboardAccess: Bool = false,
        destination: PluginDestination = .ownWindow,
        steps: [PluginStep] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.symbol = symbol
        self.entry = entry
        self.networkHosts = networkHosts
        self.keyEquivalent = keyEquivalent
        self.voiceTriggers = voiceTriggers
        self.appAffinity = appAffinity
        self.clipboardAccess = clipboardAccess
        self.destination = destination
        self.steps = steps
    }

    /// Forward-compatible decode: every field except `id`/`name`/`symbol` is optional
    /// in the JSON, so an older manifest (and a hand-written one) decodes rather than
    /// failing the whole plugin out of the list over a missing key.
    ///
    /// This is the rule for EVERY field added to this schema: default it here, and a
    /// manifest already sitting in a user's plugins folder keeps working across an app
    /// update. The inverse — a required key — turns a schema addition into a silent
    /// uninstall of every third-party plugin, which is the one migration this system
    /// can never ask its users to perform by hand.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        symbol = try container.decode(String.self, forKey: .symbol)
        // An UNKNOWN entry kind decodes to `.unsupported` rather than throwing.
        //
        // This is not hypothetical caution: before script plugins existed, a manifest
        // saying `"entry": "script"` failed this decode outright — `decodeIfPresent`
        // THROWS on an unrecognized enum value rather than returning nil — and the whole
        // plugin vanished from the pane instead of being listed as unrunnable. That is
        // exactly the migration the schema promises never to require, so the fallback
        // lives here for every future entry kind too.
        entry = (try? container.decodeIfPresent(PluginEntryKind.self, forKey: .entry))
            .flatMap { $0 }
            ?? (container.contains(.entry) ? .unsupported : .builtIn)
        networkHosts = try container.decodeIfPresent([String].self, forKey: .networkHosts) ?? []
        keyEquivalent = try container.decodeIfPresent(String.self, forKey: .keyEquivalent)
        voiceTriggers = try container.decodeIfPresent([String].self, forKey: .voiceTriggers) ?? []
        appAffinity = try container.decodeIfPresent([String].self, forKey: .appAffinity) ?? []
        clipboardAccess =
            try container.decodeIfPresent(Bool.self, forKey: .clipboardAccess) ?? false
        // An UNKNOWN destination decodes to the default rather than throwing: a
        // manifest written for a newer host must degrade to "its own window" — the
        // only route that always exists — instead of disappearing from the list. The
        // same reasoning as every other defaulted key above, applied to an enum.
        destination =
            (try? container.decodeIfPresent(PluginDestination.self, forKey: .destination))
            .flatMap { $0 } ?? .ownWindow
        // A step list that fails to decode (a step with no `type`, or a `steps` value
        // that isn't an array) yields NO steps rather than throwing the plugin out of
        // the list. The plugin is then listed and refused by `PluginScriptPlan` with a
        // reason the user can act on — the same trade every other field here makes.
        // An unknown step TYPE is not a decode failure at all; see `PluginStepKind`.
        steps = (try? container.decodeIfPresent([PluginStep].self, forKey: .steps))
            .flatMap { $0 } ?? []
    }

    /// The voice triggers this manifest may actually be routed on: trimmed,
    /// lowercased, de-duplicated, and with anything empty dropped.
    ///
    /// The router consumes THIS rather than the raw array, so a manifest carrying
    /// `["", "  ", "Create A Meme"]` contributes exactly one usable phrase instead of
    /// matching every instruction on the empty string — an empty prefix matches
    /// EVERYTHING, which would silently swallow every refine the user ever spoke.
    public var normalizedVoiceTriggers: [String] {
        var seen = Set<String>()
        return voiceTriggers.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    /// The shortcut as it should be DISPLAYED, e.g. `"⌘M"`, or nil when this manifest
    /// asks for none / asks for something unusable. Kept here so the Plugins pane and
    /// any future surface render it identically, and so `swift test` pins it.
    public var keyEquivalentDisplay: String? {
        guard let key = PluginKeyEquivalent.normalized(keyEquivalent) else { return nil }
        return "⌘\(key.uppercased())"
    }

    /// Whether this plugin uses the network at all — drives the pane's disclosure row.
    public var usesNetwork: Bool { !networkHosts.isEmpty }

    /// The disclosure sentence shown in the Plugins pane. Kept here (not in the view)
    /// so `swift test` pins the wording of a privacy-facing string.
    public var networkDisclosure: String? {
        guard usesNetwork else { return nil }
        return "Connects to \(networkHosts.joined(separator: ", ")) when you use it."
    }

    /// The clipboard disclosure shown in the Plugins pane, or nil when this plugin
    /// never receives the pasteboard.
    ///
    /// Kept beside `networkDisclosure` and pinned by `swift test` for the same reason:
    /// it is a privacy-facing string, and the pane must not be able to quietly reword
    /// what the user is consenting to.
    public var clipboardDisclosure: String? {
        guard clipboardAccess else { return nil }
        return "Reads your clipboard contents when you use it."
    }

    /// The app-affinity hints this manifest may actually be ranked on: trimmed,
    /// de-duplicated, and with anything empty dropped. Case is PRESERVED — bundle
    /// identifiers are compared exactly, and lowercasing one would silently stop it
    /// matching the app it names.
    public var normalizedAppAffinity: [String] {
        var seen = Set<String>()
        return appAffinity.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    // MARK: - Validation

    /// Why a decoded manifest was rejected.
    public enum ValidationError: Equatable, Sendable {
        case emptyID
        case invalidID(String)
        case emptyName
        case emptySymbol
        /// The manifest asked for a shortcut that isn't a single character.
        case invalidKeyEquivalent(String)
        /// The manifest declared `voiceTriggers` but not one of them survived
        /// normalization — e.g. `[""]` or `["   "]`. Reported so a plugin
        /// author sees it, but never fatal: see `isValid`.
        case emptyVoiceTriggers
        /// The manifest declared a `destination` the host cannot route to yet
        /// (anything but `.ownWindow`). Reported so a plugin author learns the route
        /// is reserved rather than live, and NEVER fatal — the plugin still runs and
        /// still owns its window. See `isValid`.
        case unsupportedDestination(PluginDestination)
        /// The manifest declared `appAffinity` but not one of the entries survived
        /// normalization. Advisory only, and never fatal.
        case emptyAppAffinity
    }

    /// Characters allowed in an id: lowercase alphanumerics plus `-` and `.`.
    /// Deliberately strict — the id becomes a PATH COMPONENT under Application
    /// Support, so anything that could traverse (`/`, `..`, NUL) must be rejected
    /// before it is ever joined onto a directory URL.
    private static let allowedIDCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")

    /// Whether a string is safe to use as the plugin directory's path component.
    ///
    /// The id rule, exposed so anything that JOINS an id onto a URL can re-check it at
    /// the point of use rather than trusting that validation happened earlier. Cheap,
    /// and the failure it guards against — a traversal-shaped id reaching a file API —
    /// is not the kind that should depend on call order.
    public static func isSafePathComponent(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        guard !id.unicodeScalars.contains(where: { !allowedIDCharacters.contains($0) })
        else { return false }
        return !id.allSatisfy { $0 == "." }
    }

    /// Validate a manifest's invariants. Returns `nil` when the manifest is usable.
    public func validate() -> ValidationError? {
        if id.isEmpty { return .emptyID }
        if id.unicodeScalars.contains(where: { !Self.allowedIDCharacters.contains($0) }) {
            return .invalidID(id)
        }
        // `.` is allowed inside an id (reverse-DNS style) but an id that is ONLY
        // dots — `.` / `..` — is a path-traversal component, never a plugin.
        if id.allSatisfy({ $0 == "." }) { return .invalidID(id) }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        if symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptySymbol }
        // A malformed shortcut is reported but is NOT fatal — see `isValid`. Losing a
        // whole working plugin over a cosmetic field would be a bad trade, and the id,
        // name, and symbol are the fields the host genuinely cannot proceed without.
        if let requested = keyEquivalent,
           PluginKeyEquivalent.normalized(requested) == nil {
            return .invalidKeyEquivalent(requested)
        }
        // Same trade as the shortcut: a manifest whose declared triggers all normalize
        // away loses its VOICE ROUTE (the router simply never matches it) and keeps
        // everything else. Fatal here would mean a stray `""` in a JSON file costs the
        // user a whole working plugin.
        if !voiceTriggers.isEmpty, normalizedVoiceTriggers.isEmpty {
            return .emptyVoiceTriggers
        }
        // A reserved-but-unimplemented destination is REPORTED, not fatal. The plugin
        // runs and keeps its own window — which is what it would have got anyway —
        // and the author gets told the route isn't live yet. Rejecting the manifest
        // would punish a plugin for describing a future the host hasn't built.
        if !destination.isImplemented { return .unsupportedDestination(destination) }
        if !appAffinity.isEmpty, normalizedAppAffinity.isEmpty { return .emptyAppAffinity }
        return nil
    }

    /// Whether the host can LIST and run this manifest.
    ///
    /// Deliberately more permissive than `validate() == nil`: only the structural
    /// failures disqualify a plugin. An unusable `keyEquivalent` costs the plugin its
    /// shortcut (`keyEquivalentDisplay` returns nil, and the menu assigns nothing) and
    /// nothing else; the same trade is made for every advisory field below.
    public var isValid: Bool {
        switch validate() {
        case nil, .invalidKeyEquivalent, .emptyVoiceTriggers,
             .unsupportedDestination, .emptyAppAffinity:
            return true
        default:
            return false
        }
    }

    /// The destination the host will ACTUALLY route this plugin's output to.
    ///
    /// Always `.ownWindow` today. Resolved here rather than at the call sites so a
    /// declared-but-unimplemented route degrades in exactly ONE place — a plugin that
    /// asks for `.cursor` gets its own window and the pane says so, instead of each
    /// caller inventing its own fallback.
    public var effectiveDestination: PluginDestination {
        destination.isImplemented ? destination : .ownWindow
    }
}

/// Where a plugin's output goes (MAK-100).
///
/// Only `.ownWindow` is implemented. The rest are RESERVED: they exist so the schema
/// does not need a breaking change when the host learns to route plugin output through
/// the `OutputTarget` protocol the dictation pipeline already uses, and so a manifest
/// declaring one is refused honestly (`PluginManifest.effectiveDestination` falls back,
/// `validate()` reports `.unsupportedDestination`) rather than silently doing something
/// the author didn't ask for.
///
/// Decoding an unknown value is not an error — see `PluginManifest.init(from:)`.
public enum PluginDestination: String, Codable, Equatable, Sendable, CaseIterable {

    /// The plugin's own window. The only route the host can take today, and the
    /// default for every manifest that doesn't say otherwise.
    case ownWindow

    /// Insert at the user's cursor in the frontmost app, via the same path a
    /// dictation takes. RESERVED — not implemented.
    case cursor

    /// Hand off to the user's configured output target (file, webhook, Shortcut).
    /// RESERVED — not implemented.
    case outputTarget

    /// Whether the host can actually route here today.
    public var isImplemented: Bool { self == .ownWindow }

    /// Why a reserved destination isn't available, shown to a plugin author.
    public var unavailableReason: String? {
        guard !isImplemented else { return nil }
        return "The '\(rawValue)' destination is reserved but not implemented yet — "
            + "this plugin's output goes to its own window."
    }
}

/// Who gets a ⌘-shortcut in the menu bar, and who is refused.
///
/// A plugin ASKS for a shortcut in its manifest; this decides. The host owns the
/// keyboard because only the host can see the whole menu — a plugin cannot know that
/// ⌘S is the Scratchpad or that ⌘, is Settings, and a plugin that could silently
/// shadow Quit would be a genuine hazard rather than a papercut.
///
/// Pure and Foundation-only so every rule here is pinned by `swift test` rather than
/// discovered by a user whose ⌘Q stopped quitting.
public enum PluginKeyEquivalent {

    /// The shortcuts the app itself already owns, which no plugin may take.
    ///
    /// Sourced from `AppMain`'s ACTUAL menu construction, and nothing beyond it:
    /// Quit (q), Scratchpad (s), Settings (,), Copy-last (c), and the Edit-menu verbs
    /// cut/paste/select-all/undo (x, v, a, z). The Edit ones matter most — PR #242 was
    /// the bug where those shortcuts were MISSING app-wide, and letting a plugin
    /// re-take one would reintroduce it for the price of a line in a JSON file.
    ///
    /// Kept to what the app really binds rather than padded with plausible-looking
    /// extras: every speculative entry here is a shortcut silently denied to a plugin
    /// for no reason. ⌘M is free precisely because this app has no Window menu.
    public static let reserved: Set<String> = [
        "q", "s", ",", "c", "x", "v", "a", "z",
    ]

    /// Normalize a requested shortcut, or nil when it isn't usable.
    ///
    /// Usable means: exactly ONE character after trimming, and a letter, digit, or
    /// `,`. Lowercased, because `NSMenuItem` treats an uppercase key equivalent as
    /// ⇧⌘ — a manifest saying `"M"` means ⌘M, not ⇧⌘M, and silently promoting it
    /// would hand out a different shortcut than the one declared.
    public static func normalized(_ requested: String?) -> String? {
        guard let requested else { return nil }
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 1, let character = trimmed.first else { return nil }
        guard character.isLetter || character.isNumber || character == "," else { return nil }
        return trimmed
    }

    /// The shortcut a plugin may actually be given, or nil to assign none.
    ///
    /// `taken` carries the shortcuts already handed out in THIS menu build — the
    /// app's reserved set plus anything an earlier plugin in the list already got —
    /// so two plugins both asking for `"m"` resolve deterministically by list order
    /// instead of both rendering ⌘M and one of them silently never firing.
    ///
    /// A refusal is SILENT by design: the plugin still appears in the menu and still
    /// opens by clicking. Dropping the whole row, or surfacing an error to the user
    /// about a collision they did not cause and cannot fix, would both be worse.
    public static func assignable(
        _ requested: String?, taken: Set<String>
    ) -> String? {
        guard let key = normalized(requested) else { return nil }
        guard !reserved.contains(key), !taken.contains(key) else { return nil }
        return key
    }

    /// Resolve shortcuts for a whole ordered menu in one pass.
    ///
    /// Returns plugin id → assigned key for the plugins that got one. Earlier entries
    /// win, matching the list order the menu renders in — the same first-wins rule
    /// `PluginDiscovery` already uses for id collisions, so the host has ONE
    /// precedence story rather than two.
    public static func assign(
        requests: [(id: String, keyEquivalent: String?)]
    ) -> [String: String] {
        var taken = reserved
        var assigned: [String: String] = [:]
        for request in requests {
            guard let key = assignable(request.keyEquivalent, taken: taken) else { continue }
            assigned[request.id] = key
            taken.insert(key)
        }
        return assigned
    }
}

/// How a plugin's code is expected to be executed by the host.
///
/// The host implements exactly ONE of these (`builtIn`). The other cases exist so
/// the manifest schema doesn't have to change when a real loader lands, and so the
/// Plugins pane can honestly tell the user that a discovered external plugin is
/// listed but NOT runnable.
public enum PluginEntryKind: String, Codable, Equatable, Sendable, CaseIterable {

    /// Compiled into the app from `plugins/<id>/` and declared in `PluginRegistry`.
    case builtIn

    /// A MANIFEST-DRIVEN plugin: a step list the host executes over the input text.
    /// Runnable from the external plugins directory — this is the tier that delivers
    /// install-without-rebuild (docs/PLUGINS.md § "Path to hot-swappable" §1).
    ///
    /// No third-party code enters this process. Every step is an action the host
    /// already performs for the user (`summarizeResolved`, `FileOutputTarget`,
    /// `ScriptRunner`, the text inserter), so the entitlement objection that rules out
    /// `dynamicLibrary` does not apply: a script plugin composes capabilities the user
    /// consented to and cannot reach past them. The one step that DOES execute code —
    /// `runScript` — is bounded to the plugin's own directory and carries its own
    /// separate consent. See `PluginScriptPlan`.
    case script

    /// A dynamically-loaded bundle. NOT IMPLEMENTED — loading third-party native
    /// code into a signed, entitled, mic-and-Accessibility-holding app inherits every
    /// one of those entitlements, so this needs a real security story first.
    case dynamicLibrary

    /// An out-of-process helper spoken to over the existing agent-bridge/MCP wire.
    /// NOT IMPLEMENTED — the likeliest real answer (it sandboxes naturally), but out
    /// of scope today — see docs/PLUGINS.md 'Path to hot-swappable'.
    case externalProcess

    /// An entry kind this build does not know — a manifest written for a NEWER
    /// OpenWhisp. Never written by a manifest author; produced only by decoding an
    /// unrecognized value, so such a plugin is LISTED and refused with a reason rather
    /// than disappearing from the pane. See `PluginManifest.init(from:)`.
    case unsupported

    /// Whether the host can run this kind of plugin today.
    ///
    /// `.script` joins `.builtIn` here, and the two are runnable for opposite reasons:
    /// a built-in is trusted because it was compiled in and reviewed; a script plugin,
    /// because it cannot do anything the host doesn't do on its behalf.
    public var isRunnable: Bool { self == .builtIn || self == .script }

    /// Why a non-runnable plugin can't run, shown in the Plugins pane.
    public var unavailableReason: String? {
        switch self {
        case .builtIn, .script:
            return nil
        case .unsupported:
            return "This plugin needs a newer version of OpenWhisp — it uses a kind of entry point this version doesn't support."
        case .dynamicLibrary:
            return "Loadable plugin bundles aren't supported — OpenWhisp only runs plugins compiled into the app."
        case .externalProcess:
            return "Out-of-process plugins aren't supported yet — OpenWhisp currently runs only plugins compiled into the app."
        }
    }
}
