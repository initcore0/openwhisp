import XCTest
@testable import OpenWhispCore

/// Covers the plugin system's pure layer (spike/plugin-system): manifest validation,
/// discovery precedence, and the enabled-set store.
final class PluginSystemTests: XCTestCase {

    // MARK: - Helpers

    private func manifest(
        id: String = "demo",
        name: String = "Demo",
        symbol: String = "puzzlepiece.extension",
        entry: PluginEntryKind = .builtIn,
        networkHosts: [String] = []
    ) -> PluginManifest {
        PluginManifest(
            id: id, name: name, version: "1.0.0", summary: "A demo plugin.",
            symbol: symbol, entry: entry, networkHosts: networkHosts)
    }

    /// Dictionary-backed `PluginEnablement.Store` so tests never touch the real
    /// UserDefaults domain.
    private final class FakeStore: PluginEnablement.Store {
        var values: [String: [String]] = [:]
        func stringArray(forKey key: String) -> [String]? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value as? [String] }
    }

    // MARK: - Manifest validation

    func testValidManifestPasses() {
        XCTAssertNil(manifest().validate())
        XCTAssertTrue(manifest().isValid)
    }

    func testEmptyIDIsRejected() {
        XCTAssertEqual(manifest(id: "").validate(), .emptyID)
    }

    /// The id becomes a path component under Application Support, so anything that
    /// could traverse out of the plugins directory must be refused before it is ever
    /// joined onto a URL.
    func testPathTraversalShapedIDsAreRejected() {
        for bad in ["..", ".", "../evil", "foo/bar", "foo bar", "Foo", "a\\b"] {
            XCTAssertEqual(
                manifest(id: bad).validate(), .invalidID(bad),
                "expected \(bad) to be rejected as an id")
        }
    }

    func testReverseDNSStyleIDIsAllowed() {
        XCTAssertNil(manifest(id: "app.openwhisp.meme-generator").validate())
    }

    func testEmptyNameAndSymbolAreRejected() {
        XCTAssertEqual(manifest(name: "   ").validate(), .emptyName)
        XCTAssertEqual(manifest(symbol: "").validate(), .emptySymbol)
    }

    // MARK: - Network disclosure

    func testLocalPluginHasNoNetworkDisclosure() {
        let local = manifest()
        XCTAssertFalse(local.usesNetwork)
        XCTAssertNil(local.networkDisclosure)
    }

    /// The app is local-first, so a plugin that reaches out must say so in the pane.
    func testNetworkPluginDisclosesEveryHost() {
        let net = manifest(networkHosts: ["api.imgflip.com", "i.imgflip.com"])
        XCTAssertTrue(net.usesNetwork)
        XCTAssertEqual(
            net.networkDisclosure,
            "Connects to api.imgflip.com, i.imgflip.com when you use it.")
    }

    // MARK: - Entry kinds

    func testOnlyBuiltInIsRunnable() {
        XCTAssertTrue(PluginEntryKind.builtIn.isRunnable)
        XCTAssertFalse(PluginEntryKind.dynamicLibrary.isRunnable)
        XCTAssertFalse(PluginEntryKind.externalProcess.isRunnable)
        XCTAssertNil(PluginEntryKind.builtIn.unavailableReason)
        XCTAssertNotNil(PluginEntryKind.dynamicLibrary.unavailableReason)
        XCTAssertNotNil(PluginEntryKind.externalProcess.unavailableReason)
    }

    // MARK: - Discovery merge

    func testMergeListsBothSourcesSortedByName() {
        let merged = PluginDiscovery.merge(
            builtIn: [manifest(id: "zebra", name: "Zebra")],
            external: [manifest(id: "alpha", name: "Alpha")])
        XCTAssertEqual(merged.map(\.id), ["alpha", "zebra"])
        XCTAssertEqual(merged.map(\.source), [.external, .builtIn])
    }

    /// A folder dropped into a user-writable directory must never shadow a reviewed
    /// in-repo plugin — that would be code substitution against an entitled app.
    func testBuiltInWinsIDCollisionWithExternal() {
        let merged = PluginDiscovery.merge(
            builtIn: [manifest(id: "meme-generator", name: "Real")],
            external: [manifest(id: "meme-generator", name: "Impostor")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .builtIn)
        XCTAssertEqual(merged[0].manifest.name, "Real")
    }

    func testInvalidManifestsAreDroppedFromMerge() {
        let merged = PluginDiscovery.merge(
            builtIn: [manifest(id: "..", name: "Traversal"), manifest(id: "ok")],
            external: [manifest(id: "bad", name: "")])
        XCTAssertEqual(merged.map(\.id), ["ok"])
    }

    /// Being enabled is not the same as being loadable: the spike lists external
    /// plugins but refuses to claim it can run them, whatever their manifest says.
    func testExternalPluginIsNeverRunnableEvenWhenItClaimsBuiltIn() {
        let merged = PluginDiscovery.merge(
            builtIn: [], external: [manifest(id: "sneaky", entry: .builtIn)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertFalse(merged[0].isRunnable)
        XCTAssertNotNil(merged[0].unavailableReason)
    }

    func testBuiltInPluginIsRunnable() {
        let merged = PluginDiscovery.merge(builtIn: [manifest()], external: [])
        XCTAssertTrue(merged[0].isRunnable)
        XCTAssertNil(merged[0].unavailableReason)
    }

    // MARK: - Discovery from disk

    func testLoadExternalManifestsReadsWellFormedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDiscoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func write(id: String, json: String) throws {
            let dir = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent("manifest.json"),
                           atomically: true, encoding: .utf8)
        }

        try write(id: "good", json: """
        {"id":"good","name":"Good","version":"1.0.0","summary":"s",
         "symbol":"star","entry":"externalProcess","networkHosts":[]}
        """)
        // Malformed JSON must be skipped, not thrown — one bad folder can't take the
        // whole pane down.
        try write(id: "broken", json: "{not json")
        // A folder whose manifest claims a different id is refused: the directory
        // name is the authority on identity.
        try write(id: "liar", json: """
        {"id":"someone-else","name":"Liar","version":"1.0.0","summary":"s",
         "symbol":"star","entry":"builtIn","networkHosts":[]}
        """)

        let found = PluginDiscovery.loadExternalManifests(in: root)
        XCTAssertEqual(found.map(\.id), ["good"])
    }

    func testLoadExternalManifestsToleratesMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-there-\(UUID().uuidString)")
        XCTAssertEqual(PluginDiscovery.loadExternalManifests(in: missing).count, 0)
    }

    func testExternalPluginsDirectoryPath() {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support")
        XCTAssertEqual(
            PluginDiscovery.externalPluginsDirectory(applicationSupport: support).path,
            "/Users/x/Library/Application Support/OpenWhisp/Plugins")
    }

    // MARK: - Enablement

    /// Plugins are optional surfaces; installing the app must not silently add them.
    func testPluginsAreDisabledByDefault() {
        let state = PluginEnablement()
        XCTAssertFalse(state.isEnabled("meme-generator"))
        XCTAssertEqual(state.enabledIDs, [])
    }

    func testToggleRoundTripsThroughStore() {
        let store = FakeStore()
        var state = PluginEnablement.load(from: store, availableIDs: ["a", "b"])
        state.setEnabled(true, for: "a")
        state.save(to: store)

        let reloaded = PluginEnablement.load(from: store, availableIDs: ["a", "b"])
        XCTAssertTrue(reloaded.isEnabled("a"))
        XCTAssertFalse(reloaded.isEnabled("b"))
    }

    func testDisablingRemovesFromPersistedSet() {
        let store = FakeStore()
        var state = PluginEnablement(enabled: ["a", "b"])
        state.setEnabled(false, for: "a")
        state.save(to: store)
        XCTAssertEqual(store.values[PluginEnablement.defaultsKey], ["b"])
    }

    /// Persisted order is sorted so writing unchanged state can't churn the defaults.
    func testPersistedIDsAreSorted() {
        let store = FakeStore()
        PluginEnablement(enabled: ["zebra", "alpha", "mid"]).save(to: store)
        XCTAssertEqual(store.values[PluginEnablement.defaultsKey], ["alpha", "mid", "zebra"])
    }

    /// A plugin that disappears and later comes back must come back OFF — otherwise
    /// removing it and reinstalling silently restores a surface (and its network
    /// access) the user last saw gone.
    func testPruneDropsUnavailablePlugins() {
        let store = FakeStore()
        PluginEnablement(enabled: ["gone", "still-here"]).save(to: store)

        let loaded = PluginEnablement.load(from: store, availableIDs: ["still-here"])
        XCTAssertFalse(loaded.isEnabled("gone"))
        XCTAssertTrue(loaded.isEnabled("still-here"))
    }

    /// Enabled + runnable is the bar for getting a tab. An enabled-but-unloadable
    /// external plugin must not produce a menu row the host can't service.
    func testActivePluginsRequireEnabledAndRunnable() {
        let discovered = PluginDiscovery.merge(
            builtIn: [manifest(id: "built-in", name: "Built In")],
            external: [manifest(id: "external", name: "External")])

        var state = PluginEnablement()
        state.setEnabled(true, for: "built-in")
        state.setEnabled(true, for: "external")

        XCTAssertEqual(state.activePlugins(from: discovered).map(\.id), ["built-in"])
    }

    func testDisabledBuiltInIsNotActive() {
        let discovered = PluginDiscovery.merge(builtIn: [manifest(id: "x")], external: [])
        XCTAssertEqual(PluginEnablement().activePlugins(from: discovered).count, 0)
    }

    // MARK: - Registry

    func testRegistryShipsTheMemeGeneratorAndItIsValid() {
        let ids = PluginRegistry.builtInManifests.map(\.id)
        XCTAssertTrue(ids.contains("meme-generator"))
        for m in PluginRegistry.builtInManifests {
            XCTAssertNil(m.validate(), "built-in manifest \(m.id) is invalid")
            XCTAssertEqual(m.entry, .builtIn)
        }
    }

    /// The registry's manifest literal and the checked-in
    /// `plugins/meme-generator/manifest.json` must not drift: the JSON is the
    /// authored source of truth and the schema example external plugins copy, while
    /// the literal is what actually ships (a built-in plugin must not be able to go
    /// missing because a resource wasn't bundled).
    func testCheckedInManifestJSONMatchesTheRegistryLiteral() throws {
        // Tests/OpenWhispCoreTests/<this file> -> repo root
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenWhispCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = repoRoot
            .appendingPathComponent("plugins/MemeGenerator/manifest.json")

        let data = try Data(contentsOf: url)
        let fromDisk = try JSONDecoder().decode(PluginManifest.self, from: data)
        XCTAssertEqual(fromDisk, PluginRegistry.memeGenerator)
    }

    /// The meme plugin uses the network, so it must declare it — the Plugins pane
    /// renders this and the app is local-first.
    func testMemeGeneratorDeclaresItsNetworkHosts() {
        XCTAssertTrue(PluginRegistry.memeGenerator.usesNetwork)
        XCTAssertNotNil(PluginRegistry.memeGenerator.networkDisclosure)
        XCTAssertTrue(PluginRegistry.memeGenerator.networkHosts.contains("api.imgflip.com"))
    }
}
