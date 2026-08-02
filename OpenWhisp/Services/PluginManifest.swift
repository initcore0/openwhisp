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

    public init(
        id: String,
        name: String,
        version: String,
        summary: String,
        symbol: String,
        entry: PluginEntryKind,
        networkHosts: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.symbol = symbol
        self.entry = entry
        self.networkHosts = networkHosts
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
        return nil
    }

    public var isValid: Bool { validate() == nil }
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
