import XCTest
@testable import OpenWhispCore

/// The MAK-100 plugin API contracts: `clipboardAccess`, `destination`, and the
/// router metadata (`voiceTriggers` + `appAffinity`).
///
/// All three are ADDITIVE to the manifest schema. The property these tests exist to
/// hold is that adding them cannot break a manifest that predates them — a plugin
/// already sitting in a user's Application Support folder must keep working across an
/// app update, because there is no migration path for a file the app doesn't own.
final class PluginContractTests: XCTestCase {

    /// A manifest with only the original required keys — i.e. one written before any
    /// of the MAK-100 fields existed.
    private let legacyJSON = """
    {
      "id": "legacy-plugin",
      "name": "Legacy Plugin",
      "symbol": "questionmark.circle"
    }
    """

    private func decode(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    // MARK: - Forward-compatible decode

    /// The headline compatibility guarantee: a manifest that predates all three
    /// contracts still decodes, is still valid, and lands on the safe defaults.
    func testAManifestPredatingEveryContractStillDecodesAtSafeDefaults() throws {
        let manifest = try decode(legacyJSON)

        XCTAssertTrue(manifest.isValid)
        // Clipboard defaults CLOSED. A field whose absence meant "yes" would hand the
        // pasteboard to every plugin written before the capability existed.
        XCTAssertFalse(manifest.clipboardAccess)
        XCTAssertNil(manifest.clipboardDisclosure)
        XCTAssertEqual(manifest.destination, .ownWindow)
        XCTAssertEqual(manifest.appAffinity, [])
        XCTAssertEqual(manifest.voiceTriggers, [])
    }

    /// An UNKNOWN destination — a manifest written for a future host — degrades to the
    /// default rather than throwing the plugin out of the list.
    func testAnUnknownDestinationDecodesToOwnWindowRatherThanFailing() throws {
        let manifest = try decode("""
        {
          "id": "future-plugin",
          "name": "Future Plugin",
          "symbol": "sparkles",
          "destination": "holographicProjector"
        }
        """)

        XCTAssertEqual(manifest.destination, .ownWindow)
        XCTAssertTrue(manifest.isValid)
    }

    /// Every contract field round-trips through JSON.
    func testEveryContractFieldRoundTripsThroughJSON() throws {
        let original = PluginManifest(
            id: "round-trip", name: "Round Trip", version: "1.2.3",
            summary: "s", symbol: "circle", entry: .builtIn,
            networkHosts: ["example.com"], keyEquivalent: "k",
            voiceTriggers: ["do the thing"],
            appAffinity: ["com.apple.Safari"],
            clipboardAccess: true,
            destination: .ownWindow)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - clipboardAccess

    /// The gate: a plugin that did not declare the capability receives NOTHING, even
    /// when the host had a perfectly good pasteboard string in hand.
    func testAPluginThatDidNotDeclareClipboardAccessReceivesNoClipboard() {
        let manifest = PluginManifest(
            id: "no-clip", name: "No Clip", version: "1", summary: "",
            symbol: "circle", entry: .builtIn)

        let context = PluginInvocationContext.make(
            manifest: manifest, material: "hello", pasteboardString: "SECRET TOKEN")

        XCTAssertNil(context.clipboard)
        XCTAssertEqual(context.material, "hello")
        XCTAssertFalse(PluginInvocationContext.needsPasteboard(manifest))
    }

    /// A plugin that DID declare it receives the pasteboard verbatim.
    func testADeclaringPluginReceivesTheClipboard() {
        let manifest = PluginManifest(
            id: "clip", name: "Clip", version: "1", summary: "",
            symbol: "circle", entry: .builtIn, clipboardAccess: true)

        let context = PluginInvocationContext.make(
            manifest: manifest, material: "hello", pasteboardString: "pasted text")

        XCTAssertEqual(context.clipboard, "pasted text")
        XCTAssertTrue(PluginInvocationContext.needsPasteboard(manifest))
    }

    /// An empty or whitespace-only pasteboard reads as nothing, so a plugin doesn't
    /// have to re-implement the emptiness check.
    func testAnEmptyOrWhitespacePasteboardIsTreatedAsNoClipboard() {
        let manifest = PluginManifest(
            id: "clip", name: "Clip", version: "1", summary: "",
            symbol: "circle", entry: .builtIn, clipboardAccess: true)

        for raw in [nil, "", "   ", "\n\t "] as [String?] {
            let context = PluginInvocationContext.make(
                manifest: manifest, material: "m", pasteboardString: raw)
            XCTAssertNil(context.clipboard, "expected nil clipboard for \(String(describing: raw))")
        }
    }

    /// Declaring the capability drives a user-visible disclosure, the same way
    /// `networkHosts` does. Pinned here because it is a privacy-facing string.
    func testDeclaringClipboardAccessProducesADisclosure() {
        let manifest = PluginManifest(
            id: "clip", name: "Clip", version: "1", summary: "",
            symbol: "circle", entry: .builtIn, clipboardAccess: true)

        XCTAssertEqual(
            manifest.clipboardDisclosure, "Reads your clipboard contents when you use it.")
    }

    /// The shipping meme plugin does NOT take the clipboard — its ⌘V import is for
    /// template images and is an explicit user action. Pinned so the capability can't
    /// be switched on without someone deciding to.
    func testTheMemePluginDoesNotDeclareClipboardAccess() {
        XCTAssertFalse(PluginRegistry.memeGenerator.clipboardAccess)
        XCTAssertNil(PluginRegistry.memeGenerator.clipboardDisclosure)
    }

    // MARK: - destination

    /// `ownWindow` is the only implemented route; the rest are reserved.
    func testOnlyOwnWindowIsImplemented() {
        XCTAssertTrue(PluginDestination.ownWindow.isImplemented)
        XCTAssertNil(PluginDestination.ownWindow.unavailableReason)

        for reserved in [PluginDestination.cursor, .outputTarget] {
            XCTAssertFalse(reserved.isImplemented)
            XCTAssertNotNil(reserved.unavailableReason)
        }
    }

    /// Declaring a reserved destination is REPORTED but never fatal, and the plugin
    /// falls back to its own window — refused honestly rather than silently rerouted.
    func testAReservedDestinationIsReportedButNotFatalAndFallsBack() throws {
        let manifest = try decode("""
        {
          "id": "cursor-plugin",
          "name": "Cursor Plugin",
          "symbol": "text.cursor",
          "destination": "cursor"
        }
        """)

        XCTAssertEqual(manifest.destination, .cursor)
        XCTAssertEqual(manifest.validate(), .unsupportedDestination(.cursor))
        // Not fatal: the plugin still lists and still runs.
        XCTAssertTrue(manifest.isValid)
        // And it goes where the host can actually put it.
        XCTAssertEqual(manifest.effectiveDestination, .ownWindow)
    }

    /// The default needs no declaration and reports nothing.
    func testTheDefaultDestinationIsClean() {
        let manifest = PluginManifest(
            id: "plain", name: "Plain", version: "1", summary: "",
            symbol: "circle", entry: .builtIn)

        XCTAssertEqual(manifest.destination, .ownWindow)
        XCTAssertNil(manifest.validate())
        XCTAssertEqual(manifest.effectiveDestination, .ownWindow)
    }

    // MARK: - Router metadata (appAffinity)

    /// Affinity entries are trimmed and de-duplicated, and CASE IS PRESERVED —
    /// lowercasing a bundle id would stop it matching the app it names.
    func testAppAffinityIsNormalizedWithoutDestroyingBundleIdentifierCase() {
        let manifest = PluginManifest(
            id: "aff", name: "Aff", version: "1", summary: "",
            symbol: "circle", entry: .builtIn,
            appAffinity: ["  com.apple.Safari  ", "com.apple.Safari", "", "   ", "com.apple.mail"])

        XCTAssertEqual(manifest.normalizedAppAffinity, ["com.apple.Safari", "com.apple.mail"])
    }

    /// An affinity list that normalizes away is advisory-only: reported, never fatal.
    func testAnAllEmptyAppAffinityIsReportedButNotFatal() {
        let manifest = PluginManifest(
            id: "aff", name: "Aff", version: "1", summary: "",
            symbol: "circle", entry: .builtIn,
            appAffinity: ["", "   "])

        XCTAssertEqual(manifest.validate(), .emptyAppAffinity)
        XCTAssertTrue(manifest.isValid)
        XCTAssertEqual(manifest.normalizedAppAffinity, [])
    }

    /// `appAffinity` decodes forward-compatibly like every other added field.
    func testAppAffinityDecodesFromJSONAndDefaultsEmpty() throws {
        let withField = try decode("""
        {
          "id": "aff", "name": "Aff", "symbol": "circle",
          "appAffinity": ["com.apple.Safari"]
        }
        """)
        XCTAssertEqual(withField.appAffinity, ["com.apple.Safari"])

        let without = try decode(legacyJSON)
        XCTAssertEqual(without.appAffinity, [])
    }

    /// Affinity is a HINT, not a priority: it must not be reachable as a ranking
    /// weight a plugin assigns itself. Nothing consumes it today, and that is the
    /// point — the host arbitrates the scarce trigger surface (MAK-100's ~15-tool
    /// cap), so this pins that the manifest carries data and never a rank.
    func testAppAffinityCarriesNoPriorityTheManifestCouldAssignItself() {
        let greedy = PluginManifest(
            id: "greedy", name: "Greedy", version: "1", summary: "",
            symbol: "circle", entry: .builtIn,
            voiceTriggers: ["do it"],
            appAffinity: ["com.apple.Safari"])
        let modest = PluginManifest(
            id: "modest", name: "Modest", version: "1", summary: "",
            symbol: "circle", entry: .builtIn,
            voiceTriggers: ["do it"])

        // Routing is decided by trigger matching and LIST ORDER alone. The affinity
        // declaration buys the greedy plugin exactly nothing when it is second.
        let match = PluginVoiceCommandRouter.match(
            instruction: "do it now", enabledPlugins: [modest, greedy])
        XCTAssertEqual(match?.pluginID, "modest")
    }
}
