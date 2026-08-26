import Foundation

/// Finds the plugins available to the host and decides which ones win.
///
/// Two sources, merged with a fixed precedence:
///
/// 1. **Built-in** — the compile-time list handed in by `PluginRegistry`. These are
///    in-repo plugins under `plugins/<id>/`, reviewed and maintained alongside the
///    app, and are the only ones that can actually RUN today.
/// 2. **External** — `~/Library/Application Support/OpenWhisp/Plugins/<id>/manifest.json`.
///    Discovered and listed so the pane can show the user what's on disk, but flagged
///    non-runnable (no loader exists).
///
/// **Built-in always wins a conflicting id.** A dropped-in folder must never be able
/// to shadow a reviewed in-repo plugin — that would turn a writable directory into
/// code-substitution against a mic-and-Accessibility-entitled app. The host cannot
/// execute external plugins at all, so this is belt-and-braces today, but the
/// precedence is the part worth pinning now because a future loader inherits it.
///
/// Foundation-only: every rule here (validation rejects, precedence, sort order,
/// malformed-JSON tolerance) is covered by `swift test`.
public enum PluginDiscovery {

    /// A discovered plugin plus where it came from.
    public struct Discovered: Equatable, Sendable, Identifiable {
        public let manifest: PluginManifest
        public let source: Source

        public var id: String { manifest.id }

        public init(manifest: PluginManifest, source: Source) {
            self.manifest = manifest
            self.source = source
        }

        /// Whether the host can actually run this plugin.
        ///
        /// Two disjoint routes, and the asymmetry is the security property:
        ///
        /// - **Built-in** — compiled in and reviewed, so it may declare `.builtIn` and
        ///   get a window.
        /// - **External** — a folder on disk may run ONLY as a `.script` plugin, whose
        ///   every action the host performs itself. It can never run as `.builtIn`,
        ///   whatever its manifest claims: **a manifest cannot promote itself** into
        ///   compiled code, and an on-disk folder declaring `.builtIn` names a Swift
        ///   type that would have to already exist in this binary.
        ///
        /// So a dropped-in folder gained exactly one capability — composing host
        /// actions — and gained no path at all to the in-process execution
        /// docs/ROADMAP.md §6 rules out.
        public var isRunnable: Bool {
            switch source {
            case .builtIn: return manifest.entry.isRunnable
            case .external: return manifest.entry == .script
            }
        }

        /// Why this plugin can't run, if it can't.
        public var unavailableReason: String? {
            guard !isRunnable else { return nil }
            if source == .external, manifest.entry == .builtIn {
                return "Installed plugins can't be compiled into the app — only script plugins (\"entry\": \"script\") can be installed this way."
            }
            return manifest.entry.unavailableReason
        }
    }

    public enum Source: String, Equatable, Sendable {
        /// Compiled into the app from `plugins/<id>/`.
        case builtIn
        /// Found on disk under Application Support.
        case external
    }

    /// The directory external plugins are discovered from.
    public static func externalPluginsDirectory(
        applicationSupport: URL
    ) -> URL {
        applicationSupport
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    /// One source of plugin manifests.
    ///
    /// The host enumerates an ORDERED list of these rather than knowing about any
    /// particular source, so the compile-time registry is just one provider among
    /// others. This is the seam that keeps the design honest about being
    /// hot-swappable: adding a real installation path (a downloaded bundle
    /// directory, a per-user plugins folder, an out-of-process helper that
    /// advertises itself) means adding a provider, not changing the host.
    public struct Provider: Sendable {
        public let source: Source
        /// Produce the manifests this source currently offers. Called on every
        /// `reload`, so a provider backed by the filesystem picks up installs
        /// without an app restart.
        public let manifests: @Sendable () -> [PluginManifest]

        public init(source: Source, manifests: @escaping @Sendable () -> [PluginManifest]) {
            self.source = source
            self.manifests = manifests
        }
    }

    /// Merge an ordered list of providers into the host's plugin list.
    ///
    /// - Invalid manifests are dropped (a plugin with no name/symbol or a
    ///   traversal-shaped id is not listable).
    /// - **Later providers lose an id collision to earlier ones.** Callers pass
    ///   providers in DESCENDING trust order, so a lower-trust source can never
    ///   shadow a higher-trust one — the property that stops a writable directory
    ///   from substituting code into an app holding Accessibility + mic rights.
    /// - Result is sorted by display name, then id, so the pane's order is stable
    ///   across launches and independent of filesystem enumeration order.
    public static func merge(providers: [Provider]) -> [Discovered] {
        var byID: [String: Discovered] = [:]

        for provider in providers {
            for manifest in provider.manifests() where manifest.isValid {
                // First provider to claim an id keeps it.
                guard byID[manifest.id] == nil else { continue }
                byID[manifest.id] = Discovered(manifest: manifest, source: provider.source)
            }
        }

        return byID.values.sorted {
            if $0.manifest.name != $1.manifest.name {
                return $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
            }
            return $0.manifest.id < $1.manifest.id
        }
    }

    /// Convenience for the two sources that exist today, in trust order.
    public static func merge(
        builtIn: [PluginManifest],
        external: [PluginManifest]
    ) -> [Discovered] {
        merge(providers: [
            Provider(source: .builtIn) { builtIn },
            Provider(source: .external) { external },
        ])
    }

    /// The directory one external plugin lives in: `<root>/<id>`.
    ///
    /// The id has already been validated as a safe path component (`PluginManifest`
    /// refuses traversal-shaped ids), and this is the ONLY place that join happens, so
    /// the runner cannot accidentally build the path a different way.
    public static func pluginDirectory(id: String, in root: URL) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    /// Re-read ONE plugin's manifest from disk, right now.
    ///
    /// The runner calls this at invocation time instead of using the manifest captured
    /// when the pane last listed. Editing `manifest.json` and running the plugin again
    /// therefore picks up the edit with no reload, no relaunch, and no rebuild — which
    /// is the hot-swap promise, and the specific bug this repo has already shipped once
    /// (a plugin serving a cached value long after the source of truth changed).
    ///
    /// Returns nil when the folder is gone, the JSON is malformed, the manifest is
    /// invalid, or it claims an id other than its own directory — the same rules
    /// `loadExternalManifests` applies, kept in one place so a plugin cannot be run
    /// under looser validation than it was listed under.
    public static func reloadManifest(
        id: String,
        in root: URL,
        fileManager: FileManager = .default
    ) -> PluginManifest? {
        guard PluginManifest.isSafePathComponent(id) else { return nil }
        let url = pluginDirectory(id: id, in: root)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
              manifest.isValid,
              manifest.id == id
        else { return nil }
        return manifest
    }

    /// Read every `<dir>/<id>/manifest.json` under an external plugins directory.
    ///
    /// Tolerant by design: a malformed or unreadable manifest is SKIPPED, never
    /// thrown — one bad third-party folder must not stop the Plugins pane from
    /// listing the good ones (the same fail-soft posture `JSONStore` takes).
    /// A manifest whose `id` disagrees with its containing directory name is
    /// rejected, so a folder can't claim to be a different plugin than where it sits.
    public static func loadExternalManifests(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [PluginManifest] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        var manifests: [PluginManifest] = []

        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let manifestURL = entry.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(PluginManifest.self, from: data),
                  manifest.isValid,
                  // The directory name is the authority on identity.
                  manifest.id == entry.lastPathComponent
            else { continue }

            manifests.append(manifest)
        }

        return manifests
    }
}
