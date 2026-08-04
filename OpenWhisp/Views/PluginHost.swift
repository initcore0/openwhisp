import AppKit
import SwiftUI

/// The app-side plugin host.
///
/// Owns everything about plugins that AppState would otherwise have to: the
/// discovered list, the enabled set, and the windows enabled plugins open. AppState
/// gains exactly ONE line for this feature (a `lazy var pluginHost`) because the
/// MAK-32 ratchet is at zero headroom — same reason `ScratchpadWindowController` and
/// `TranslationPreviewController` keep their own storage.
///
/// A singleton because the menu bar, the Settings pane, and the plugin windows all
/// need the same enabled set, and none of them share an owner.
///
/// **What this is not:** a loader. It enumerates a compile-time registry plus any
/// manifests dropped on disk, and can open windows only for the former. See
/// `PluginRegistry` for why (the app holds Accessibility + mic + clipboard rights).
@MainActor
final class PluginHost: ObservableObject {

    static let shared = PluginHost()

    /// Every plugin the host knows about, built-in and discovered-on-disk.
    @Published private(set) var discovered: [PluginDiscovery.Discovered] = []

    /// The enabled set. Published so the pane's toggles and the menu bar stay in
    /// sync; persisted through `PluginEnablement` on its own defaults key.
    @Published private(set) var enablement = PluginEnablement()

    /// One window per plugin id, created on first open and reused after.
    private var windows: [String: NSWindowController] = [:]

    private init() {
        reload()
    }

    // MARK: - Discovery

    /// Re-enumerate plugins and re-load the (pruned) enabled set.
    ///
    /// Called at init and whenever the Plugins pane appears, so dropping a folder
    /// into the plugins directory shows up without relaunching.
    func reload() {
        discovered = PluginDiscovery.merge(providers: Self.providers)
        enablement = PluginEnablement.load(
            from: UserDefaults.standard,
            availableIDs: Set(discovered.map(\.id)))
    }

    /// The manifest sources, in DESCENDING trust order (earlier wins an id
    /// collision, so a writable directory can never shadow a reviewed plugin).
    ///
    /// The compile-time registry is deliberately just ONE entry here. The
    /// install-a-folder provider below is the real hot-swap story: it re-reads the
    /// filesystem on every `reload()`, so an installed plugin appears without
    /// rebuilding — and, once a loader exists, without relaunching either. Shipping
    /// hot-swappable plugins means adding a provider and a runner, not restructuring
    /// the host. See the PR's "Path to hot-swappable" section.
    private static var providers: [PluginDiscovery.Provider] {
        [
            .init(source: .builtIn) { PluginRegistry.builtInManifests },
            .init(source: .external) {
                PluginDiscovery.loadExternalManifests(in: PluginHost.externalDirectory)
            },
        ]
    }

