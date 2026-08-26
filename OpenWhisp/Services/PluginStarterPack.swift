import Foundation

/// The **starter pack**: a handful of script plugins that ship inside the app bundle and
/// install into the user's plugins directory in one click (MAK-101).
///
/// ## Why they install rather than just run
///
/// The obvious shortcut would be a third `PluginDiscovery.Provider` reading straight out
/// of `Contents/Resources/StarterPlugins/`. That is deliberately NOT what this does. A
/// bundled provider would make the starter plugins a private, read-only tier that proves
/// nothing about the tier third parties actually use — and this repo's own history says a
/// path exercised only by its author is a path that quietly breaks. So a starter plugin
/// takes the SAME route a downloaded one does: it is copied into
/// `~/Library/Application Support/OpenWhisp/Plugins/<id>/`, discovered by the ordinary
/// external provider, enabled in the ordinary pane, and run by the ordinary runner.
///
/// The copy is also what makes the plugin the USER'S. Once installed it is an editable
/// folder on their disk — change a prompt, change the file path, delete it — which is the
/// whole promise of the script tier. A read-only bundled plugin would be a feature with
/// a manifest, not a plugin.
///
/// ## Why the decision layer is here and not in the pane
///
/// Everything below is a pure function of a directory listing: which folders are
/// offerable, which are already installed, what happens on an id collision, and whether
/// an id is safe to join onto a URL. The app layer does the two things that genuinely
/// need the filesystem — enumerate a directory, copy a tree — and asks this for every
/// decision in between.
///
/// That split is the same one `PluginScriptPlan` makes, for the same reason: `PluginsPane`
/// and `PluginHost` sit OUTSIDE `swift test`, so a rule left in the view is a rule nobody
/// checks. The specific rule worth protecting here is **never overwrite** — a starter
/// install that clobbered an edited plugin folder would destroy user work silently, and
/// that is not a behavior to leave to a view's `if`.
///
/// Foundation-only, registered in `Package.swift`'s `OpenWhispCore` sources.
public enum PluginStarterPack {

    /// The bundle-relative directory the pack is packaged into.
    ///
    /// `package.sh` copies `OpenWhisp/Resources/*` into `Contents/Resources/`, so the
    /// in-repo `OpenWhisp/Resources/StarterPlugins/` arrives here untouched — the pack
    /// needs no bundling step of its own, which is one fewer script that can silently
    /// stop copying.
    public static let bundleSubdirectory = "StarterPlugins"

    // MARK: - An offerable plugin

    /// One starter plugin as the pane offers it: its manifest, where it is copied from,
    /// and whether the user already has it.
    public struct Offering: Equatable, Sendable, Identifiable {

        /// The manifest read out of the bundled folder. The pane renders the name,
        /// summary, and symbol from THIS rather than from a hardcoded list, so adding a
        /// starter plugin is adding a folder — no Swift change, no second source of truth
        /// to drift.
        public let manifest: PluginManifest

        /// The bundled folder to copy. Absolute.
        public let sourceDirectory: URL

        /// Whether a folder with this id already exists in the user's plugins directory.
        ///
        /// Note what this does NOT claim: that the installed copy came from this pack, or
        /// that it matches this version. It cannot know either, and pretending otherwise
        /// is how an "update" button ends up overwriting a plugin the user wrote. The
        /// only question the pack is entitled to answer is "is that id taken".
        public let isInstalled: Bool

        public var id: String { manifest.id }

        public init(manifest: PluginManifest, sourceDirectory: URL, isInstalled: Bool) {
            self.manifest = manifest
            self.sourceDirectory = sourceDirectory
            self.isInstalled = isInstalled
        }
    }

    // MARK: - Install decisions

    /// What the pane should do when the user asks to install a starter plugin.
    ///
    /// A `Result`-shaped verdict rather than a bare `Bool` so the refusal carries its own
    /// user-facing reason — the pane never composes one, for the same reason it never
    /// composes a consent disclosure.
    public enum InstallDecision: Equatable, Sendable {

        /// Copy `source` to `destination`. The destination is guaranteed not to exist.
        case copy(source: URL, destination: URL)

        /// Do nothing, and say why.
        case refuse(Refusal)

        /// Whether this decision performs a copy — the thing the app layer branches on.
        public var isCopy: Bool {
            if case .copy = self { return true }
            return false
        }

        /// The refusal, if this is one.
        public var refusal: Refusal? {
            if case .refuse(let refusal) = self { return refusal }
            return nil
        }
    }

    /// Why an install was refused. Every case is a sentence the pane shows verbatim.
    public enum Refusal: Equatable, Sendable {

        /// A folder with this id already exists in the user's plugins directory.
        ///
        /// This is the ORDINARY outcome, not an error: the user has the plugin, possibly
        /// with their own edits in it, and their copy wins. Reinstalling means deleting
        /// the folder first, which is a deliberate act in the Finder rather than a button
        /// that can be clicked by accident.
        case alreadyInstalled(id: String)

