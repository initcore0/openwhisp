import Foundation

/// Which plugins the user has turned on.
///
/// Plugins are OPTIONAL and **off by default**: installing the app must not silently
/// add surfaces, network calls, or menu rows the user never asked for. A plugin only
/// appears as a tab/menu entry after it is explicitly enabled in Settings → Plugins.
///
/// The enabled set lives on this type's OWN UserDefaults key rather than as a
/// `@Published` property on AppState — the MAK-32 AppState LOC ratchet is at its
/// budget, and the established dodge (see `ScratchpadWindowController`'s AI-model
/// overrides and `TranslationPreviewController`) is to keep new storage on the
/// feature's own type. `PluginHost` owns the observable wrapper for the UI.
///
/// Foundation-only, and the store is injected, so `swift test` pins the default-off
/// rule, the round-trip, and the sanitization without touching real user defaults.
public struct PluginEnablement: Equatable, Sendable {

    /// The single defaults key holding the enabled ids (an array of strings; a Set
    /// isn't a plist type). Namespaced like the app's other feature keys.
    public static let defaultsKey = "openwhisp.plugins.enabledIDs"

    private var enabled: Set<String>

    public init(enabled: Set<String> = []) {
        self.enabled = enabled
    }

    /// Whether a plugin id is turned on. Unknown ids are off — the default-off rule.
    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) }

    /// The enabled ids, sorted for a stable persisted representation (so writing
    /// unchanged state can't churn the defaults file).
    public var enabledIDs: [String] { enabled.sorted() }

    public mutating func setEnabled(_ isEnabled: Bool, for id: String) {
        if isEnabled { enabled.insert(id) } else { enabled.remove(id) }
    }

    /// Drop ids that no longer correspond to an available plugin.
    ///
    /// Without this, uninstalling a plugin and reinstalling it later would silently
    /// come back ENABLED, re-adding a surface (and possibly network access) the user
    /// last saw disappear. Prune on load so re-appearing means re-consenting.
    public mutating func prune(toAvailable availableIDs: Set<String>) {
        enabled.formIntersection(availableIDs)
    }

    /// The subset of `discovered` the host should surface as active tabs/menu rows:
    /// enabled AND actually runnable. An external plugin can be toggled on in the
    /// pane, but the host still won't open a window for it — being enabled is not
    /// the same as being loadable, and conflating the two is how a system starts
    /// lying about what it can do.
    public func activePlugins(
        from discovered: [PluginDiscovery.Discovered]
    ) -> [PluginDiscovery.Discovered] {
        discovered.filter { isEnabled($0.id) && $0.isRunnable }
    }

    // MARK: - Persistence

    /// The minimal slice of UserDefaults this store needs, so tests can supply a
    /// dictionary-backed fake instead of polluting the real domain.
    public protocol Store: AnyObject {
        func stringArray(forKey key: String) -> [String]?
        func set(_ value: Any?, forKey key: String)
    }

    /// Load the enabled set, pruned to what's actually available.
    public static func load(
        from store: Store,
        availableIDs: Set<String>
    ) -> PluginEnablement {
        var state = PluginEnablement(
            enabled: Set(store.stringArray(forKey: defaultsKey) ?? []))
        state.prune(toAvailable: availableIDs)
        return state
    }

    /// Persist the enabled set.
    public func save(to store: Store) {
        store.set(enabledIDs, forKey: Self.defaultsKey)
    }
}

extension UserDefaults: PluginEnablement.Store {}