    /// `~/Library/Application Support/OpenWhisp/Plugins`.
    ///
    /// `nonisolated` because the discovery providers read it from a `@Sendable`
    /// closure: it only derives a path from the filesystem and touches no host state.
    nonisolated static var externalDirectory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return PluginDiscovery.externalPluginsDirectory(applicationSupport: support)
    }

    // MARK: - Enablement

    func isEnabled(_ id: String) -> Bool { enablement.isEnabled(id) }

    /// Turn a plugin on or off and persist immediately.
    ///
    /// Disabling closes any window the plugin had open: a disabled plugin should not
    /// keep a surface alive, and leaving a stale window up is how a user ends up
    /// interacting with something they just switched off.
    func setEnabled(_ isEnabled: Bool, for id: String) {
        enablement.setEnabled(isEnabled, for: id)
        enablement.save(to: UserDefaults.standard)
        if !isEnabled { closeWindow(for: id) }
    }

    /// The plugins that should appear as tabs / menu rows: enabled AND runnable.
    var activePlugins: [PluginDiscovery.Discovered] {
        enablement.activePlugins(from: discovered)
    }

    // MARK: - Windows

    /// Open (or focus) a plugin's window.
    ///
    /// Refuses anything not enabled AND runnable, so a stale menu row or a
    /// hand-crafted call can't surface a plugin the user hasn't turned on.
    func open(pluginID: String) {
        guard let plugin = activePlugins.first(where: { $0.id == pluginID }) else { return }

        if let existing = windows[pluginID] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // v5: tell the controller it is being SHOWN AGAIN.
            //
            // This is the fix for "template downloads stop working after a day". The
            // controller is cached for the app's lifetime and reused on every open, so
            // a plugin that did its open-time work in `init` did it exactly ONCE. The
            // Meme Generator closes over that: `windowWillClose` sets its model's
            // `isCancelled = true` to stop a late result touching a dead window, and
            // only `windowDidOpen` clears it — which, reached from `init` alone, never
            // ran again. Every download after the first close therefore returned
            // through a guard that dropped it, silently and permanently.
            (existing as? PluginWindowLifecycle)?.pluginWindowWillShow()
            return
        }

        guard let controller = Self.makeWindowController(for: plugin) else { return }
        windows[pluginID] = controller
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The live window controller for a plugin, if one has been opened.
    ///
    /// Exists for the v9 runtime probe, which must reach the SAME cached controller
    /// `open(pluginID:)` created rather than build a parallel one.
    func windowController(for pluginID: String) -> NSWindowController? {
        windows[pluginID]
    }

    private func closeWindow(for id: String) {
        windows[id]?.window?.close()
        windows[id] = nil
    }

    /// Map a built-in plugin id to its window. The second of the two places a
    /// built-in plugin is wired (the first is `PluginRegistry`).
    private static func makeWindowController(
        for plugin: PluginDiscovery.Discovered
    ) -> NSWindowController? {
        switch plugin.id {
        #if OPENWHISP_PLUGINS
        case PluginRegistry.memeGenerator.id:
            return MemeGeneratorWindowController()
        #endif
        default:
            // Either the plugin's sources weren't compiled into this build
            // (a PLUGINS=0 build) or the id has no window. Both are honest
            // no-ops rather than a crash.
            return nil
        }
    }

    // MARK: - Dictation seam

    /// Offer a completed dictation to whichever plugin window is frontmost.
    ///
    /// Mirrors `ScratchpadWindowController.appendDictationIfKey`: returns whether a
    /// plugin took the text, so AppState skips its focused-app insert. The
    /// focused-app paste path deliberately declines while OUR app is frontmost, so
    /// without this a dictation aimed at a plugin window would be lost.
    ///
    /// Only ONE window can be key, so at most one plugin can accept.
    @discardableResult
    func appendDictationIfKey(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for controller in windows.values {
            if let sink = controller as? PluginDictationSink,
               sink.appendDictationIfKey(text) {
                return true
            }
        }
        return false
    }
}

/// A plugin window that needs to know when it is shown again.
///
/// Plugin window controllers are created once and REUSED — `PluginHost` caches them so
/// reopening restores the user's window rather than throwing their work away. That
/// makes `init` the wrong place for anything that must be true on every open, and the
/// wrong-place-ness is invisible until a plugin also does teardown on close: the
/// teardown then runs N times against exactly one setup.
///
/// This seam is the missing half. A controller adopting it gets told about every
/// subsequent show, so "prepare to be used" and "stop touching me" stay balanced no
/// matter how many times the user opens and closes the window.
@MainActor
protocol PluginWindowLifecycle: AnyObject {
    /// The window is about to be brought forward again after having been created.
    /// Not called for the first show — `init` already covers that.
    func pluginWindowWillShow()
}

/// A plugin window that can receive dictation when it is the key window.
///
/// This is the seam the Scratchpad hardcodes on AppState, generalized just enough
/// for plugins — a plugin surface with a text field wants dictation to land in it
/// exactly the way the Scratchpad does.
@MainActor
protocol PluginDictationSink: AnyObject {
    /// Append a completed dictation IF this window is key. Returns whether it took
    /// the text.
    @discardableResult
    func appendDictationIfKey(_ text: String) -> Bool
}