        /// The id in the bundled manifest isn't safe to use as a path component.
        ///
        /// Re-checked HERE even though `PluginManifest.validate` already rejects such
        /// ids, because this is the moment the id becomes a directory that gets WRITTEN
        /// to. A traversal-shaped id reaching a copy destination would write outside the
        /// plugins folder entirely, and "validation happened earlier" is not a property
        /// to depend on at a call site with side effects. Same reasoning
        /// `PluginScriptPath` gives for checking containment twice.
        case unsafeIdentifier(id: String)

        /// The bundled manifest doesn't describe a runnable script plugin. A pack entry
        /// that couldn't run once installed has no business being offered.
        case notAScriptPlugin(id: String)

        public var reason: String {
            switch self {
            case .alreadyInstalled(let id):
                return "“\(id)” is already in your plugins folder — delete it there first if you want a fresh copy."
            case .unsafeIdentifier(let id):
                return "This starter plugin's identifier (“\(id)”) isn't a usable folder name."
            case .notAScriptPlugin(let id):
                return "“\(id)” isn't a script plugin, so installing it wouldn't give you anything runnable."
            }
        }
    }

    /// Decide whether one offering may be installed into `destinationRoot`.
    ///
    /// Pure: `isInstalled` is the caller's already-taken filesystem reading, and the
    /// destination URL is derived through `PluginDiscovery.pluginDirectory` — the single
    /// place an id becomes a plugin folder — rather than joined here a second way.
    public static func decide(
        _ offering: Offering,
        destinationRoot: URL
    ) -> InstallDecision {
        let id = offering.manifest.id
        guard PluginManifest.isSafePathComponent(id) else {
            return .refuse(.unsafeIdentifier(id: id))
        }
        guard offering.manifest.entry == .script else {
            return .refuse(.notAScriptPlugin(id: id))
        }
        guard !offering.isInstalled else {
            return .refuse(.alreadyInstalled(id: id))
        }
        return .copy(
            source: offering.sourceDirectory,
            destination: PluginDiscovery.pluginDirectory(id: id, in: destinationRoot))
    }

    // MARK: - Enumerating the pack

    /// Read the bundled pack, marking which entries the user already has.
    ///
    /// Tolerant in exactly the way `PluginDiscovery.loadExternalManifests` is: a folder
    /// with no manifest, a malformed one, or one whose id disagrees with its directory
    /// name is SKIPPED rather than thrown. A broken entry must not empty the whole
    /// starter list — and the id/directory agreement matters more here than anywhere,
    /// because the directory name is what the install writes to.
    ///
    /// Sorted by display name then id, matching `PluginDiscovery.merge`, so the pack's
    /// order is stable and independent of filesystem enumeration order.
    ///
    /// - Parameters:
    ///   - packDirectory: the bundled `StarterPlugins` folder.
    ///   - installedIDs: ids already present in the user's plugins directory.
    public static func offerings(
        in packDirectory: URL,
        installedIDs: Set<String>,
        fileManager: FileManager = .default
    ) -> [Offering] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: packDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        var offerings: [Offering] = []

        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            guard let data = try? Data(
                    contentsOf: entry.appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(PluginManifest.self, from: data),
                  manifest.isValid,
                  // The directory name is the authority on identity — the same rule the
                  // external loader applies, and the reason a pack folder cannot install
                  // itself under someone else's id.
                  manifest.id == entry.lastPathComponent
            else { continue }

            offerings.append(
                Offering(
                    manifest: manifest,
                    sourceDirectory: entry,
                    isInstalled: installedIDs.contains(manifest.id)))
        }

        return offerings.sorted {
            if $0.manifest.name != $1.manifest.name {
                return $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name)
                    == .orderedAscending
            }
            return $0.manifest.id < $1.manifest.id
        }
    }

    /// The script filenames a starter plugin ships that must be executable once copied.
    ///
    /// The app layer restores the executable bit on exactly these after copying. It is
    /// stated here, derived from the manifest, rather than left as "chmod everything that
    /// looks like a script": a pack folder may legitimately carry a README or a sample
    /// file, and marking arbitrary copied files executable is not a habit to build into
    /// an install path.
    ///
    /// Only paths that pass `PluginScriptPath.validate` are returned, so this can never
    /// hand the app layer a name that would chmod something outside the plugin folder.
    public static func executableScriptNames(in manifest: PluginManifest) -> [String] {
        var names: [String] = []
        for step in manifest.steps where step.kind == .runScript {
            guard let raw = step.script?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  PluginScriptPath.validate(raw) == nil,
                  !names.contains(raw)
            else { continue }
            names.append(raw)
        }
        return names
    }
}
