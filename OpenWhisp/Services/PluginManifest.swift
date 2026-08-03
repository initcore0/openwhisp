import Foundation

/// The declarative description of an OpenWhisp plugin (spike: `spike/plugin-system`).
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
///   literal so it can never go missing at runtime. This is what the spike uses.
/// - **External** — a manifest discovered on disk at
///   `~/Library/Application Support/OpenWhisp/Plugins/<id>/manifest.json`. The
///   spike DISCOVERS and LISTS these but cannot execute them: there is no loader.
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
    /// This is an HONEST LABEL, not a sandbox — nothing enforces it in the spike.
    /// A real third-party plugin system would need the enforcement to live outside
    /// the plugin's own manifest (see the PR's security notes).
    public let networkHosts: [String]

    /// The single character this plugin would like as its ⌘-shortcut in the menu bar
    /// (v5), e.g. `"m"` → ⌘M opens the Meme Generator's window.
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

    public init(
        id: String,
        name: String,
        version: String,
        summary: String,
        symbol: String,
        entry: PluginEntryKind,
        networkHosts: [String] = [],
        keyEquivalent: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.symbol = symbol
        self.entry = entry
        self.networkHosts = networkHosts
        self.keyEquivalent = keyEquivalent
    }

    /// Forward-compatible decode: `networkHosts` and `keyEquivalent` are optional in
    /// the JSON, so an older manifest (and a hand-written one) decodes rather than
    /// failing the whole plugin out of the list over a missing key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        symbol = try container.decode(String.self, forKey: .symbol)
        entry = try container.decodeIfPresent(PluginEntryKind.self, forKey: .entry) ?? .builtIn
        networkHosts = try container.decodeIfPresent([String].self, forKey: .networkHosts) ?? []
        keyEquivalent = try container.decodeIfPresent(String.self, forKey: .keyEquivalent)
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

    // MARK: - Validation

    /// Why a decoded manifest was rejected.
    public enum ValidationError: Equatable, Sendable {
        case emptyID
        case invalidID(String)
        case emptyName
        case emptySymbol
        /// The manifest asked for a shortcut that isn't a single character (v5).
        case invalidKeyEquivalent(String)
    }

    /// Characters allowed in an id: lowercase alphanumerics plus `-` and `.`.
    /// Deliberately strict — the id becomes a PATH COMPONENT under Application
    /// Support, so anything that could traverse (`/`, `..`, NUL) must be rejected
    /// before it is ever joined onto a directory URL.
    private static let allowedIDCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")

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
        return nil
    }

    /// Whether the host can LIST and run this manifest.
    ///
    /// Deliberately more permissive than `validate() == nil`: only the structural
    /// failures disqualify a plugin. An unusable `keyEquivalent` costs the plugin its
    /// shortcut (`keyEquivalentDisplay` returns nil, and the menu assigns nothing) and
    /// nothing else.
    public var isValid: Bool {
        switch validate() {
        case nil, .invalidKeyEquivalent: return true
        default: return false
        }
    }
}

/// Who gets a ⌘-shortcut in the menu bar, and who is refused (v5).
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
/// The spike implements exactly ONE of these (`builtIn`). The other cases exist so
/// the manifest schema doesn't have to change when a real loader lands, and so the
/// Plugins pane can honestly tell the user that a discovered external plugin is
/// listed but NOT runnable.
public enum PluginEntryKind: String, Codable, Equatable, Sendable, CaseIterable {

    /// Compiled into the app from `plugins/<id>/` and declared in `PluginRegistry`.
    /// The only kind the host can actually run today.
    case builtIn

    /// A dynamically-loaded bundle. NOT IMPLEMENTED — loading third-party native
    /// code into a signed, entitled, mic-and-Accessibility-holding app inherits every
    /// one of those entitlements, so this needs a real security story first.
    case dynamicLibrary

    /// An out-of-process helper spoken to over the existing agent-bridge/MCP wire.
    /// NOT IMPLEMENTED — the likeliest real answer (it sandboxes naturally), but out
    /// of scope for the spike.
    case externalProcess

    /// Whether the host can run this kind of plugin today.
    public var isRunnable: Bool { self == .builtIn }

    /// Why a non-runnable plugin can't run, shown in the Plugins pane.
    public var unavailableReason: String? {
        switch self {
        case .builtIn:
            return nil
        case .dynamicLibrary:
            return "Loadable plugin bundles aren't supported yet — this prototype only runs plugins compiled into the app."
        case .externalProcess:
            return "Out-of-process plugins aren't supported yet — this prototype only runs plugins compiled into the app."
        }
    }
}
